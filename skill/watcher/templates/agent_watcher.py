"""
agent_watcher.py — shared watcher engine for autonomous coding agents.

Each agent runs as a watcher: poll GitHub, and when there is work in the agent's
label queue and no open PR of its own, launch a fresh headless Claude Code
session with the agent's opening prompt, then exit. This module is the common
engine; per-agent watchers (e.g. backend-watcher.py) are thin config that build
an AgentConfig and call run().

Generic / repo-agnostic: nothing here is specific to one project. Set repo/label/
paths in the per-agent config.
"""

from __future__ import annotations

import json
import os
import sys
import time
import subprocess
from dataclasses import dataclass
from pathlib import Path
from datetime import datetime, timezone

import httpx

POLL_INTERVAL = 60          # seconds between polls
COOLDOWN_SECONDS = 120      # min gap between launches (avoid thrash)
GITHUB_API = "https://api.github.com"


def _record_event(agent: str, ticket, outcome: str, pr_url: str = "") -> None:
    """Append one line to ~/.dyflo/events.jsonl so `dyflo --status` can see what the
    autonomous lane did. Standalone (no engine import — this template runs from the
    repo root): if the engine's events.py is importable we reuse it, else we inline
    the same append + optional DYFLO_NOTIFY_CMD pipe. Best-effort — never fatal."""
    try:
        state = Path(os.getenv("DYFLO_STATE_DIR", str(Path.home() / ".dyflo")))
        ev = {
            "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "agent": agent,
            "ticket": str(ticket) if ticket is not None else "",
            "outcome": outcome,
            "pr_url": pr_url or "",
        }
        line = json.dumps(ev, ensure_ascii=False)
        state.mkdir(parents=True, exist_ok=True)
        with (state / "events.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
        cmd = os.getenv("DYFLO_NOTIFY_CMD")
        if cmd:
            subprocess.run(cmd, shell=True, input=line + "\n", text=True,
                           timeout=10, check=False)
    except Exception:
        pass  # feedback is best-effort; the agent's work is the real output


@dataclass
class AgentConfig:
    name: str                                    # "Backend"
    repo: str                                    # "owner/repo"
    label: str                                   # "backend"
    work_dir: Path                               # repo dir the session runs in
    go_prompt_file: Path                         # opening prompt
    integration_prompt: str                      # end-of-sprint verification prompt
    runtime: str = "claude"                      # "claude" | "cursor" (which headless agent)
    model: str = "claude-sonnet-4-6"             # model id for the chosen runtime
    config_dir: str | None = None                # CLAUDE_CONFIG_DIR / CURSOR_CONFIG_DIR isolation
    queue_file: Path | None = None               # optional queue.json (priority)
    banner: str = ""
    art_idle: str = ""
    art_working: str = ""
    art_goodbye: str = ""


def _gh_headers() -> dict:
    token = os.getenv("GITHUB_TOKEN", "")
    if not token:
        try:
            token = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True).stdout.strip()
        except Exception:
            pass
    return {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"} if token else {}


class _RateLimited(Exception):
    """GitHub signalled a rate limit — never mistake this for an empty queue."""


def _gh_get(url: str, params: dict | None = None):
    r = httpx.get(url, headers=_gh_headers(), params=params or {}, timeout=10)
    remaining = r.headers.get("X-RateLimit-Remaining")
    if r.status_code == 403 and (remaining == "0" or "rate limit" in r.text.lower()):
        retry_after = r.headers.get("Retry-After")
        reset = r.headers.get("X-RateLimit-Reset")
        wait = int(retry_after) if retry_after else (max(0, int(reset) - int(time.time())) if reset else 60)
        raise _RateLimited(f"rate limited; reset in ~{wait}s")
    r.raise_for_status()
    return r.json()  # parse once


def get_open_tickets(cfg: AgentConfig) -> list:
    data = _gh_get(f"{GITHUB_API}/repos/{cfg.repo}/issues",
                   {"labels": cfg.label, "state": "open", "per_page": 50})
    if not isinstance(data, list):   # error body (dict) — never iterate as keys
        return []
    return [i for i in data if "pull_request" not in i]


def get_open_prs(cfg: AgentConfig) -> list:
    data = _gh_get(f"{GITHUB_API}/repos/{cfg.repo}/pulls", {"state": "open", "per_page": 20})
    return data if isinstance(data, list) else []


def _current_login() -> str | None:
    try:
        me = _gh_get(f"{GITHUB_API}/user")
        return me.get("login") if isinstance(me, dict) else None
    except Exception:
        return None


def get_my_failing_pr(cfg: AgentConfig) -> tuple[dict, str] | tuple[None, None]:
    """Return (pr, failure_summary) for a failing PR THIS agent (the auth'd user)
    authored — never anyone else's PR (no touching dependabot etc.)."""
    me = _current_login()
    if not me:
        return None, None
    for pr in get_open_prs(cfg):
        if (pr.get("user") or {}).get("login") != me:
            continue
        try:
            sha = pr["head"]["sha"]
            runs_body = _gh_get(f"{GITHUB_API}/repos/{cfg.repo}/commits/{sha}/check-runs")
            runs = runs_body.get("check_runs", []) if isinstance(runs_body, dict) else []
            if any(r.get("conclusion") == "failure" for r in runs):
                n = len([r for r in runs if r.get("conclusion") == "failure"])
                return pr, f"{n} check(s) failing on your PR #{pr['number']}."
        except _RateLimited:
            raise
        except Exception:
            continue
    return None, None


def _load_queue(cfg: AgentConfig) -> dict:
    """queue.json: { "order": [ints], "skip": [ints], "blocked_by": {"N": [ints]} }
    ALL values are issue NUMBERS (ints). External/prose blockers go in skip + _notes,
    NEVER blocked_by. Missing file → empty policy (ascending issue number)."""
    if not cfg.queue_file or not cfg.queue_file.exists():
        return {"order": [], "skip": set(), "blocked_by": {}}
    try:
        q = json.loads(cfg.queue_file.read_text(encoding="utf-8"))
        return {
            "order": [int(n) for n in q.get("order", [])],
            "skip": {int(n) for n in q.get("skip", [])},
            "blocked_by": {int(k): [int(x) for x in v] for k, v in q.get("blocked_by", {}).items()},
        }
    except Exception as e:
        print(f"[{_now()}] queue.json parse error ({e}) — falling back to default priority.")
        return {"order": [], "skip": set(), "blocked_by": {}}


def prioritize(cfg: AgentConfig, tickets: list) -> list:
    q = _load_queue(cfg)
    open_nums = {t["number"] for t in tickets}
    order_index = {n: i for i, n in enumerate(q["order"])}

    def is_blocked(num: int) -> bool:
        return any(dep in open_nums for dep in q["blocked_by"].get(num, []))

    eligible = [t for t in tickets if t["number"] not in q["skip"] and not is_blocked(t["number"])]
    eligible.sort(key=lambda t: (order_index.get(t["number"], 10_000), t["number"]))
    return eligible


def _now() -> str:
    return datetime.now().strftime("%H:%M:%S")


def _build_prompt(cfg: AgentConfig, tickets: list, failure_context: str | None,
                  custom_prompt: str | None) -> tuple[str, str]:
    if custom_prompt is not None:
        return custom_prompt, f"  {cfg.name} integration verification session"
    go = cfg.go_prompt_file.read_text(encoding="utf-8")
    ordered = prioritize(cfg, tickets)
    if ordered:
        go += "\n\n---\n\n## Your queue (filtered — top = pick this)\n" + \
            "\n".join(f"  {i+1}. #{t['number']} — {t['title']}" for i, t in enumerate(ordered[:10]))
    if failure_context:
        prompt = (f"URGENT — checks are failing on YOUR open PR. Fix them before any new ticket.\n\n"
                  f"{failure_context}\n\n1. Check out the failing PR's branch\n2. Read the failure\n"
                  f"3. Fix\n4. Push — CI re-runs\n\n---\n\n{go}")
        return prompt, "  PR failing — fixing before next ticket"
    return go, "\n".join(f"  #{t['number']} — {t['title']}" for t in ordered[:5])


def _launch_cmd(cfg: AgentConfig, prompt: str) -> tuple[list[str], dict]:
    """Build the headless-agent command + env for the configured runtime.
    claude → `claude -p --dangerously-skip-permissions`;
    cursor → `cursor-agent -p --force --sandbox disabled` (unattended edits+exec).
    Each runtime isolates sessions via its own CONFIG_DIR env var."""
    env = dict(os.environ)
    if cfg.runtime == "cursor":
        if cfg.config_dir:
            env["CURSOR_CONFIG_DIR"] = cfg.config_dir
        cmd = ["cursor-agent", "-p", "--force", "--sandbox", "disabled",
               "--model", cfg.model, prompt]
    else:  # claude (default)
        if cfg.config_dir:
            env["CLAUDE_CONFIG_DIR"] = cfg.config_dir
        cmd = ["claude", "--model", cfg.model, "--dangerously-skip-permissions", "-p", prompt]
    return cmd, env


def launch(cfg: AgentConfig, tickets: list, failure_context: str | None = None,
           custom_prompt: str | None = None):
    prompt, summary = _build_prompt(cfg, tickets, failure_context, custom_prompt)
    print(f"\n[{_now()}] Launching {cfg.name} ({cfg.runtime}):\n{summary}")
    cmd, env = _launch_cmd(cfg, prompt)
    return subprocess.Popen(cmd, cwd=str(cfg.work_dir), env=env, start_new_session=True)


def _my_open_pr_numbers(cfg: AgentConfig) -> set[int]:
    """Open PR numbers authored by the auth'd login on this repo (best-effort)."""
    me = _current_login()
    if not me:
        return set()
    try:
        return {pr["number"] for pr in get_open_prs(cfg)
                if (pr.get("user") or {}).get("login") == me}
    except Exception:
        return set()


def _my_open_prs(cfg: AgentConfig) -> dict[int, str]:
    me = _current_login()
    if not me:
        return {}
    try:
        return {pr["number"]: pr.get("html_url", "")
                for pr in get_open_prs(cfg)
                if (pr.get("user") or {}).get("login") == me}
    except Exception:
        return {}


def run(cfg: AgentConfig):
    if cfg.banner:
        print(cfg.banner)
    print(f"{cfg.name} Watcher started. Polling {cfg.repo} (label: {cfg.label}) every {POLL_INTERVAL}s.")
    print("Press Ctrl+C to stop.\n")

    proc = None
    last_launch = 0.0
    last_state: str | None = None
    prs_at_launch: set[int] = set()   # agent's open PRs when the current session started
    ticket_at_launch = None           # top eligible ticket the session was aimed at

    def announce(state: str, msg: str, art: str = ""):
        nonlocal last_state
        if state == last_state:
            return
        last_state = state
        if art:
            print(art)
        print(f"[{_now()}] {msg}")

    while True:
        try:
            if proc is not None and proc.poll() is not None:
                last_state = None
                print(f"[{_now()}] {cfg.name} session ended (exit {proc.returncode}).")
                # feedback: did the session open a new PR of ours? Record either way.
                try:
                    now_prs = _my_open_prs(cfg)
                    new_nums = set(now_prs) - prs_at_launch
                    if new_nums:
                        for num in sorted(new_nums):
                            _record_event(cfg.name, ticket_at_launch, "pr_opened", now_prs.get(num, ""))
                    else:
                        _record_event(cfg.name, ticket_at_launch, "session_ended")
                except Exception:
                    pass
                proc = None
                ticket_at_launch = None
            running = proc is not None
            cooldown_ok = (time.time() - last_launch) > COOLDOWN_SECONDS

            try:
                tickets = get_open_tickets(cfg)
            except _RateLimited as rl:
                announce("rate_limited", f"GitHub {rl} — backing off, NOT empty queue.")
                time.sleep(POLL_INTERVAL); continue

            eligible = prioritize(cfg, tickets)

            # 1) Fix our OWN failing PR first.
            if not running and cooldown_ok:
                try:
                    failing_pr, failing_out = get_my_failing_pr(cfg)
                except _RateLimited as rl:
                    announce("rate_limited", f"GitHub {rl} — backing off.")
                    time.sleep(POLL_INTERVAL); continue
                if failing_pr:
                    last_state = None
                    prs_at_launch = _my_open_pr_numbers(cfg)
                    ticket_at_launch = failing_pr["number"]
                    proc = launch(cfg, tickets, failure_context=failing_out); last_launch = time.time()
                    announce("working", f"{cfg.name} fixing its failing PR #{failing_pr['number']}.", cfg.art_working)
                    time.sleep(POLL_INTERVAL); continue

            # 2) Otherwise pick a ticket.
            if not eligible:
                announce("idle", f"{cfg.name} chilling — no eligible tickets. Watching...", cfg.art_idle)
            elif running:
                announce("working", f"{cfg.name} working — wrapping current ticket.", cfg.art_working)
            elif cooldown_ok:
                last_state = None
                prs_at_launch = _my_open_pr_numbers(cfg)
                ticket_at_launch = eligible[0]["number"] if eligible else None
                proc = launch(cfg, tickets); last_launch = time.time()
                announce("working", f"{cfg.name} on the prowl — {len(eligible)} eligible.", cfg.art_working)
            else:
                announce("cooldown", f"{len(eligible)} eligible — cooldown active.")

        except KeyboardInterrupt:
            if cfg.art_goodbye:
                print(cfg.art_goodbye)
            print(f"\n{cfg.name} Watcher stopped.")
            sys.exit(0)
        except Exception as e:
            print(f"[{_now()}] Watcher error: {e}")

        time.sleep(POLL_INTERVAL)

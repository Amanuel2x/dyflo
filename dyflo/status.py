#!/usr/bin/env python3
"""
status.py — what are the autonomous-lane watchers doing right now?

For each `*-watcher.py` in the repo root: is its process running (pgrep), what
label does it poll, how deep is its queue, the last few log lines, and the open
PRs the current gh login authored. Plus the tail of the shared event log.

GitHub reads go through the `gh` CLI (it owns its own rate limiting — we don't
duplicate agent_watcher's httpx/backoff logic here).

    python3 status.py [--repo-root DIR] [--events N]
    python3 status.py --self-check
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import events as ev_mod  # noqa: E402


def find_watchers(repo_root: Path) -> list[Path]:
    return sorted(p for p in repo_root.glob("*-watcher.py"))


def _grep_assign(text: str, var: str) -> str | None:
    """Pull a top-level `VAR = "value"` (or os.getenv default) out of a watcher file
    by regex — no import, so a watcher needing httpx/creds can still be inspected."""
    # LABEL = "backend"   /   LABEL = os.getenv("DYFLO_LABEL", "backend")
    m = re.search(rf'^{var}\s*=\s*os\.getenv\([^,]+,\s*["\']([^"\']*)["\']\)', text, re.M)
    if m:
        return m.group(1)
    m = re.search(rf'^{var}\s*=\s*["\']([^"\']*)["\']', text, re.M)
    return m.group(1) if m else None


def is_running(watcher: Path) -> bool:
    """True if a python process is running this exact watcher file."""
    try:
        r = subprocess.run(["pgrep", "-f", watcher.name], capture_output=True, text=True)
        return r.returncode == 0 and bool(r.stdout.strip())
    except Exception:
        return False


def queue_depth(repo_root: Path, name: str) -> int | None:
    """Eligible-ish depth = len(order) - len(skip) from <name>-queue.json, if present.
    A rough number for a glance, not the engine's real prioritize()."""
    qf = repo_root / f"{name}-queue.json"
    if not qf.exists():
        return None
    try:
        q = json.loads(qf.read_text(encoding="utf-8"))
        return max(0, len(q.get("order", [])) - len(q.get("skip", [])))
    except Exception:
        return None


def _gh_login() -> str | None:
    try:
        r = subprocess.run(["gh", "api", "user", "--jq", ".login"],
                           capture_output=True, text=True, timeout=10)
        return r.stdout.strip() or None if r.returncode == 0 else None
    except Exception:
        return None


def open_prs_by_me() -> list[dict]:
    """Open PRs authored by the current gh login, this repo. Empty on any failure
    (no gh, no auth, not a repo) — status must never crash on a missing tool."""
    try:
        r = subprocess.run(
            ["gh", "pr", "list", "--author", "@me", "--state", "open",
             "--json", "number,title,url"],
            capture_output=True, text=True, timeout=15)
        return json.loads(r.stdout or "[]") if r.returncode == 0 else []
    except Exception:
        return []


def last_log_lines(name: str, k: int = 3) -> list[str]:
    """Last k lines of this watcher's most recent per-run log (rt_headless writes
    <ts>-<op>.log; watchers themselves print to their own stdout, but --self /
    research runs land here). Matched loosely by op-name substring."""
    logs_dir = ev_mod._state_dir() / "logs"
    if not logs_dir.exists():
        return []
    cands = sorted(logs_dir.glob(f"*{name}*.log"), reverse=True)
    if not cands:
        return []
    try:
        return cands[0].read_text(encoding="utf-8", errors="replace").splitlines()[-k:]
    except Exception:
        return []


def report(repo_root: Path, events_n: int = 8) -> str:
    lines: list[str] = []
    watchers = find_watchers(repo_root)
    login = _gh_login()
    lines.append(f"== Dyflo status — {repo_root} ==")
    lines.append(f"gh login: {login or '(none / not authed)'}")
    if not watchers:
        lines.append("no *-watcher.py in this repo (set one up via the dyflo-watcher skill).")
    for w in watchers:
        name = w.name[:-len("-watcher.py")]
        text = w.read_text(encoding="utf-8", errors="replace")
        label = _grep_assign(text, "LABEL") or "?"
        depth = queue_depth(repo_root, name)
        run = "RUNNING" if is_running(w) else "stopped"
        depth_s = "n/a" if depth is None else str(depth)
        lines.append(f"\n• {name}  [{run}]  label={label}  queue={depth_s}")
        for ll in last_log_lines(name):
            lines.append(f"    log: {ll}")

    prs = open_prs_by_me()
    lines.append(f"\nopen PRs by {login or 'you'}: {len(prs)}")
    for pr in prs[:10]:
        lines.append(f"    #{pr.get('number')}  {pr.get('title','')}  {pr.get('url','')}")

    tail = ev_mod.tail(events_n)
    lines.append(f"\nrecent events (last {len(tail)}):")
    for e in tail:
        pr = f"  {e.get('pr_url')}" if e.get("pr_url") else ""
        lines.append(f"    {e.get('ts','')}  {e.get('agent','')}  #{e.get('ticket','')}  {e.get('outcome','')}{pr}")
    if not tail:
        lines.append("    (none yet — watchers log here when they open a PR or file a bug)")
    return "\n".join(lines)


def _self_check() -> None:
    import os
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        # a realistic generated watcher
        (root / "backend-watcher.py").write_text(
            'LABEL = os.getenv("DYFLO_LABEL", "backend")\nREPO = "o/r"\n', encoding="utf-8")
        (root / "tessy-watcher.py").write_text('LABEL = "tests"\n', encoding="utf-8")
        (root / "backend-queue.json").write_text(
            json.dumps({"order": [1, 2, 3, 4], "skip": [2]}), encoding="utf-8")

        assert [p.name for p in find_watchers(root)] == ["backend-watcher.py", "tessy-watcher.py"]
        assert _grep_assign((root / "backend-watcher.py").read_text(), "LABEL") == "backend"
        assert _grep_assign((root / "tessy-watcher.py").read_text(), "LABEL") == "tests"
        assert queue_depth(root, "backend") == 3, "4 ordered - 1 skipped"
        assert queue_depth(root, "tessy") is None, "no queue file → None"
        # is_running is a pgrep on a name that isn't a live process → False
        assert is_running(root / "tessy-watcher.py") is False

        # report runs end-to-end with gh/pgrep possibly absent — must not raise
        os.environ["DYFLO_STATE_DIR"] = d
        text = report(root)
        assert "backend" in text and "tessy" in text and "recent events" in text
    print("status self-check OK — discover watchers, parse label, queue depth, report renders")


def main() -> int:
    ap = argparse.ArgumentParser(description="Dyflo watcher status")
    ap.add_argument("--repo-root", default=".")
    ap.add_argument("--events", type=int, default=8)
    ap.add_argument("--self-check", action="store_true")
    args = ap.parse_args()
    if args.self_check:
        _self_check()
        return 0
    print(report(Path(args.repo_root).resolve(), args.events))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

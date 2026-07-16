#!/usr/bin/env python3
"""
events.py — the autonomous lane's feedback trail.

One append-only JSONL file at ~/.dyflo/events.jsonl. Each line is one thing an
agent did: {"ts", "agent", "ticket", "outcome", "pr_url"}. The watcher writes an
event when a session opens a PR or files a bug; `dyflo --status` reads the tail.

Optional integration without coupling: if $DYFLO_NOTIFY_CMD is set, each event
line is piped to it (e.g. a Slack/ntfy one-liner). Notify failures never break the
agent — the JSONL is the source of truth, the notifier is best-effort.

    python3 events.py --self-check
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def _state_dir() -> Path:
    return Path(os.getenv("DYFLO_STATE_DIR", str(Path.home() / ".dyflo")))


def events_path() -> Path:
    return _state_dir() / "events.jsonl"


def record(agent: str, ticket, outcome: str, pr_url: str = "", *, ts: str | None = None) -> dict:
    """Append one event and (best-effort) notify. Returns the event dict.
    `outcome` is a short verb: "pr_opened", "bug_filed", "pr_fixed", etc."""
    ev = {
        "ts": ts or datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "agent": agent,
        "ticket": str(ticket) if ticket is not None else "",
        "outcome": outcome,
        "pr_url": pr_url or "",
    }
    line = json.dumps(ev, ensure_ascii=False)
    path = events_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")
    _notify(line)
    return ev


def _notify(line: str) -> None:
    cmd = os.getenv("DYFLO_NOTIFY_CMD")
    if not cmd:
        return
    try:  # ponytail: best-effort — a broken notifier must never fail the agent.
        subprocess.run(cmd, shell=True, input=line + "\n", text=True,
                       timeout=10, check=False)
    except Exception:
        pass


def tail(n: int = 20, agent: str | None = None) -> list[dict]:
    """Last n events (optionally filtered to one agent), oldest-first."""
    path = events_path()
    if not path.exists():
        return []
    out = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            ev = json.loads(raw)
        except Exception:
            continue  # skip a torn/partial line, keep the rest
        if agent and ev.get("agent") != agent:
            continue
        out.append(ev)
    return out[-n:]


def _self_check() -> None:
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        os.environ["DYFLO_STATE_DIR"] = d
        os.environ.pop("DYFLO_NOTIFY_CMD", None)
        assert tail() == [], "empty before any write"
        e1 = record("Tessy", 42, "pr_opened", "http://pr/1", ts="2026-01-01T00:00:00+00:00")
        assert e1["agent"] == "Tessy" and e1["ticket"] == "42"
        record("Quin", 7, "bug_filed", ts="2026-01-01T00:01:00+00:00")
        got = tail()
        assert len(got) == 2, got
        assert got[0]["outcome"] == "pr_opened" and got[1]["outcome"] == "bug_filed"
        assert tail(agent="Quin") == [got[1]], "agent filter"
        assert tail(n=1) == [got[1]], "n limits to newest"
        # a torn line is skipped, not fatal
        with events_path().open("a", encoding="utf-8") as fh:
            fh.write("{not json\n")
        assert len(tail()) == 2, "torn line skipped"
        # notify hook fires (write a sentinel via the shell command)
        sentinel = Path(d) / "notified.txt"
        os.environ["DYFLO_NOTIFY_CMD"] = f"cat >> {sentinel}"
        record("Coder", 9, "pr_opened", "http://pr/9", ts="2026-01-01T00:02:00+00:00")
        assert sentinel.exists() and "pr_opened" in sentinel.read_text(), "notify cmd got the line"
    print("events self-check OK — append, tail, agent filter, torn-line skip, notify hook")


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        _self_check()
    elif "--tail" in sys.argv:
        for ev in tail():
            print(json.dumps(ev, ensure_ascii=False))
    else:
        print(__doc__)

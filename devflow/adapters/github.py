"""
GitHub ticket adapter — wraps the `gh` CLI (same auth path the watcher uses).

No new dependency: `gh` is already required by agent-orchestration's go-prompts.
Repo is taken from $DEVFLOW_REPO or the current dir's `gh repo view`.
"""
from __future__ import annotations

import json
import os
import subprocess

from . import Ticket, normalize


def _repo() -> str:
    repo = os.getenv("DEVFLOW_REPO")
    if repo:
        return repo
    out = subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
                         capture_output=True, text=True)
    repo = out.stdout.strip()
    if not repo:
        raise RuntimeError("no repo: set $DEVFLOW_REPO or run inside a gh-authed repo")
    return repo


def _gh_json(args: list[str]) -> list[dict]:
    out = subprocess.run(["gh", *args], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args)} failed: {out.stderr.strip()}")
    return json.loads(out.stdout or "[]")


def list_open_tickets(label: str | None) -> list[Ticket]:
    repo = _repo()
    args = ["issue", "list", "--repo", repo, "--state", "open",
            "--json", "number,title,body,labels,url", "--limit", "50"]
    if label:
        args += ["--label", label]
    tickets = []
    for raw in _gh_json(args):
        labels = [l["name"] for l in raw.get("labels", [])]
        tickets.append(normalize(raw, id_key="number", title_key="title",
                                 body_key="body", labels=labels, url=raw.get("url", "")))
    return tickets


def set_label(ticket_id: str, label: str) -> None:
    """Add a label (used by the research stage's auto-downgrade). Idempotent."""
    repo = _repo()
    r = subprocess.run(["gh", "issue", "edit", str(ticket_id), "--repo", repo,
                        "--add-label", label], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"gh issue edit #{ticket_id} --add-label {label} failed: {r.stderr.strip()}")

#!/usr/bin/env python3
"""
Dyflo router — decide a ticket's lane from its labels. Deterministic, no LLM.

    auto            → AUTONOMOUS lane (the watcher runs it headless)
    hitl / unlabeled → HITL lane (research stage → your approval → TRIP)

The one safety invariant: the router NEVER escalates. A ticket only reaches the
autonomous lane if a human labeled it `auto`, OR the research stage downgraded it
there after judging it small. The router itself cannot send `hitl`/unlabeled work
into unattended execution — that path goes through research, which only downgrades.

Usage:
  python3 router.py --repo owner/name --adapter github [--label hitl]
  python3 router.py --self-check
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from adapters import Ticket, get  # noqa: E402

AUTO = "auto"
HITL = "hitl"


def _config_labels() -> tuple[str, str]:
    """Read renamed lane labels from dyflo.config.json (repo cwd), if present.
    This is what makes the README's 'rename auto/hitl to whatever your team uses'
    real — the lane semantics never change, only the label spellings."""
    import json
    cfg = Path("dyflo.config.json")
    if cfg.exists():
        try:
            labels = json.loads(cfg.read_text(encoding="utf-8")).get("labels", {})
            return labels.get("auto", AUTO).lower(), labels.get("hitl", HITL).lower()
        except Exception:
            pass  # malformed config → safe defaults
    return AUTO, HITL


def lane_for(ticket: Ticket, auto_label: str = AUTO, hitl_label: str = HITL) -> str:
    """Pure function: map a ticket to 'auto' or 'hitl'. The auto label wins only if
    present; everything else (including the hitl label and unlabeled) is HITL, which
    routes through the research stage. Never returns auto for an unlabeled ticket."""
    labels = {l.lower() for l in ticket["labels"]}
    if auto_label in labels and hitl_label not in labels:   # explicit auto, not also flagged hitl
        return AUTO
    return HITL


def route(adapter_name: str, label: str | None = None) -> dict[str, list[Ticket]]:
    adapter = get(adapter_name)
    auto_label, hitl_label = _config_labels()
    tickets = adapter.list_open_tickets(label)
    lanes: dict[str, list[Ticket]] = {AUTO: [], HITL: []}
    for t in tickets:
        lanes[lane_for(t, auto_label, hitl_label)].append(t)
    return lanes


def _self_check() -> None:
    def tk(labels):
        return Ticket(id="1", title="t", body="b", labels=labels, url="u")

    assert lane_for(tk(["auto"])) == AUTO
    assert lane_for(tk(["hitl"])) == HITL
    assert lane_for(tk([])) == HITL, "unlabeled must be HITL, never auto — the invariant"
    assert lane_for(tk(["AUTO"])) == AUTO, "label match is case-insensitive"
    assert lane_for(tk(["auto", "hitl"])) == HITL, "hitl wins the tie — never auto-run a hitl ticket"
    assert lane_for(tk(["bug", "auto", "p1"])) == AUTO, "auto among other labels still routes auto"
    # renamed labels (dyflo.config.json "labels" key) keep the same semantics
    assert lane_for(tk(["bot-ok"]), "bot-ok", "review-me") == AUTO, "renamed auto label routes auto"
    assert lane_for(tk(["auto"]), "bot-ok", "review-me") == HITL, "old spelling no longer routes auto after rename"
    assert lane_for(tk([]), "bot-ok", "review-me") == HITL, "unlabeled stays HITL under renamed labels"
    assert lane_for(tk(["bot-ok", "review-me"]), "bot-ok", "review-me") == HITL, "renamed hitl still wins the tie"
    print("router self-check OK — lane mapping + no-escalation invariant + renamed labels verified")


def main() -> int:
    ap = argparse.ArgumentParser(description="Dyflo router")
    ap.add_argument("--adapter", default=os.getenv("DYFLO_ADAPTER", "github"))
    ap.add_argument("--label", default=None, help="filter tickets by label at the source")
    ap.add_argument("--repo", default=None, help="sets $DYFLO_REPO for the adapter")
    ap.add_argument("--json", action="store_true",
                    help="emit the routed lanes as JSON (for the launcher's ticket picker)")
    ap.add_argument("--self-check", action="store_true")
    args = ap.parse_args()

    if args.self_check:
        _self_check()
        return 0
    if args.repo:
        os.environ["DYFLO_REPO"] = args.repo

    lanes = route(args.adapter, args.label)
    if args.json:
        import json as _json
        print(_json.dumps(lanes))
        return 0
    for lane, tickets in lanes.items():
        print(f"\n{lane.upper()} lane — {len(tickets)} ticket(s):")
        for t in tickets:
            print(f"  #{t['id']} {t['title']}  [{', '.join(t['labels']) or 'unlabeled'}]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""
catalog lookup — match a ticket's text against the vendored pattern index.

Used by the Dyflo research stage: score each pattern's `use_when` triggers
against the ticket + blast-radius text; return ranked hits. A miss (top score
below THRESHOLD) is the signal to fall back to live retrieval.

Usage:
  python3 lookup.py "ticket text describing the change"
  python3 lookup.py --self-check      # runnable assertions, no args needed
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

CATALOG = Path(__file__).parent / "catalog.json"
THRESHOLD = 0.6  # ponytail: tuned in _self_check — below this → catalog miss → live fallback

# words too common to signal a pattern match on their own
_STOP = {"a", "an", "the", "to", "of", "on", "in", "or", "and", "by", "for", "with",
         "at", "as", "is", "it", "its", "this", "that", "from", "into", "our", "we",
         "per", "not", "no", "do", "does", "can", "may", "must", "should", "same",
         "one", "two", "many", "some", "any", "each", "them", "they", "when", "up",
         "off", "out", "over", "across", "than", "vs", "have", "has", "are", "be"}


def _tokens(text: str) -> set[str]:
    return {w for w in re.findall(r"[a-z0-9]+", text.lower()) if w not in _STOP}


def load() -> list[dict]:
    data = json.loads(CATALOG.read_text(encoding="utf-8"))
    return data["patterns"]


def score(ticket: str, pattern: dict) -> float:
    """Score a pattern against ticket text. Per trigger, credit the FRACTION of
    its meaningful words present (real tickets paraphrase, so all-or-nothing
    overlap misses); a verbatim phrase counts as a full 1.0. The pattern's score
    is its BEST-aligned trigger plus a small bonus for corroborating hits — one
    strong match beats a pile of weak ones, so the genuinely-best-fit pattern
    ranks first regardless of how many triggers it happens to list."""
    t = ticket.lower()
    toks = _tokens(ticket)
    strengths = []
    for trigger in pattern["use_when"]:
        if trigger.lower() in t:                       # whole phrase present verbatim
            strengths.append(1.0)
            continue
        tw = _tokens(trigger)
        if not tw:
            continue
        overlap = len(tw & toks) / len(tw)             # fraction of trigger words present
        if overlap >= 0.5:                             # at least half the trigger's words
            strengths.append(overlap)
    if not strengths:
        return 0.0
    strengths.sort(reverse=True)
    best = strengths[0]
    corroboration = 0.1 * (len(strengths) - 1)         # small bonus, can't overtake a stronger best
    return round(best + corroboration, 2)


def match(ticket: str, patterns: list[dict] | None = None, top: int = 3) -> list[tuple[dict, int]]:
    patterns = patterns if patterns is not None else load()
    ranked = sorted(((p, score(ticket, p)) for p in patterns), key=lambda x: -x[1])
    return [(p, s) for p, s in ranked[:top] if s >= THRESHOLD]


def _self_check() -> None:
    pats = load()
    # schema: every entry has the required fields and a real source URL
    req = {"id", "name", "category", "intent", "use_when", "tradeoff", "source_url"}
    cats = {"gof", "poeaa", "microservices", "eip"}
    ids = set()
    for p in pats:
        assert req <= p.keys(), f"{p.get('id')} missing fields: {req - p.keys()}"
        assert p["category"] in cats, f"{p['id']} bad category {p['category']}"
        assert p["use_when"], f"{p['id']} has no triggers"
        assert p["source_url"].startswith("http"), f"{p['id']} bad url"
        assert p["id"] not in ids, f"duplicate id {p['id']}"
        ids.add(p["id"])
    # hit: content-based routing ticket → a router pattern ranks FIRST (not just present)
    hits = match("route each incoming ticket to the auto lane or hitl lane by its label", pats)
    assert hits, "expected a router match"
    assert hits[0][0]["id"] in {"content-based-router", "message-router"}, hits[0][0]["id"]
    # hit: legacy-boundary language surfaces the anti-corruption / strangler family in top 3
    hits = match("integrate the payment boundary to our old legacy billing system, migrating off it incrementally", pats)
    assert any(p["id"] in {"anti-corruption-layer", "strangler-fig"} for p, _ in hits), hits
    # miss: nonsense text scores below threshold → live-fallback signal
    assert not match("xyzzy plugh frobnicate the quux", pats), "nonsense should miss"
    # miss: a genuine typo-fix has no architectural shape → miss → (research downgrades to auto)
    assert not match("fix the typo in the readme heading", pats), "trivial fix should miss"
    print(f"self-check OK — {len(pats)} patterns, {len(cats)} categories, ranking+miss verified")


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-check":
        _self_check()
        return 0
    if len(sys.argv) < 2:
        print(__doc__.strip())
        return 2
    ticket = " ".join(sys.argv[1:])
    hits = match(ticket)
    if not hits:
        print("MISS — no pattern above threshold. Research stage: fall back to live retrieval.")
        return 0
    for p, s in hits:
        print(f"[{s:>2}] {p['name']} ({p['category']}) — {p['intent']}")
        print(f"     {p['source_url']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

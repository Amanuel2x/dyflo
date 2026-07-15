#!/usr/bin/env python3
"""Adapter-layer self-check: resolver, envelope shape, error messaging.
Does NOT hit the network — the GitHub calls are exercised by the live router test.

Run:  python3 selfcheck.py
"""
from __future__ import annotations

import sys
from pathlib import Path

# import the package whether run as module or script
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import adapters  # noqa: E402


def main() -> int:
    # normalize() produces the exact envelope keys the router/research stage expect
    t = adapters.normalize(
        {"number": 123, "title": "Add retry", "body": "flaky call", "url": "http://x/123"},
        id_key="number", title_key="title", body_key="body",
        labels=["hitl", "bug"], url="http://x/123",
    )
    assert set(t.keys()) == {"id", "title", "body", "labels", "url"}, t.keys()
    assert t["id"] == "123" and isinstance(t["id"], str), "id must be stringified"
    assert t["labels"] == ["hitl", "bug"]

    # missing-field body/title coerce to "" not None (research stage concatenates them)
    t2 = adapters.normalize({"number": 9, "url": "u"}, id_key="number", title_key="title",
                            body_key="body", labels=[], url="u")
    assert t2["title"] == "" and t2["body"] == "", "missing title/body must be empty strings"

    # resolver: known adapter imports; github exposes the contract
    gh = adapters.get("github")
    assert hasattr(gh, "list_open_tickets") and hasattr(gh, "set_label"), "github missing contract"

    # resolver: unknown adapter gives a clear, listing error (not a bare ImportError)
    try:
        adapters.get("nope")
        assert False, "expected ValueError for unknown adapter"
    except ValueError as e:
        assert "unknown ticket adapter" in str(e) and "github" in str(e), str(e)

    print("adapters self-check OK — envelope, resolver, and error messaging verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

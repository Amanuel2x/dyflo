#!/usr/bin/env python3
"""
adr.py — list and gate the research stage's ADRs.

The research stage writes docs/adr/NNN-<slug>.md (adr.github.io format). The human
gate is a one-word status under a `## Status` header: Proposed → Accepted (approve)
or Rejected. This tool lists them, flips one status line in place, and — on approve —
names the next step: the TRIP plan command seeded with that ADR path.

    python3 adr.py list [--dir docs/adr]
    python3 adr.py set <n> Accepted|Rejected|Proposed [--dir docs/adr]
    python3 adr.py next <n> [--dir docs/adr]      # print the seeded plan command
    python3 adr.py --self-check

`<n>` matches the leading number of the ADR filename (e.g. 7 → docs/adr/0007-*.md).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

STATUSES = ("Proposed", "Accepted", "Rejected", "Superseded")
_NUM_RE = re.compile(r"^0*(\d+)")


def parse_status(text: str) -> str:
    """First non-empty line inside the `## Status` section. Returns the recognized
    status word if present, else the raw first line, else 'Unknown'. Tolerant of an
    inline HTML comment on the status line (the template has one)."""
    lines = text.splitlines()
    in_status = False
    for line in lines:
        stripped = line.strip()
        if stripped.lower().startswith("## status"):
            in_status = True
            continue
        if in_status:
            if not stripped:
                continue
            if stripped.startswith("#"):     # hit the next section without a value
                break
            word = stripped.split("<!--")[0].strip()  # drop trailing comment
            for s in STATUSES:
                if word.lower().startswith(s.lower()):
                    return s
            return word or "Unknown"
    return "Unknown"


def _num(path: Path) -> int | None:
    m = _NUM_RE.match(path.stem)
    return int(m.group(1)) if m else None


def list_adrs(adr_dir: Path) -> list[tuple[int | None, Path, str]]:
    """(number, path, status) for every ADR file, template.md excluded, sorted."""
    if not adr_dir.exists():
        return []
    out = []
    for p in sorted(adr_dir.glob("*.md")):
        if p.name == "template.md":
            continue
        out.append((_num(p), p, parse_status(p.read_text(encoding="utf-8"))))
    out.sort(key=lambda t: (t[0] is None, t[0] if t[0] is not None else 0, t[1].name))
    return out


def find(adr_dir: Path, n: int) -> Path | None:
    for num, path, _ in list_adrs(adr_dir):
        if num == n:
            return path
    return None


def set_status(path: Path, status: str) -> str:
    """Replace the value line inside `## Status` with `status`, preserving any
    trailing `<!-- ... -->` comment on that line. Returns the new status."""
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    in_status = False
    for i, line in enumerate(lines):
        s = line.strip()
        if s.lower().startswith("## status"):
            in_status = True
            continue
        if in_status:
            if not s:
                continue
            if s.startswith("#"):
                break  # section had no value line; leave as-is
            comment = ""
            if "<!--" in line:
                comment = "  " + line[line.index("<!--"):].rstrip("\n")
            nl = "\n" if line.endswith("\n") else ""
            lines[i] = f"{status}{comment}{nl}"
            path.write_text("".join(lines), encoding="utf-8")
            return status
    raise ValueError(f"no Status value line found in {path.name}")


def next_step(path: Path) -> str:
    """The command to run once an ADR is Accepted: TRIP's plan step, seeded with
    the ADR path. TRIP reads repo docs, so the ADR file IS the handoff artifact."""
    return f"/TRIP-1-plan (seed: {path})"


def _self_check() -> None:
    import tempfile
    tmpl = (
        "# ADR 0007: Use a Strategy\n\n"
        "## Status\n\n"
        "Proposed  <!-- Proposed → Accepted at the gate -->\n\n"
        "## Context\n\nsome context\n"
    )
    with tempfile.TemporaryDirectory() as d:
        adr_dir = Path(d)
        p = adr_dir / "0007-use-a-strategy.md"
        p.write_text(tmpl, encoding="utf-8")
        (adr_dir / "template.md").write_text("# ADR NNN\n## Status\nProposed\n", encoding="utf-8")

        assert parse_status(tmpl) == "Proposed"
        lst = list_adrs(adr_dir)
        assert len(lst) == 1 and lst[0][0] == 7, "template.md excluded, number parsed"
        assert lst[0][2] == "Proposed"
        assert find(adr_dir, 7) == p and find(adr_dir, 99) is None

        assert set_status(p, "Accepted") == "Accepted"
        assert parse_status(p.read_text(encoding="utf-8")) == "Accepted"
        assert "<!-- Proposed" in p.read_text(encoding="utf-8"), "trailing comment preserved"
        # rejecting flips it back and body/other sections stay intact
        set_status(p, "Rejected")
        body = p.read_text(encoding="utf-8")
        assert parse_status(body) == "Rejected" and "some context" in body

        # no-status-value file: raises rather than corrupting
        bad = adr_dir / "0008-empty.md"
        bad.write_text("# ADR 0008\n## Status\n## Context\nx\n", encoding="utf-8")
        try:
            set_status(bad, "Accepted"); assert False, "should raise on missing value"
        except ValueError:
            pass
        assert "/TRIP-1-plan" in next_step(p) and str(p) in next_step(p)
    print("adr self-check OK — parse, list (template excluded), set (comment-preserving), next-step")


def _cmd_list(adr_dir: Path) -> int:
    rows = list_adrs(adr_dir)
    if not rows:
        print(f"no ADRs in {adr_dir} (research stage writes them here).")
        return 0
    for num, path, status in rows:
        tag = f"#{num}" if num is not None else "  ?"
        print(f"  {tag:>4}  [{status:<10}] {path.name}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Dyflo ADR gate")
    ap.add_argument("action", nargs="?", default="list",
                    choices=["list", "set", "next", "selfcheck"])
    ap.add_argument("n", nargs="?", type=int)
    ap.add_argument("status", nargs="?")
    ap.add_argument("--dir", default="docs/adr")
    ap.add_argument("--self-check", action="store_true")
    args = ap.parse_args()

    if args.self_check or args.action == "selfcheck":
        _self_check()
        return 0

    adr_dir = Path(args.dir)
    if args.action == "list":
        return _cmd_list(adr_dir)

    if args.n is None:
        print("need an ADR number (see: adr.py list)", file=sys.stderr)
        return 2
    path = find(adr_dir, args.n)
    if not path:
        print(f"no ADR #{args.n} in {adr_dir}", file=sys.stderr)
        return 1

    if args.action == "next":
        print(next_step(path))
        return 0

    # set
    if not args.status:
        print("need a status: Accepted | Rejected | Proposed", file=sys.stderr)
        return 2
    target = next((s for s in STATUSES if s.lower() == args.status.lower()), None)
    if not target:
        print(f"unknown status {args.status!r}; use one of {', '.join(STATUSES)}", file=sys.stderr)
        return 2
    set_status(path, target)
    print(f"{path.name} → {target}")
    if target == "Accepted":
        print(f"next: {next_step(path)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

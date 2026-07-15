#!/usr/bin/env bash
# vendor-ponytail.sh — put ponytail's ruleset into a repo's AGENTS.md so the
# autonomous lane's headless `claude -p` children obey it.
#
# Why: ponytail injects into interactive sessions and Task-spawned subagents via a
# SubagentStart hook, but the watcher launches `claude -p` as a SEPARATE top-level
# process in its own CLAUDE_CONFIG_DIR — that hook never fires for it. The watcher
# go-prompt already promises "CLAUDE.md / AGENTS.md … treat its rules as mandatory",
# so vendoring the ruleset into AGENTS.md is how ponytail reaches that lane.
#
# Idempotent: the block is fenced by markers, so re-running (or upgrading ponytail)
# replaces it in place instead of duplicating, while preserving any other content.
#
#   vendor-ponytail.sh <repo-root>
set -euo pipefail

REPO="${1:?usage: vendor-ponytail.sh <repo-root>}"

python3 - "$REPO" <<'PY'
import glob, os, sys

repo = sys.argv[1]
dest = os.path.join(repo, "AGENTS.md")
BEGIN = "<!-- ponytail:begin (vendored by devflow) -->"
END = "<!-- ponytail:end -->"

# Locate ponytail's canonical AGENTS.md — newest installed version, not hardcoded.
cands = sorted(
    glob.glob(os.path.expanduser("~/.claude/plugins/cache/ponytail/ponytail/*/AGENTS.md")),
    key=os.path.getmtime, reverse=True,
)
if not cands:
    sys.exit("!! ponytail AGENTS.md not found under ~/.claude/plugins/cache/ponytail/.\n"
             f"   Install the ponytail plugin, or copy its AGENTS.md into {dest} manually.")
src = cands[0]
block = f"{BEGIN}\n{open(src, encoding='utf-8').read().rstrip()}\n{END}\n"

existing = open(dest, encoding="utf-8").read() if os.path.exists(dest) else ""
if BEGIN in existing and END in existing:
    b = existing.index(BEGIN)
    e = existing.index(END) + len(END)
    # keep a trailing newline if the old block had one
    tail = existing[e:]
    new = existing[:b] + block.rstrip("\n") + tail
    action = "refreshed"
else:
    sep = "" if not existing or existing.endswith("\n\n") else ("\n" if existing.endswith("\n") else "\n\n")
    new = existing + sep + block
    action = "vendored"

open(dest, "w", encoding="utf-8").write(new)
print(f"-- {action} ponytail ruleset in {dest} (from {src})")
PY

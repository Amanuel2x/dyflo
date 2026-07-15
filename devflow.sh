#!/usr/bin/env bash
# devflow.sh — single entry point for the hybrid autonomous + HITL dev loop.
#
#   devflow.sh                 interactive menu (assign vs do-it-yourself)
#   devflow.sh --self          do the work yourself (equipped interactive session)
#   devflow.sh --assign        route all open tickets into their lanes
#   devflow.sh --assign <id>   run the research stage on one HITL ticket
#   devflow.sh --docs [focus]  document the repo (doc-cartographer → docs/ARCHITECTURE.md + Mermaid)
#   devflow.sh --bootstrap     one-time setup for the TARGET repo (graph, hooks, labels, ponytail)
#   devflow.sh --check         run the engine self-checks
#
# Two directories, kept separate so this wraps ANY project:
#   DEVFLOW_HOME — where this repo's engine lives (resolved from the script path,
#                  or $DEVFLOW_HOME if you symlinked devflow.sh onto your PATH).
#   REPO_ROOT    — the TARGET project you're operating on (the current git repo / cwd).
#
# ponytail: this is dispatch, not a daemon. The autonomous *loop* is the watcher
# (python3 <name>-watcher.py); scheduling (cron/launchd) is deliberately out of scope.
set -euo pipefail

# Resolve DEVFLOW_HOME even through a symlink on PATH.
_src="${BASH_SOURCE[0]}"
while [ -h "$_src" ]; do _dir="$(cd -P "$(dirname "$_src")" && pwd)"; _src="$(readlink "$_src")"; [[ $_src != /* ]] && _src="$_dir/$_src"; done
DEVFLOW_HOME="${DEVFLOW_HOME:-$(cd -P "$(dirname "$_src")" && pwd)}"
ENGINE="$DEVFLOW_HOME/devflow"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="$REPO_ROOT/devflow.config.json"

cfg() { [ -f "$CONFIG" ] && python3 -c "import json;print(json.load(open('$CONFIG')).get('$1',''))" 2>/dev/null || echo ""; }
ADAPTER="$(cfg adapter)"; ADAPTER="${ADAPTER:-github}"

bootstrap() {
  echo "== DevFlow bootstrap — target repo: $REPO_ROOT =="
  command -v graphify >/dev/null || { echo "!! graphify not found. Install: uv tool install 'graphifyy[mcp]'"; exit 1; }

  echo "-- building knowledge graph (AST-only, no API key)…"
  ( cd "$REPO_ROOT" && graphify update . )

  echo "-- installing graphify post-commit re-index hook…"
  ( cd "$REPO_ROOT" && graphify hook install ) || echo "   (hook install skipped — not a git repo?)"

  echo "-- vendoring ponytail AGENTS.md for the autonomous lane…"
  bash "$ENGINE/vendor-ponytail.sh" "$REPO_ROOT" || echo "   (ponytail plugin not found; see skill/references/vendor-ponytail.md)"

  if [ ! -f "$CONFIG" ]; then
    cat > "$CONFIG" <<JSON
{
  "adapter": "github",
  "labels": { "auto": "auto", "hitl": "hitl" }
}
JSON
    echo "-- wrote $CONFIG (edit adapter/labels as needed)"
  fi

  echo "-- ensuring lane labels exist on the source…"
  if command -v gh >/dev/null 2>&1 && [ "$ADAPTER" = "github" ]; then
    gh label create auto --description 'DevFlow: autonomous lane' 2>/dev/null && echo "   created label: auto" || echo "   label auto exists (or no gh repo)"
    gh label create hitl --description 'DevFlow: human-in-the-loop lane' 2>/dev/null && echo "   created label: hitl" || echo "   label hitl exists (or no gh repo)"
  else
    echo "   (non-github adapter — create the auto/hitl labels on your ticket source manually)"
  fi
  echo "== bootstrap done. Next: devflow.sh --assign  or  devflow.sh --self =="
}

do_self() {
  echo "== equipped interactive session (Graphify + ponytail + TRIP loaded) =="
  [ -f "$REPO_ROOT/graphify-out/graph.json" ] || echo "  (tip: run devflow.sh --bootstrap first so the graph exists)"
  exec claude   # ponytail active via session hooks; graphify MCP + TRIP skills available
}

do_assign() {
  local id="${1:-}"
  # freshness precondition: blast radius must read a CURRENT graph. Refreshing at
  # the read covers every staleness source (pull, rebase, reset, out-of-band edits)
  # that git hooks can't — and costs the same incremental update they would run.
  [ -d "$REPO_ROOT/graphify-out" ] && ( cd "$REPO_ROOT" && graphify update . 2>&1 | grep -E "Rebuilt" || true )
  if [ -n "$id" ]; then
    echo "== research stage on ticket #$id (HITL) =="
    echo "The devflow skill will, for ticket #$id:"
    echo "  1. graphify affected/path on the symbols it touches (blast radius)"
    echo "  2. python3 $ENGINE/patterns/lookup.py \"<ticket text>\"  (pattern match)"
    echo "  3. ponytail gate → NO_PATTERN (relabel auto) OR draft ADR → docs/adr/"
    echo "Then: approve the ADR and run /TRIP-1-plan on it."
    exec claude -p "/devflow research the ticket #$id in $REPO_ROOT and produce a draft ADR or downgrade it to the auto lane"
  fi
  echo "== routing all open tickets by label (adapter: $ADAPTER) =="
  DEVFLOW_ADAPTER="$ADAPTER" python3 "$ENGINE/router.py" --adapter "$ADAPTER"
  echo
  echo "Next:"
  echo "  • AUTO tickets  → start the watcher:  python3 <name>-watcher.py"
  echo "  • HITL tickets  → devflow.sh --assign <id>   (runs the research stage)"
  echo "  • before merging an auto-lane PR → /code-review <pr#>  (+ /security-review if it touches auth/secrets/validation)"
}

do_check() {
  echo "== engine self-checks =="
  python3 "$ENGINE/patterns/lookup.py" --self-check
  ( cd "$ENGINE/adapters" && python3 selfcheck.py )
  python3 "$ENGINE/router.py" --self-check
  python3 "$ENGINE/docs/graph_to_mermaid.py" --self-check
  bash -n "$ENGINE/vendor-ponytail.sh" && echo "vendor-ponytail.sh syntax OK"
}

do_docs() {
  echo "== documenting $REPO_ROOT =="
  command -v graphify >/dev/null || { echo "!! graphify not found; run devflow --bootstrap first"; exit 1; }
  [ -f "$REPO_ROOT/graphify-out/graph.json" ] || ( cd "$REPO_ROOT" && graphify update . )
  local focus="${1:-}"
  local msg="Use the doc-cartographer agent to document $REPO_ROOT into docs/ARCHITECTURE.md with Mermaid diagrams generated from the graph."
  [ -n "$focus" ] && msg="$msg Focus on: $focus."
  exec claude -p "$msg"
}

case "${1:-}" in
  --bootstrap) bootstrap ;;
  --self)      do_self ;;
  --assign)    do_assign "${2:-}" ;;
  --docs)      do_docs "${2:-}" ;;
  --check)     do_check ;;
  "" )
    echo "DevFlow — target repo: $REPO_ROOT"
    echo "  1) Assign work   (route tickets into lanes)"
    echo "  2) Do it myself  (equipped interactive session)"
    read -rp "> " choice
    case "$choice" in
      1) do_assign ;;
      2) do_self ;;
      *) echo "nothing picked"; exit 0 ;;
    esac ;;
  -h|--help)   sed -n '2,18p' "$0" ;;
  *) echo "usage: devflow.sh [--bootstrap|--self|--assign [id]|--docs [focus]|--check]"; exit 2 ;;
esac

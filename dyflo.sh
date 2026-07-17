#!/usr/bin/env bash
# dyflo.sh — single entry point for the hybrid autonomous + HITL dev loop.
#
#   dyflo.sh                 persistent interactive menu (assign/research/self/docs/status/adr/check)
#   dyflo.sh --self          do the work yourself (equipped interactive session)
#   dyflo.sh --assign        route all open tickets into their lanes (+ pick one to act on)
#   dyflo.sh --assign <id>   run the research stage on one HITL ticket
#   dyflo.sh --docs [focus]  document the repo (doc-cartographer → docs/ARCHITECTURE.md + Mermaid)
#   dyflo.sh --status        what each *-watcher.py is doing + recent events + open PRs
#   dyflo.sh --adr [n [approve|reject]]  list ADRs / gate one at the human checkpoint
#   dyflo.sh --bootstrap     one-time setup for the TARGET repo (graph, hooks, labels, ponytail)
#   dyflo.sh --check         run the engine self-checks
#
# Two directories, kept separate so this wraps ANY project:
#   DYFLO_HOME — where this repo's engine lives (resolved from the script path,
#                  or $DYFLO_HOME if you symlinked dyflo.sh onto your PATH).
#   REPO_ROOT    — the TARGET project you're operating on (the current git repo / cwd).
#
# ponytail: this is dispatch, not a daemon. The autonomous *loop* is the watcher
# (python3 <name>-watcher.py); scheduling (cron/launchd) is deliberately out of scope.
set -euo pipefail

# Resolve DYFLO_HOME even through a symlink on PATH.
_src="${BASH_SOURCE[0]}"
while [ -h "$_src" ]; do _dir="$(cd -P "$(dirname "$_src")" && pwd)"; _src="$(readlink "$_src")"; [[ $_src != /* ]] && _src="$_dir/$_src"; done
DYFLO_HOME="${DYFLO_HOME:-$(cd -P "$(dirname "$_src")" && pwd)}"
ENGINE="$DYFLO_HOME/dyflo"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="$REPO_ROOT/dyflo.config.json"

# runtime abstraction (claude|cursor) — provides rt_interactive / rt_headless
. "$ENGINE/runtime.sh"

cfg() { [ -f "$CONFIG" ] && python3 -c "import json;print(json.load(open('$CONFIG')).get('$1',''))" 2>/dev/null || echo ""; }
ADAPTER="$(cfg adapter)"; ADAPTER="${ADAPTER:-github}"
# runtime from config overrides auto-detection unless env already set it
[ -z "${DYFLO_RUNTIME_ENV_SET:-}" ] && { _cfg_rt="$(cfg runtime)"; [ -n "$_cfg_rt" ] && DYFLO_RUNTIME="$_cfg_rt"; }

bootstrap() {
  echo "== Dyflo bootstrap — target repo: $REPO_ROOT =="
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
  "labels": { "auto": "auto", "hitl": "hitl" },
  "runtime": "$DYFLO_RUNTIME"
}
JSON
    echo "-- wrote $CONFIG (edit adapter/labels as needed)"
  fi

  echo "-- ensuring lane labels exist on the source…"
  if command -v gh >/dev/null 2>&1 && [ "$ADAPTER" = "github" ]; then
    gh label create auto --description 'Dyflo: autonomous lane' 2>/dev/null && echo "   created label: auto" || echo "   label auto exists (or no gh repo)"
    gh label create hitl --description 'Dyflo: human-in-the-loop lane' 2>/dev/null && echo "   created label: hitl" || echo "   label hitl exists (or no gh repo)"
  else
    echo "   (non-github adapter — create the auto/hitl labels on your ticket source manually)"
  fi
  echo "== bootstrap done. Next: dyflo.sh --assign  or  dyflo.sh --self =="
}

do_self() {
  echo "== equipped interactive session (Graphify + ponytail + TRIP loaded) =="
  [ -f "$REPO_ROOT/graphify-out/graph.json" ] || echo "  (tip: run dyflo.sh --bootstrap first so the graph exists)"
  echo "   runtime: $DYFLO_RUNTIME"
  # --self flag hands the shell over (session BECOMES the process); menu uses rt_interactive.
  if [ "${DYFLO_SELF_EXEC:-1}" = "1" ]; then rt_exec_interactive; else rt_interactive; fi
}

# research one HITL ticket → draft ADR / downgrade (child process, so we return)
research_ticket() {
  local id="$1"
  echo "== research stage on ticket #$id (HITL) =="
  echo "The dyflo skill will, for ticket #$id:"
  echo "  1. graphify affected/path on the symbols it touches (blast radius)"
  echo "  2. python3 $ENGINE/patterns/lookup.py \"<ticket text>\"  (pattern match)"
  echo "  3. ponytail gate → NO_PATTERN (relabel auto) OR draft ADR → docs/adr/"
  echo "Then: approve the ADR (dyflo --adr) and run the plan step."
  rt_headless "Run the Dyflo research stage on ticket #$id in $REPO_ROOT (see the dyflo rule/skill): compute blast radius via graphify, match a pattern, and produce a draft ADR in docs/adr/ or downgrade the ticket to the auto lane." "research-$id"
}

do_assign() {
  local id="${1:-}"
  # freshness precondition: blast radius must read a CURRENT graph. Refreshing at
  # the read covers every staleness source (pull, rebase, reset, out-of-band edits)
  # that git hooks can't — and costs the same incremental update they would run.
  [ -d "$REPO_ROOT/graphify-out" ] && ( cd "$REPO_ROOT" && graphify update . 2>&1 | grep -E "Rebuilt" || true )
  if [ -n "$id" ]; then
    research_ticket "$id"
    return
  fi
  echo "== routing all open tickets by label (adapter: $ADAPTER) =="
  # Route ONCE, capture the JSON, print it, and drive the picker from the SAME data
  # (no second fetch). router.py owns the lane decision + no-escalation invariant.
  local lanes_json
  lanes_json="$(cd "$REPO_ROOT" && DYFLO_ADAPTER="$ADAPTER" python3 "$ENGINE/router.py" --adapter "$ADAPTER" --json 2>/dev/null)" || {
    echo "!! routing failed (adapter/auth?). Try: DYFLO_REPO=owner/name, and check gh auth."; return 1; }
  _print_lanes "$lanes_json"
  echo
  echo "Next:"
  echo "  • AUTO tickets  → start the watcher:  python3 <name>-watcher.py"
  echo "  • HITL tickets  → research one below, or: dyflo --assign <id>"
  echo "  • before merging an auto-lane PR → /code-review <pr#>  (+ /security-review if it touches auth/secrets/validation)"
  # Interactive picker (only with a TTY): pick a numbered ticket → research (hitl) / preview (auto).
  if [ -t 0 ]; then _ticket_picker "$lanes_json"; fi
}

# pretty-print the routed lanes from router's JSON
_print_lanes() {
  echo "$1" | python3 -c '
import json, sys
lanes = json.load(sys.stdin)
for lane in ("HITL", "AUTO"):
    ts = lanes.get(lane.lower(), [])
    print()
    print("%s lane — %d ticket(s):" % (lane, len(ts)))
    for i, t in enumerate(ts):
        labels = ", ".join(t["labels"]) or "unlabeled"
        print("  %s%d. #%s %s  [%s]" % (lane[0], i + 1, t["id"], t["title"], labels))
'
}

# numbered picker over the SAME routed data: H<n> → research, A<n> → preview
_ticket_picker() {
  local lanes_json="$1"
  echo
  read -rp "Pick a ticket to act on (e.g. H1 to research, A1 to preview) or Enter to skip: " pick
  [ -z "$pick" ] && return 0
  local lane="${pick:0:1}"; local n="${pick:1}"
  case "$lane" in H|h) lane=hitl ;; A|a) lane=auto ;; *) echo "  (unrecognized — use H<n> or A<n>)"; return 0 ;; esac
  local id
  id="$(echo "$lanes_json" | python3 -c '
import json,sys
lanes=json.load(sys.stdin); lane=sys.argv[1]; i=int(sys.argv[2])-1
ts=lanes.get(lane,[])
print(ts[i]["id"] if 0<=i<len(ts) else "")
' "$lane" "$n" 2>/dev/null)"
  [ -z "$id" ] && { echo "  (no such ticket)"; return 0; }
  if [ "$lane" = hitl ]; then
    research_ticket "$id"
  else
    echo "== preview: auto-lane ticket #$id (no action taken) =="
    echo "This ticket is queued for the autonomous lane. To run it: start its watcher"
    echo "(python3 <name>-watcher.py). To inspect: gh issue view $id"
  fi
}

do_status() {
  python3 "$ENGINE/status.py" --repo-root "$REPO_ROOT"
}

do_adr() {
  local n="${1:-}" action="${2:-}"
  if [ -z "$n" ]; then
    python3 "$ENGINE/adr.py" list --dir "$REPO_ROOT/docs/adr"
    echo
    echo "Approve/reject:  dyflo --adr <n> approve|reject"
    return
  fi
  case "$action" in
    approve)
      python3 "$ENGINE/adr.py" set "$n" Accepted --dir "$REPO_ROOT/docs/adr" || return 1
      local nextcmd
      nextcmd="$(python3 "$ENGINE/adr.py" next "$n" --dir "$REPO_ROOT/docs/adr" 2>/dev/null)"
      echo "Next step: $nextcmd"
      if [ -t 0 ]; then
        read -rp "Run it now via $DYFLO_RUNTIME? [y/N] " yn
        case "$yn" in y|Y) rt_headless "$nextcmd" "adr-$n-plan" ;; esac
      fi ;;
    reject)  python3 "$ENGINE/adr.py" set "$n" Rejected --dir "$REPO_ROOT/docs/adr" ;;
    "")      python3 "$ENGINE/adr.py" list --dir "$REPO_ROOT/docs/adr" ;;
    *)       echo "usage: dyflo --adr <n> approve|reject"; return 2 ;;
  esac
}

do_check() {
  echo "== runtime: $DYFLO_RUNTIME ($(rt_available && echo "$(rt_bin) installed" || echo "$(rt_bin) NOT on PATH")) =="
  if [ -n "${DYFLO_MODEL:-}" ]; then
    echo "== model: $DYFLO_MODEL (from DYFLO_MODEL) =="
  else
    echo "== model: $DYFLO_RUNTIME's own default (set DYFLO_MODEL to force one, e.g. gpt-5) =="
  fi
  echo "== engine self-checks =="
  python3 "$ENGINE/patterns/lookup.py" --self-check
  ( cd "$ENGINE/adapters" && python3 selfcheck.py )
  python3 "$ENGINE/router.py" --self-check
  python3 "$ENGINE/docs/graph_to_mermaid.py" --self-check
  python3 "$ENGINE/adr.py" --self-check
  python3 "$ENGINE/events.py" --self-check
  python3 "$ENGINE/status.py" --self-check
  bash -n "$ENGINE/runtime.sh" && echo "runtime.sh syntax OK"
  bash -n "$ENGINE/vendor-ponytail.sh" && echo "vendor-ponytail.sh syntax OK"
}

do_docs() {
  echo "== documenting $REPO_ROOT =="
  command -v graphify >/dev/null || { echo "!! graphify not found; run dyflo --bootstrap first"; exit 1; }
  [ -f "$REPO_ROOT/graphify-out/graph.json" ] || ( cd "$REPO_ROOT" && graphify update . )
  local focus="${1:-}"
  local msg="Use the doc-cartographer agent to document $REPO_ROOT into docs/ARCHITECTURE.md with Mermaid diagrams generated from the graph."
  [ -n "$focus" ] && msg="$msg Focus on: $focus."
  rt_headless "$msg"
}

# persistent interactive loop: run an action, return to the menu, repeat.
menu_loop() {
  # model: whatever your claude/cursor is configured to use, unless DYFLO_MODEL forces one.
  local model="${DYFLO_MODEL:-$DYFLO_RUNTIME default}"
  while true; do
    echo
    echo "── Dyflo ─────────────────────────────────────────────"
    echo "  runtime: $DYFLO_RUNTIME    model: $model    repo: $REPO_ROOT"
    echo "──────────────────────────────────────────────────────"
    echo "  1) assign    route open tickets into lanes (+ pick one)"
    echo "  2) research  run the research stage on one HITL ticket"
    echo "  3) self      equipped interactive session (return here after)"
    echo "  4) docs      document the repo (Mermaid from the graph)"
    echo "  5) status    what the watchers are doing + recent events"
    echo "  6) adr       list / approve / reject ADRs"
    echo "  7) check     engine self-checks"
    echo "  q) quit"
    read -rp "> " choice || { echo; break; }
    case "$choice" in
      1) do_assign ;;
      2) read -rp "ticket id to research: " rid; if [ -n "$rid" ]; then do_assign "$rid"; fi ;;
      3) DYFLO_SELF_EXEC=0 do_self ;;   # child process, so the menu resumes after
      4) read -rp "focus (optional): " f; do_docs "$f" ;;
      5) do_status ;;
      6) read -rp "adr number (Enter to list): " an
         if [ -z "$an" ]; then do_adr; else read -rp "approve/reject (Enter to view): " aa; do_adr "$an" "$aa"; fi ;;
      7) do_check ;;
      q|Q|quit|exit) break ;;
      "" ) : ;;   # empty line → redraw
      *) echo "  (unrecognized: $choice)" ;;
    esac
  done
}

case "${1:-}" in
  --bootstrap) bootstrap ;;
  --self)      do_self ;;
  --assign)    do_assign "${2:-}" ;;
  --docs)      do_docs "${2:-}" ;;
  --status)    do_status ;;
  --adr)       do_adr "${2:-}" "${3:-}" ;;
  --check)     do_check ;;
  "" )
    # No TTY (CI / piped / remote) → don't block on a prompt; show usage and exit.
    if [ ! -t 0 ]; then
      echo "Dyflo — no interactive terminal. Use an explicit command:"
      echo "  dyflo --assign [id] | --self | --docs [focus] | --status | --adr [n [approve|reject]] | --bootstrap | --check"
      exit 0
    fi
    menu_loop ;;
  -h|--help)   sed -n '2,18p' "$0" ;;
  *) echo "usage: dyflo.sh [--bootstrap|--self|--assign [id]|--docs [focus]|--status|--adr [n [approve|reject]]|--check]"; exit 2 ;;
esac

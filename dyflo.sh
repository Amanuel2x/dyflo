#!/usr/bin/env bash
# dyflo.sh — single entry point for the hybrid autonomous + HITL dev loop.
#
#   dyflo.sh                 persistent interactive menu; first run in a repo opens the setup wizard
#   dyflo.sh --setup         re-run the welcome wizard (agent CLI, model, ticket source)
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

# --- first-run setup wizard --------------------------------------------------
# Dyflo can't guess three things: which agent CLI you use, which model, and where
# your tickets live. Ask once, write the answers to dyflo.config.json, never ask
# again. Fires automatically when there's no config AND we have a TTY (so CI is
# untouched), or on demand via `dyflo --setup`.

# Agent CLIs we know how to look for. Presence on PATH ≠ works (a broken npm shim
# still resolves), so we probe rather than trust `command -v` alone.
_KNOWN_CLIS="claude cursor-agent codex gemini grok aider opencode goose crush"

# does this CLI actually run? (`command -v` finds broken shims too)
_cli_works() {
  local bin="$1"
  command -v "$bin" >/dev/null 2>&1 || return 1
  "$bin" --version >/dev/null 2>&1 || "$bin" --help >/dev/null 2>&1
}

# map a binary name → Dyflo runtime name (built-ins), else empty
_runtime_for_bin() {
  case "$1" in claude) echo claude ;; cursor-agent) echo cursor ;; *) echo "" ;; esac
}

do_setup() {
  if [ ! -t 0 ]; then
    echo "dyflo --setup needs an interactive terminal."; return 1
  fi
  # Preflight: the wizard writes dyflo.config.json in the repo root. If we can't
  # write there (e.g. /opt/... owned by root), say so NOW — not after 3 questions.
  if ! ( : > "$REPO_ROOT/.dyflo-writetest" ) 2>/dev/null; then
    echo
    echo "  ✗ Can't write to $REPO_ROOT"
    echo "    Dyflo saves its config here, but this directory isn't writable by $(id -un)."
    echo "    Fix it one of these ways, then re-run dyflo:"
    echo "      • take ownership:   sudo chown -R $(id -un) \"$REPO_ROOT\""
    echo "      • or run dyflo from a directory you own (e.g. a repo under \$HOME)"
    return 1
  fi
  rm -f "$REPO_ROOT/.dyflo-writetest" 2>/dev/null
  echo
  echo "  ╭──────────────────────────────────────────────╮"
  echo "  │  Welcome to Dyflo                            │"
  echo "  │  Three quick questions, then you're set.     │"
  echo "  ╰──────────────────────────────────────────────╯"
  echo
  echo "  Dyflo routes tickets into two lanes: small work runs autonomously"
  echo "  (agent → PR → exit), big work gets researched and waits for your"
  echo "  approval. It never runs unlabeled work unattended."
  echo

  # ---- 1/3 agent CLI --------------------------------------------------------
  echo "  1/3  Which agent CLI should run sessions?"
  local found=() broken=() b
  for b in $_KNOWN_CLIS; do
    if command -v "$b" >/dev/null 2>&1; then
      if _cli_works "$b"; then found+=("$b"); else broken+=("$b"); fi
    fi
  done
  if [ ${#found[@]} -gt 0 ]; then
    echo "       found on your PATH: ${found[*]}"
  else
    echo "       (none found on your PATH — you can still pick one to install later)"
  fi
  [ ${#broken[@]} -gt 0 ] && echo "       ⚠ installed but not runnable: ${broken[*]}"
  echo
  local i=1 opts=()
  for b in "${found[@]}"; do echo "       $i) $b"; opts+=("$b"); i=$((i+1)); done
  echo "       $i) other (name any agent CLI)"; local other_idx=$i
  echo
  local pick rt="" custom_bin=""
  read -rp "       > " pick
  if [ "$pick" = "$other_idx" ]; then
    read -rp "       CLI command (e.g. codex, grok): " custom_bin
    [ -z "$custom_bin" ] && { echo "       (nothing entered — keeping $DYFLO_RUNTIME)"; custom_bin=""; }
  elif [ -n "$pick" ] && [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -lt "$other_idx" ]; then
    custom_bin="${opts[$((pick-1))]}"
  else
    echo "       (skipped — keeping $DYFLO_RUNTIME)"
  fi

  if [ -n "$custom_bin" ]; then
    rt="$(_runtime_for_bin "$custom_bin")"
    if [ -n "$rt" ]; then
      python3 "$ENGINE/config.py" set runtime "$rt" --dir "$REPO_ROOT" >/dev/null
      DYFLO_RUNTIME="$rt"
      echo "       → runtime: $rt"
    else
      # Unknown CLI: Dyflo doesn't know its flags, so ask for them once.
      echo
      echo "       Dyflo doesn't know $custom_bin's flags — tell it once."
      echo "       (headless = flags for a one-shot non-interactive run)"
      local hl ml am
      read -rp "       headless flags [-p]: " hl; hl="${hl:--p}"
      read -rp "       model flag [--model]: " ml; ml="${ml:---model}"
      read -rp "       small model for menu Q&A (Enter = its default): " am
      # NOTE: use --flag=value. A value like "-p" looks like a flag to argparse
      # with the space form and blows up ("expected one argument").
      python3 "$ENGINE/config.py" add-runtime "$custom_bin" --bin="$custom_bin" \
        --headless="$hl" --model-flag="$ml" --ask-model="$am" --dir="$REPO_ROOT" >/dev/null
      python3 "$ENGINE/config.py" set runtime "$custom_bin" --dir "$REPO_ROOT" >/dev/null
      DYFLO_RUNTIME="$custom_bin"
      echo "       → runtime: $custom_bin (declared; edit dyflo.config.json to tune)"
    fi
  fi

  # ---- 2/3 model ------------------------------------------------------------
  echo
  echo "  2/3  Which model?"
  echo "       1) use $DYFLO_RUNTIME's own default  (recommended)"
  echo "       2) name one (e.g. gpt-5, claude-sonnet-4-6, grok-4)"
  read -rp "       > " mpick
  case "$mpick" in
    2) local mv; read -rp "       model id: " mv
       if [ -n "$mv" ]; then
         python3 "$ENGINE/config.py" set model "$mv" --dir "$REPO_ROOT" >/dev/null
         DYFLO_MODEL="$mv"; echo "       → model: $mv"
       fi ;;
    *) python3 "$ENGINE/config.py" set model "" --dir "$REPO_ROOT" >/dev/null
       echo "       → model: $DYFLO_RUNTIME's default" ;;
  esac

  # ---- 3/3 tickets ----------------------------------------------------------
  echo
  echo "  3/3  Where do your tickets live?"
  echo "       1) GitHub Issues  (built in)"
  echo "       2) Jira / other   (needs a small adapter file)"
  echo "       3) none yet       (I'll use --self and --docs)"
  read -rp "       > " tpick
  case "$tpick" in
    2) echo "       → Jira isn't built in. Drop a file at:"
       echo "         $ENGINE/adapters/jira.py"
       echo "         exposing list_open_tickets(label) + set_label(id,label)"
       echo "         returning {id,title,body,labels,url}. Use github.py as the template."
       echo "         Then: dyflo ask \"set my adapter to jira\"" ;;
    3) echo "       → no ticket source. assign/research stay idle; self/docs work." ;;
    *) python3 "$ENGINE/config.py" set adapter github --dir "$REPO_ROOT" >/dev/null
       echo "       → tickets: GitHub Issues" ;;
  esac

  # ---- auth check -----------------------------------------------------------
  echo
  echo "  Checking what's ready:"
  if rt_available; then echo "       ✓ $(rt_bin) on PATH"
  else echo "       ✗ $(rt_bin) NOT on PATH — install it before assign/research/docs"; fi
  if command -v gh >/dev/null 2>&1; then
    local who; who="$(gh api user --jq .login 2>/dev/null || echo "")"
    if [ -n "$who" ]; then echo "       ✓ gh authed as $who"
    else echo "       ✗ gh installed but not authed — run:  gh auth login"; fi
  else
    echo "       ✗ gh not installed — needed for GitHub tickets + PRs"
  fi
  if command -v graphify >/dev/null 2>&1; then echo "       ✓ graphify $(graphify --version 2>/dev/null | head -1)"
  else echo "       ✗ graphify missing — run:  uv tool install 'graphifyy[mcp]'"; fi

  # ---- offer bootstrap ------------------------------------------------------
  echo
  if [ ! -d "$REPO_ROOT/graphify-out" ]; then
    read -rp "  Bootstrap this repo now (graph, hooks, labels)? [Y/n] " bs
    case "$bs" in n|N) echo "  (skipped — run dyflo --bootstrap when ready)" ;; *) echo; bootstrap ;; esac
  fi
  echo
  echo "  Setup saved to $REPO_ROOT/dyflo.config.json — you won't be asked again."
  echo "  Tip: at the menu prompt you can just type a question, e.g."
  echo "       \"how do I switch to cursor?\" or \"what does assign do?\""
  echo
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
  python3 "$ENGINE/config.py" --self-check
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

# The ask-line: anything typed at `>` that isn't a menu choice is treated as a
# question. It runs on a small/fast model with Dyflo's REAL state injected, and may
# configure Dyflo itself (via config.py — validated writes, never a raw JSON edit).
do_ask() {
  local q="$1"
  if ! rt_available; then
    echo "  ($(rt_bin) isn't on PATH — can't answer questions. Install it, or use the menu numbers.)"
    return 0
  fi
  local cfg_json; cfg_json="$(python3 "$ENGINE/config.py" get --dir "$REPO_ROOT" 2>/dev/null || echo '{}')"
  local brief
  brief="You are the built-in helper for Dyflo, a hybrid dev-loop CLI. Answer the user's question about Dyflo concisely (a few lines, plain text, no markdown headers). You are talking to them at Dyflo's interactive menu prompt.

CURRENT STATE (real, do not contradict it):
  runtime: $DYFLO_RUNTIME   (the coding-agent CLI running sessions)
  model:   ${DYFLO_MODEL:-<unset — the CLI uses its own default model>}
  repo:    $REPO_ROOT
  engine:  $DYFLO_HOME
  dyflo.config.json: $cfg_json

WHAT DYFLO IS: it routes tickets into two lanes. 'auto' label -> autonomous lane (a
watcher runs a headless agent, one ticket -> one PR -> exit). 'hitl'/unlabeled ->
research stage (blast radius via graphify + architecture pattern -> draft ADR you
approve -> gated build). The router only ever DOWNGRADES; unlabeled work never runs
unattended.

MENU: 1 assign (route tickets + pick one) | 2 research <id> | 3 self (equipped
session) | 4 docs (Mermaid from graph) | 5 status (watchers/events) | 6 adr
(list/approve/reject) | 7 check (self-checks) | q quit.
FLAGS: dyflo --bootstrap|--assign [id]|--self|--docs [focus]|--status|--adr [n [approve|reject]]|--check
ENV: DYFLO_RUNTIME (claude|cursor), DYFLO_MODEL (force a model; unset = CLI default),
DYFLO_ASK_MODEL (model for THIS ask-line), DYFLO_ATTENDED=1 (run a headless action
interactively), DYFLO_NOTIFY_CMD (pipe watcher events somewhere), DYFLO_STATE_DIR.

YOU MAY CHANGE DYFLO'S CONFIG when the user asks (e.g. 'switch me to cursor',
'always use gpt-5', 'rename the auto label'). Do it by running, from $REPO_ROOT:
  python3 $ENGINE/config.py set runtime cursor --dir $REPO_ROOT
  python3 $ENGINE/config.py set model gpt-5 --dir $REPO_ROOT     (empty value clears it)
  python3 $ENGINE/config.py set label auto bot-ok --dir $REPO_ROOT
  python3 $ENGINE/config.py set adapter jira --dir $REPO_ROOT
Then state plainly what you changed and that it takes effect on the next menu draw.
Note: config.json sets the default; a DYFLO_RUNTIME/DYFLO_MODEL env var in the
current shell still overrides it for this session.

RULES:
- If it's a config change you can make, MAKE IT, then say what you did.
- If it needs an interactive step you cannot do (gh auth login, claude login,
  installing a CLI), explain it and give the exact command for them to run.
- Never claim to have done something you didn't. Never invent state.
- Be brief. No preamble."
  echo
  rt_ask "$brief" "$q"
  echo
}

# does this look like a question/request rather than a stray typo?
_looks_like_question() {
  case "$1" in
    *\ *|*\?*) return 0 ;;   # has a space or a question mark → prose
    *) return 1 ;;
  esac
}

# Re-read runtime/model from dyflo.config.json (the ask-line may have just changed
# them). An explicit env var still wins — it's the more specific choice.
_refresh_runtime_from_config() {
  if [ -z "${DYFLO_RUNTIME_ENV_SET:-}" ]; then
    local rt; rt="$(cfg runtime)"
    [ -n "$rt" ] && DYFLO_RUNTIME="$rt"
  fi
  if [ -z "${DYFLO_MODEL:-}" ]; then
    local md; md="$(cfg model)"
    [ -n "$md" ] && DYFLO_MODEL="$md"
  fi
}

# persistent interactive loop: run an action, return to the menu, repeat.
menu_loop() {
  # model: whatever your claude/cursor is configured to use, unless DYFLO_MODEL forces one.
  local model="${DYFLO_MODEL:-$DYFLO_RUNTIME default}"
  local ask_model; ask_model="$(rt_ask_model)"; ask_model="${ask_model:-$DYFLO_RUNTIME default}"
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
    echo "  …or just ask: \"how do I switch to cursor?\"  (${ask_model} answers)"
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
      # Anything else that reads like prose → the ask-line. A bare typo still gets
      # the old hint rather than burning a model call.
      *) if _looks_like_question "$choice"; then
           do_ask "$choice"
           # config may have just changed — re-resolve so the header tells the truth.
           _refresh_runtime_from_config
           model="${DYFLO_MODEL:-$DYFLO_RUNTIME default}"
         else
           echo "  (unrecognized: $choice — pick 1-7/q, or ask a question in plain English)"
         fi ;;
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
  --setup)     do_setup ;;
  --check)     do_check ;;
  "" )
    # No TTY (CI / piped / remote) → don't block on a prompt; show usage and exit.
    if [ ! -t 0 ]; then
      echo "Dyflo — no interactive terminal. Use an explicit command:"
      echo "  dyflo --setup | --assign [id] | --self | --docs [focus] | --status | --adr [n [approve|reject]] | --bootstrap | --check"
      exit 0
    fi
    # First run in this repo (no config yet) → the welcome wizard, then the menu.
    if [ ! -f "$CONFIG" ]; then
      do_setup
      _refresh_runtime_from_config
    fi
    menu_loop ;;
  -h|--help)   sed -n '2,18p' "$0" ;;
  *) echo "usage: dyflo.sh [--bootstrap|--self|--assign [id]|--docs [focus]|--status|--adr [n [approve|reject]]|--check]"; exit 2 ;;
esac

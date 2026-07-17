#!/usr/bin/env bash
# runtime.sh — the agent-runtime abstraction. Dyflo's engine is portable; only the
# handful of "launch a coding agent" call sites differ between Claude Code and
# Cursor. Source this and use the rt_* functions instead of hardcoding `claude`.
#
# Pick the runtime with $DYFLO_RUNTIME (claude|cursor); default: whichever CLI is
# on PATH, preferring an explicit setting. Everything below is verified against the
# Cursor CLI docs (cursor-agent -p/--force/--model/--sandbox, CURSOR_CONFIG_DIR,
# .cursor/mcp.json) and the Claude Code CLI.

# --- select runtime -----------------------------------------------------------
# Resolve which coding-agent CLI runs sessions, from what's actually on the machine:
#   1. explicit $DYFLO_RUNTIME (env or config) always wins
#   2. only one of claude / cursor-agent installed → use it
#   3. BOTH installed, nothing chosen → default claude, but say so once so you can
#      switch (no silent hardcoded winner)
#   4. neither installed yet → claude (the install target)
# The MODEL is deliberately NOT chosen here: with $DYFLO_MODEL unset we pass no
# --model flag, so each CLI uses its OWN configured default (whatever model you
# picked in claude / cursor). Set $DYFLO_MODEL to force a specific one (e.g. gpt-5).
rt_detect() {
  if [ -n "${DYFLO_RUNTIME:-}" ]; then echo "$DYFLO_RUNTIME"; return; fi
  local have_claude=0 have_cursor=0
  command -v claude       >/dev/null 2>&1 && have_claude=1
  command -v cursor-agent >/dev/null 2>&1 && have_cursor=1
  if [ "$have_claude" = 1 ] && [ "$have_cursor" = 1 ]; then
    # ambiguous — say which we picked so you can switch (runs once: rt_detect is
    # called a single time per invocation, at source).
    echo "dyflo: both claude and cursor found; using claude (set DYFLO_RUNTIME=cursor to switch)" >&2
    echo "claude"; return
  fi
  [ "$have_cursor" = 1 ] && { echo "cursor"; return; }
  echo "claude"  # only claude, or neither yet (the install target)
}
DYFLO_RUNTIME="$(rt_detect)"

# --- custom runtimes ----------------------------------------------------------
# Beyond the two built-ins, a user can declare ANY agent CLI (codex, grok, gemini…)
# in dyflo.config.json via `config.py add-runtime`. We read its spec here so the
# engine stays generic — Dyflo can't know a third-party CLI's flags, so the user
# supplies them once.
#   rt_spec <field>  → value from the declared spec, empty for built-ins
rt_spec() {
  local field="$1"
  case "$DYFLO_RUNTIME" in claude|cursor) echo ""; return ;; esac
  [ -f "${REPO_ROOT:-$PWD}/dyflo.config.json" ] || { echo ""; return; }
  python3 - "$field" <<PY 2>/dev/null || echo ""
import json, sys
try:
    cfg = json.load(open("${REPO_ROOT:-$PWD}/dyflo.config.json"))
except Exception:
    sys.exit(0)
spec = (cfg.get("runtimes") or {}).get("$DYFLO_RUNTIME", {})
v = spec.get(sys.argv[1], "")
print(" ".join(v) if isinstance(v, list) else v)
PY
}

rt_bin() {
  case "$DYFLO_RUNTIME" in
    cursor) echo "cursor-agent" ;;
    claude) echo "claude" ;;
    *) local b; b="$(rt_spec bin)"; echo "${b:-$DYFLO_RUNTIME}" ;;
  esac
}

# is the runtime's CLI actually installed?
rt_available() { command -v "$(rt_bin)" >/dev/null 2>&1; }

# where per-run logs go: ~/.dyflo/logs/<timestamp>-<op>.log
DYFLO_STATE_DIR="${DYFLO_STATE_DIR:-$HOME/.dyflo}"
rt_log_path() {   # rt_log_path <op>  → path (also ensures the dir exists)
  local op="${1:-run}"
  mkdir -p "$DYFLO_STATE_DIR/logs"
  echo "$DYFLO_STATE_DIR/logs/$(date +%Y%m%d-%H%M%S)-$op.log"
}

# --- launch an interactive session (RETURNS to the caller) -------------------
# rt_interactive        → runs a chat as a CHILD process so the menu can resume.
# For the top-level `--self` flag where handing the shell over is intended, use
# rt_exec_interactive instead (it exec's and never returns).
rt_interactive() {
  case "$DYFLO_RUNTIME" in
    cursor) cursor-agent ;;
    claude) claude ;;
    *) local i; i="$(rt_spec interactive)"; $(rt_bin) $i ;;
  esac
}

# rt_exec_interactive   → replace THIS shell with the interactive session. Only
# for `dyflo --self` (one-shot flag): the user wants the session to BE the process.
rt_exec_interactive() {
  case "$DYFLO_RUNTIME" in
    cursor) exec cursor-agent ;;
    claude) exec claude ;;
    *) local i; i="$(rt_spec interactive)"; exec $(rt_bin) $i ;;
  esac
}

# --- ask-line: answer a question at the menu prompt --------------------------
# rt_ask "<system brief>" "<question>"
# The menu's `>` accepts plain English, not just menu numbers. That's Q&A, not a
# coding session, so it runs on a SMALL/FAST model by default ($DYFLO_ASK_MODEL,
# default claude-haiku-4-5 on claude; on cursor we let the CLI's own default ride
# unless you set one) and is bounded to Dyflo's own config surface — it can run
# `config.py` to actually change settings, but never gets a blanket
# skip-permissions shell from a stray keystroke at a menu prompt.
rt_ask_model() {
  if [ -n "${DYFLO_ASK_MODEL:-}" ]; then echo "$DYFLO_ASK_MODEL"; return; fi
  # Small default only for claude, whose model ids we know. Cursor's list is
  # plan-dependent; a custom runtime's is whatever the user declared. Never guess a
  # model id we can't verify — an unknown --model is a hard error on most CLIs.
  case "$DYFLO_RUNTIME" in
    claude) echo "claude-haiku-4-5" ;;
    cursor) echo "" ;;
    *) rt_spec ask_model ;;
  esac
}

rt_ask() {
  local brief="$1" question="$2"
  local model; model="$(rt_ask_model)"
  local m=(); [ -n "$model" ] && m=(--model "$model")
  local prompt="$brief

USER QUESTION: $question"
  case "$DYFLO_RUNTIME" in
    cursor)
      cursor-agent -p --force --sandbox disabled ${m[@]+"${m[@]}"} "$prompt" ;;
    claude)
      # Allowlist: read state + run Dyflo's own config tool. NOT a general shell.
      # Comma-separated single value — space-separated would swallow the prompt.
      claude -p ${m[@]+"${m[@]}"} \
        --allowedTools "Bash(python3:*),Bash(git status:*),Bash(gh auth status:*),Read" \
        -- "$prompt" ;;
    *)
      # Custom runtime: use its declared headless flags. We can't express a
      # per-CLI tool allowlist we don't know, so this is answer-oriented only —
      # the flags are whatever the user declared.
      local h; h="$(rt_spec headless)"
      $(rt_bin) $h ${m[@]+"${m[@]}"} "$prompt" ;;
  esac
}

# --- launch a one-shot headless session (edits files, runs commands) ----------
# rt_headless "<prompt>" [op]   [optional: $DYFLO_MODEL selects the model]
# Runs as a CHILD (not exec) so callers keep running after it — this is what makes
# `dyflo --assign <id>` route lanes AFTER the research session finishes. Tees output
# to a per-run log under ~/.dyflo/logs and returns the agent's exit code.
# DYFLO_ATTENDED=1 → run the SAME prompt interactively (no -p / no --force) so you
# can watch and steer a session that would otherwise run unattended.
rt_headless() {
  local prompt="$1" op="${2:-headless}"
  # A custom runtime may name its model flag something other than --model.
  local mflag="--model"
  case "$DYFLO_RUNTIME" in claude|cursor) : ;; *) local f; f="$(rt_spec model_flag)"; [ -n "$f" ] && mflag="$f" ;; esac
  local model_arg=()
  [ -n "${DYFLO_MODEL:-}" ] && model_arg=("$mflag" "$DYFLO_MODEL")
  # macOS bash 3.2 treats "${empty[@]}" as unbound under `set -u`; this idiom
  # expands to the flags when set and to NOTHING when empty. ponytail: keep it —
  # it's the portable way to splice an optional array on old bash.
  local m=(); [ ${#model_arg[@]} -gt 0 ] && m=("${model_arg[@]}")
  local log; log="$(rt_log_path "$op")"
  local cmd=()
  if [ "${DYFLO_ATTENDED:-}" = "1" ]; then
    # attended: interactive, so you can watch/steer. No -p, no skip-permissions/--force.
    case "$DYFLO_RUNTIME" in
      cursor) cmd=(cursor-agent ${m[@]+"${m[@]}"} "$prompt") ;;
      claude) cmd=(claude ${m[@]+"${m[@]}"} "$prompt") ;;
      *) local i; i="$(rt_spec interactive)"; cmd=($(rt_bin) $i ${m[@]+"${m[@]}"} "$prompt") ;;  # $i: split on purpose
    esac
  else
    case "$DYFLO_RUNTIME" in
      # --force + --sandbox disabled = unattended file edits + command execution
      cursor) cmd=(cursor-agent -p --force --sandbox disabled ${m[@]+"${m[@]}"} "$prompt") ;;
      claude) cmd=(claude -p --dangerously-skip-permissions ${m[@]+"${m[@]}"} "$prompt") ;;
      *) local h; h="$(rt_spec headless)"; cmd=($(rt_bin) $h ${m[@]+"${m[@]}"} "$prompt") ;;  # $h: split on purpose
    esac
  fi
  echo "   (logging to $log)"
  # tee so the user still sees output live; PIPESTATUS[0] is the agent's real exit.
  "${cmd[@]}" 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}

# --- register an MCP server ---------------------------------------------------
# rt_mcp_add <name> <scope: user|project> -- <cmd> [args...]
# claude has a CLI for this; cursor uses a JSON file, so we write it.
rt_mcp_add() {
  local name="$1" scope="$2"; shift 2
  [ "$1" = "--" ] && shift
  if [ "$DYFLO_RUNTIME" = "cursor" ]; then
    local cfg
    if [ "$scope" = "project" ]; then cfg="$PWD/.cursor/mcp.json"; else cfg="$HOME/.cursor/mcp.json"; fi
    mkdir -p "$(dirname "$cfg")"
    rt_cursor_mcp_write "$cfg" "$name" "$@"
  else
    local scope_flag=(--scope "$scope")
    claude mcp add "$name" "${scope_flag[@]}" -- "$@"
  fi
}

# merge one stdio server into a cursor mcp.json (create if absent), idempotent
rt_cursor_mcp_write() {
  local cfg="$1" name="$2"; shift 2
  python3 - "$cfg" "$name" "$@" <<'PY'
import json, os, sys
cfg, name, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
args = sys.argv[4:]
data = {}
if os.path.exists(cfg):
    try: data = json.load(open(cfg))
    except Exception: data = {}
data.setdefault("mcpServers", {})[name] = {"command": cmd, "args": args, "env": {}}
json.dump(data, open(cfg, "w"), indent=2)
print(f"   wrote {name} → {cfg}")
PY
}

# --- where this runtime keeps skills/commands/rules ---------------------------
# Claude: ~/.claude/{skills,agents}. Cursor: ~/.cursor + .cursor/{commands,rules}.
rt_config_home() {
  if [ "$DYFLO_RUNTIME" = "cursor" ]; then echo "${CURSOR_CONFIG_DIR:-$HOME/.cursor}"; else echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; fi
}

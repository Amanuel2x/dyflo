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
rt_detect() {
  if [ -n "${DYFLO_RUNTIME:-}" ]; then echo "$DYFLO_RUNTIME"; return; fi
  if command -v claude >/dev/null 2>&1; then echo "claude"; return; fi
  if command -v cursor-agent >/dev/null 2>&1; then echo "cursor"; return; fi
  echo "claude"  # default target if neither is installed yet
}
DYFLO_RUNTIME="$(rt_detect)"

rt_bin() { [ "$DYFLO_RUNTIME" = "cursor" ] && echo "cursor-agent" || echo "claude"; }

# is the runtime's CLI actually installed?
rt_available() { command -v "$(rt_bin)" >/dev/null 2>&1; }

# --- launch an interactive session -------------------------------------------
# rt_interactive        → drops you into a chat with the repo + MCP + rules loaded
rt_interactive() {
  if [ "$DYFLO_RUNTIME" = "cursor" ]; then
    exec cursor-agent
  else
    exec claude
  fi
}

# --- launch a one-shot headless session (edits files, runs commands) ----------
# rt_headless "<prompt>"   [optional: $DYFLO_MODEL selects the model]
rt_headless() {
  local prompt="$1"
  local model_arg=()
  [ -n "${DYFLO_MODEL:-}" ] && model_arg=(--model "$DYFLO_MODEL")
  if [ "$DYFLO_RUNTIME" = "cursor" ]; then
    # --force + --sandbox disabled = unattended file edits + command execution
    exec cursor-agent -p --force --sandbox disabled "${model_arg[@]}" "$prompt"
  else
    exec claude -p --dangerously-skip-permissions "${model_arg[@]}" "$prompt"
  fi
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

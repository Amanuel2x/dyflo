#!/usr/bin/env bash
# install.sh — set up Dyflo so you can wrap any repo with it.
#
#   ./install.sh                 install skill + MCP globally (~/.claude), symlink dyflo.sh
#   ./install.sh --project DIR   install the dyflo skill into a specific project's .claude/
#   ./install.sh --no-link       skip the PATH symlink
#
# What it does:
#   1. ensures graphify (+mcp extra) is installed
#   2. registers the graphify MCP server with Claude Code
#   3. installs the /dyflo skill (global ~/.claude/skills or a project .claude/skills)
#   4. symlinks dyflo.sh onto your PATH so you can run it from any repo
#
# Nothing here touches a target repo — per-repo setup is `dyflo.sh --bootstrap`,
# run from inside the repo you want to wrap.
set -euo pipefail

HOME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT=""
LINK=1
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:?--project needs a DIR}"; shift;;
    --project=*) PROJECT="${1#*=}";;
    --no-link) LINK=0;;
  esac
  shift
done

say() { printf '\033[1m%s\033[0m\n' "$*"; }

# 1) graphify -----------------------------------------------------------------
say "1) graphify"
if command -v graphify >/dev/null; then
  echo "   graphify present: $(graphify --version 2>/dev/null || echo '?')"
else
  if command -v uv >/dev/null; then
    echo "   installing graphifyy[mcp] via uv…"; uv tool install 'graphifyy[mcp]'
  elif command -v pipx >/dev/null; then
    echo "   installing graphifyy[mcp] via pipx…"; pipx install 'graphifyy[mcp]'
  else
    echo "   !! need uv or pipx. Install uv:  curl -LsSf https://astral.sh/uv/install.sh | sh"
    echo "      then re-run this installer."; exit 1
  fi
fi
# ensure the mcp extra is present even if graphify was already installed
if command -v uv >/dev/null; then uv tool install 'graphifyy[mcp]' >/dev/null 2>&1 || true; fi

# 2) graphify MCP server ------------------------------------------------------
say "2) graphify MCP server"
if command -v claude >/dev/null; then
  SCOPE_ARGS=(--scope user); [ -n "$PROJECT" ] && SCOPE_ARGS=(--scope project)
  # `claude mcp add <name> [flags] -- <cmd> [args]`
  ( [ -n "$PROJECT" ] && cd "$PROJECT"; \
    claude mcp add graphify "${SCOPE_ARGS[@]}" -- graphify-mcp graphify-out/graph.json ) \
    && echo "   registered 'graphify' MCP (${SCOPE_ARGS[*]})" \
    || echo "   (graphify MCP may already be registered — skipping)"
else
  echo "   claude CLI not found; add the MCP manually — see README (mcp-server.json)."
fi

# 3) the /dyflo skill -------------------------------------------------------
say "3) /dyflo skill"
if [ -n "$PROJECT" ]; then
  DEST="$PROJECT/.claude/skills/dyflo"
else
  DEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/dyflo"
fi
mkdir -p "$DEST/references"
cp "$HOME_DIR/skill/SKILL.md" "$DEST/SKILL.md"
cp "$HOME_DIR/skill/references/vendor-ponytail.md" "$DEST/references/vendor-ponytail.md"
# skill points at the engine via $DYFLO_HOME
printf '\n<!-- DYFLO_HOME=%s -->\n' "$HOME_DIR" >> "$DEST/SKILL.md"
echo "   installed skill → $DEST"

# 3b) the doc-cartographer agent ---------------------------------------------
say "3b) doc-cartographer agent"
if [ -n "$PROJECT" ]; then
  ADEST="$PROJECT/.claude/agents"
else
  ADEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents"
fi
mkdir -p "$ADEST"
# resolve the <DYFLO_HOME> placeholder to the real path so the helper command runs
sed "s|<DYFLO_HOME>|$HOME_DIR|g" "$HOME_DIR/agents/doc-cartographer.md" > "$ADEST/doc-cartographer.md"
echo "   installed agent → $ADEST/doc-cartographer.md"

# 4) PATH symlink -------------------------------------------------------------
say "4) launcher on PATH"
if [ "$LINK" = 1 ]; then
  BIN="$HOME/.local/bin"; mkdir -p "$BIN"
  ln -sf "$HOME_DIR/dyflo.sh" "$BIN/dyflo"
  echo "   linked $BIN/dyflo → dyflo.sh"
  case ":$PATH:" in *":$BIN:"*) ;; *) echo "   (add $BIN to your PATH to run 'dyflo' anywhere)";; esac
else
  echo "   skipped (--no-link). Run via: $HOME_DIR/dyflo.sh"
fi

say "done."
echo "Wrap a repo:   cd /path/to/your/project && dyflo --bootstrap"
echo "Then:          dyflo --assign     (route tickets)   or   dyflo --self"
echo "Verify engine: dyflo --check"

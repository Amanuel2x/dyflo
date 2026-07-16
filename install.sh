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
    --runtime) DYFLO_RUNTIME="${2:?--runtime needs claude|cursor}"; shift;;
    --runtime=*) DYFLO_RUNTIME="${1#*=}";;
    --no-link) LINK=0;;
  esac
  shift
done

# runtime abstraction — picks claude vs cursor install targets
. "$HOME_DIR/dyflo/runtime.sh"

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

echo "   runtime: $DYFLO_RUNTIME"

# 2) graphify MCP server ------------------------------------------------------
say "2) graphify MCP server ($DYFLO_RUNTIME)"
SCOPE=user; [ -n "$PROJECT" ] && SCOPE=project
( [ -n "$PROJECT" ] && cd "$PROJECT"; rt_mcp_add graphify "$SCOPE" -- graphify-mcp graphify-out/graph.json ) \
  && echo "   registered 'graphify' MCP ($SCOPE, $DYFLO_RUNTIME)" \
  || echo "   (graphify MCP may already be registered — skipping)"

# 3) Dyflo instructions + commands (per-runtime) ------------------------------
if [ "$DYFLO_RUNTIME" = "cursor" ]; then
  # Cursor: the skill body becomes an always-apply rule; commands become .cursor/commands/*.md
  say "3) /dyflo rule + commands (Cursor)"
  BASE="${PROJECT:-$HOME}"
  RULES="$BASE/.cursor/rules"; CMDS="$BASE/.cursor/commands"
  mkdir -p "$RULES" "$CMDS"
  # dyflo skill → always-apply rule (prepend .mdc frontmatter)
  { printf -- '---\ndescription: Dyflo hybrid dev loop — routing, research stage, lanes\nalwaysApply: true\n---\n\n'; \
    sed "s|\$DYFLO_HOME|$HOME_DIR|g" "$HOME_DIR/skill/SKILL.md"; } > "$RULES/dyflo.mdc"
  # watcher skill → rule too (so the agent knows the autonomous lane exists)
  { printf -- '---\ndescription: Dyflo autonomous watcher — generalist + Tessy (tests) + Quin (QA)\nalwaysApply: false\n---\n\n'; \
    cat "$HOME_DIR/skill/watcher/SKILL.md"; } > "$RULES/dyflo-watcher.mdc"
  # invocable commands
  printf -- '---\ndescription: Run the Dyflo research stage on a ticket\n---\nRun the Dyflo research stage (see the dyflo rule): compute blast radius via graphify, match a pattern from %s/dyflo/patterns/lookup.py, apply the ponytail/security gate, and produce a draft ADR in docs/adr/ or downgrade the ticket to the auto lane.\n' "$HOME_DIR" > "$CMDS/dyflo-research.md"
  printf -- '---\ndescription: Document this repo with graph-derived Mermaid diagrams\n---\nUse the doc-cartographer approach: read the graphify graph, generate Mermaid via %s/dyflo/docs/graph_to_mermaid.py, and write docs/ARCHITECTURE.md — every claim cited to file:line.\n' "$HOME_DIR" > "$CMDS/dyflo-docs.md"
  echo "   installed rules → $RULES/{dyflo,dyflo-watcher}.mdc"
  echo "   installed commands → $CMDS/{dyflo-research,dyflo-docs}.md"
  # doc-cartographer → an agent-requested rule (Cursor has no separate agent registry)
  { printf -- '---\ndescription: Documentation cartographer — architecture docs with Mermaid from the graph\nalwaysApply: false\n---\n\n'; \
    sed "s|<DYFLO_HOME>|$HOME_DIR|g" "$HOME_DIR/agents/doc-cartographer.md"; } > "$RULES/doc-cartographer.mdc"
  echo "   installed doc-cartographer → $RULES/doc-cartographer.mdc"
else
  # Claude Code: skills + agents in ~/.claude
  say "3) /dyflo skill (Claude Code)"
  CH="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  DEST="${PROJECT:+$PROJECT/.claude}"; DEST="${DEST:-$CH}/skills/dyflo"
  mkdir -p "$DEST/references"
  cp "$HOME_DIR/skill/SKILL.md" "$DEST/SKILL.md"
  cp "$HOME_DIR/skill/references/vendor-ponytail.md" "$DEST/references/vendor-ponytail.md"
  printf '\n<!-- DYFLO_HOME=%s -->\n' "$HOME_DIR" >> "$DEST/SKILL.md"
  echo "   installed skill → $DEST"

  say "3a) dyflo-watcher skill (autonomous lane)"
  WDEST="${PROJECT:+$PROJECT/.claude}"; WDEST="${WDEST:-$CH}/skills/dyflo-watcher"
  mkdir -p "$WDEST/templates"
  cp "$HOME_DIR/skill/watcher/SKILL.md" "$WDEST/SKILL.md"
  cp "$HOME_DIR/skill/watcher/README.md" "$WDEST/README.md"
  cp "$HOME_DIR"/skill/watcher/templates/* "$WDEST/templates/"
  echo "   installed skill → $WDEST (engine + generalist/Tessy/Quin briefs)"

  say "3b) doc-cartographer agent"
  ADEST="${PROJECT:+$PROJECT/.claude}"; ADEST="${ADEST:-$CH}/agents"
  mkdir -p "$ADEST"
  sed "s|<DYFLO_HOME>|$HOME_DIR|g" "$HOME_DIR/agents/doc-cartographer.md" > "$ADEST/doc-cartographer.md"
  echo "   installed agent → $ADEST/doc-cartographer.md"
fi

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

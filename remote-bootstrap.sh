#!/usr/bin/env bash
# remote-bootstrap.sh — stand up Dyflo from a BARE remote box (container, cloud VM, CI).
#
# Goes from "nothing installed" to "Dyflo ready" without any interactive step:
# installs uv + graphify, installs Dyflo for the chosen runtime, validates auth,
# and (devbox mode) leaves you a working `dyflo` command.
#
#   curl -fsSL https://raw.githubusercontent.com/Amanuel-Abu/dyflo/master/remote-bootstrap.sh | bash
#   ./remote-bootstrap.sh --mode devbox --runtime cursor
#   ./remote-bootstrap.sh --mode ci --runtime claude --repo owner/name
#
# Modes:
#   devbox  full setup on a persistent box you'll work on (default)
#   ci      lean one-shot for a pipeline: install engine, no PATH symlink, no menu
#
# Auth (no interactive login on a remote box) — set what you use:
#   GITHUB_TOKEN            ticket adapter + PRs (required to route/assign)
#   ANTHROPIC_API_KEY       claude runtime headless
#   CURSOR_API_KEY          cursor runtime headless
# The script validates presence and warns; it never stores or prints secrets.
set -euo pipefail

MODE=devbox
RUNTIME="${DYFLO_RUNTIME:-}"
REPO="${DYFLO_REPO:-}"
DYFLO_REF="${DYFLO_REF:-master}"
SRC_DIR=""          # if run from a checkout, reuse it; else clone
DO_BOOTSTRAP_REPO=1 # devbox: also `dyflo --bootstrap` the target repo if we're in one

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:?}"; shift;;
    --mode=*) MODE="${1#*=}";;
    --runtime) RUNTIME="${2:?}"; shift;;
    --runtime=*) RUNTIME="${1#*=}";;
    --repo) REPO="${2:?}"; shift;;
    --repo=*) REPO="${1#*=}";;
    --ref) DYFLO_REF="${2:?}"; shift;;
    --src) SRC_DIR="${2:?}"; shift;;
    --no-repo-bootstrap) DO_BOOTSTRAP_REPO=0;;
    -h|--help) sed -n '2,26p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
  shift
done

log() { printf '\033[1m[dyflo-bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[dyflo-bootstrap] WARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[dyflo-bootstrap] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 0. sanity: the tools we cannot install for the user ---------------------
command -v git    >/dev/null || die "git is required (install it first)."
command -v python3 >/dev/null || die "python3 is required (3.10+)."
command -v curl   >/dev/null || command -v wget >/dev/null || die "need curl or wget."
[ "$RUNTIME" = "claude" ] || [ "$RUNTIME" = "cursor" ] || [ -z "$RUNTIME" ] \
  || die "--runtime must be claude or cursor (got '$RUNTIME')."

# --- 1. uv (isolated Python tool env) ----------------------------------------
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null; then
  log "installing uv…"
  if command -v curl >/dev/null; then curl -LsSf https://astral.sh/uv/install.sh | sh
  else wget -qO- https://astral.sh/uv/install.sh | sh; fi
  export PATH="$HOME/.local/bin:$PATH"
fi
command -v uv >/dev/null || die "uv install failed; add ~/.local/bin to PATH and retry."
log "uv: $(uv --version)"

# --- 2. graphify (the one hard dependency) -----------------------------------
if ! command -v graphify >/dev/null; then
  log "installing graphify…"
  uv tool install 'graphifyy[mcp]' || die "graphify install failed."
  export PATH="$HOME/.local/bin:$PATH"
fi
log "graphify: $(graphify --version 2>/dev/null || echo '?')"

# --- 3. get the Dyflo source -------------------------------------------------
if [ -z "$SRC_DIR" ]; then
  if [ -f "$(dirname "$0")/install.sh" ] && [ -d "$(dirname "$0")/dyflo" ]; then
    SRC_DIR="$(cd "$(dirname "$0")" && pwd)"        # run from a checkout
  else
    SRC_DIR="${DYFLO_HOME_DIR:-$HOME/.dyflo-src}"
    if [ -d "$SRC_DIR/.git" ]; then
      log "updating Dyflo source in $SRC_DIR…"; git -C "$SRC_DIR" fetch -q && git -C "$SRC_DIR" checkout -q "$DYFLO_REF" && git -C "$SRC_DIR" pull -q --ff-only || true
    else
      log "cloning Dyflo → $SRC_DIR…"
      git clone -q --branch "$DYFLO_REF" https://github.com/Amanuel-Abu/dyflo.git "$SRC_DIR" \
        || die "clone failed (set --src to a local checkout, or check --ref)."
    fi
  fi
fi
log "Dyflo source: $SRC_DIR"

# --- 4. resolve runtime (default = whatever CLI exists, else claude) ----------
if [ -z "$RUNTIME" ]; then
  if command -v cursor-agent >/dev/null; then RUNTIME=cursor
  elif command -v claude >/dev/null; then RUNTIME=claude
  else RUNTIME=claude; warn "no runtime CLI found; defaulting to claude. Install 'claude' or 'cursor-agent' to launch agents."; fi
fi
log "runtime: $RUNTIME"

# --- 5. install Dyflo --------------------------------------------------------
INSTALL_ARGS=(--runtime "$RUNTIME")
[ "$MODE" = "ci" ] && INSTALL_ARGS+=(--no-link)     # CI: no PATH symlink, engine only
DYFLO_RUNTIME="$RUNTIME" bash "$SRC_DIR/install.sh" "${INSTALL_ARGS[@]}"

# --- 6. validate auth (warn, don't block — user may wire it after) -----------
log "checking auth env (nothing is stored or printed)…"
[ -n "${GITHUB_TOKEN:-}" ] && log "  GITHUB_TOKEN set ✓" || warn "GITHUB_TOKEN not set — ticket routing / PRs will fail until it is."
case "$RUNTIME" in
  claude) [ -n "${ANTHROPIC_API_KEY:-}" ] && log "  ANTHROPIC_API_KEY set ✓" || warn "ANTHROPIC_API_KEY not set — headless claude won't run until it is (or run \`claude\` once to log in)." ;;
  cursor) [ -n "${CURSOR_API_KEY:-}" ] && log "  CURSOR_API_KEY set ✓" || warn "CURSOR_API_KEY not set — headless cursor-agent won't run until it is." ;;
esac

# --- 7. engine self-check (proves the install works) -------------------------
log "running engine self-checks…"
DYFLO_RUNTIME="$RUNTIME" bash "$SRC_DIR/dyflo.sh" --check || die "engine self-check failed — install is broken."

# --- 8. devbox: bootstrap the target repo if we're standing in one -----------
if [ "$MODE" = "devbox" ] && [ "$DO_BOOTSTRAP_REPO" = 1 ] && git rev-parse --show-toplevel >/dev/null 2>&1; then
  log "bootstrapping the current repo (graph, hooks, ponytail, config)…"
  DYFLO_RUNTIME="$RUNTIME" bash "$SRC_DIR/dyflo.sh" --bootstrap || warn "repo bootstrap incomplete (see above)."
fi

# --- 9. done -----------------------------------------------------------------
log "done — Dyflo ready ($RUNTIME, mode=$MODE)."
if [ "$MODE" = "ci" ]; then
  echo "CI: run a one-shot job with:  DYFLO_RUNTIME=$RUNTIME bash $SRC_DIR/dyflo.sh --assign ${REPO:+<id>}"
else
  command -v dyflo >/dev/null && echo "Run:  dyflo --assign   |   dyflo --self   |   dyflo --docs" \
    || echo "Run:  bash $SRC_DIR/dyflo.sh --assign   (add ~/.local/bin to PATH for the 'dyflo' shortcut)"
fi

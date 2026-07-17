#!/usr/bin/env bash
# test.sh — Dyflo's own test suite. Run it before opening a PR; CI runs the same thing.
#
#   ./test.sh
#
# No network, no graphify, no gh — everything here is offline and deterministic:
#   1. every Python module compiles
#   2. every module's --self-check passes (auto-discovered, not hardcoded)
#   3. every shell script parses (bash -n)
#   4. shellcheck, if installed (skipped with a note otherwise)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

fail=0
pass=0
note() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }

# 1. Python compiles ----------------------------------------------------------
note "Python compile"
py_files=$(find dyflo -name '*.py' -not -path '*__pycache__*' | sort)
if python3 -m py_compile $py_files 2>/tmp/dyflo-compile.err; then
  ok "$(echo "$py_files" | wc -l | tr -d ' ') modules compile"
else
  bad "compile errors:"; cat /tmp/dyflo-compile.err
fi

# 2. self-checks (auto-discovered) --------------------------------------------
note "Self-checks"
# Any module advertising --self-check, PLUS the adapters selfcheck.py (which runs
# its checks on import from its own dir, no flag). Discovery, not a hardcoded list:
# a new module with a --self-check is picked up automatically.
sc_files=$( { grep -rl -- '--self-check' dyflo --include='*.py' 2>/dev/null;
              find dyflo -name 'selfcheck.py'; } | grep -v __pycache__ | sort -u )
for f in $sc_files; do
  # some modules run their self-check from a sibling dir (adapters/selfcheck.py)
  if [ "$(basename "$f")" = "selfcheck.py" ]; then
    if ( cd "$(dirname "$f")" && python3 "$(basename "$f")" ) >/tmp/dyflo-sc.out 2>&1; then
      ok "$f"; else bad "$f"; cat /tmp/dyflo-sc.out; fi
  else
    if python3 "$f" --self-check >/tmp/dyflo-sc.out 2>&1; then
      ok "$f"; else bad "$f"; cat /tmp/dyflo-sc.out; fi
  fi
done

# 3. shell syntax -------------------------------------------------------------
note "Shell syntax (bash -n)"
sh_files=$(find . -name '*.sh' -not -path './.git/*' | sort)
for s in $sh_files; do
  if bash -n "$s" 2>/tmp/dyflo-shn.err; then ok "$s"; else bad "$s"; cat /tmp/dyflo-shn.err; fi
done

# 4. shellcheck (optional) ----------------------------------------------------
note "Shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # Excludes, each deliberate:
  #   SC1091 — don't follow sourced files (runtime.sh is sourced, not run)
  #   SC2086/SC2206/SC2207 — intentional word-splitting of user-DECLARED runtime
  #            flags in runtime.sh (a custom CLI's "exec --full-auto" must split)
  #   SC2015 — `log ✓ || warn` in remote-bootstrap: log can't fail, so it's fine
  if shellcheck -e SC1091,SC2086,SC2206,SC2207,SC2015 $sh_files 2>/tmp/dyflo-shc.out; then
    ok "shellcheck clean"; else bad "shellcheck findings:"; cat /tmp/dyflo-shc.out; fi
else
  printf '  \033[33m—\033[0m shellcheck not installed (skipped)\n'
fi

echo
if [ "$fail" -eq 0 ]; then
  note "ALL GREEN — $pass checks passed."
else
  note "FAILED — $fail failing, $pass passed."
fi
exit "$fail"

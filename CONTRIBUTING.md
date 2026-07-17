# Contributing to Dyflo

Thanks for hacking on Dyflo. It's meant to be forked and bent to your own workflow —
here's how to change it without breaking it.

## Run the tests

One command, before you open a PR. CI runs the exact same thing.

```bash
./test.sh
```

It's fully offline — no `graphify`, no `gh`, no network. It checks:

1. **every Python module compiles** (`py_compile`)
2. **every module's `--self-check` passes** (auto-discovered — see below)
3. **every shell script parses** (`bash -n`)
4. **shellcheck** is clean (skipped locally if you don't have it; CI always runs it — `brew install shellcheck`)

Green means you're good. CI runs it on Python 3.10–3.13.

## The self-check convention

Every engine module carries its own test as a `--self-check` flag:

```bash
python3 dyflo/router.py --self-check
python3 dyflo/config.py --self-check
```

`test.sh` **discovers** these by grep, so **a new module with a `--self-check` is
picked up automatically** — you don't edit CI. If you add a module with real logic
(a branch, a parser, a money/security path), give it a `--self-check` that fails if
the logic breaks. That's the whole test strategy: no framework, no fixtures, one
runnable check living next to the code it guards.

`dyflo --check` runs the same self-checks plus the runtime line (it needs `graphify`
installed); `./test.sh` is the graphify-free version CI uses.

## Layout, briefly

- `dyflo.sh` — the launcher / menu (bash)
- `dyflo/runtime.sh` — the claude/cursor/custom-runtime abstraction (bash)
- `dyflo/*.py` — the engine: `router`, `config`, `adr`, `status`, `events`,
  `patterns/lookup`, `docs/graph_to_mermaid`, `adapters/`
- `skill/` — the `/dyflo` + `/dyflo-watcher` skills
- `test.sh` — this suite

## House style

- **Keep it lazy.** Shortest thing that works; reuse what's there; no abstraction
  for one caller. If you defer something, mark it with a `ponytail:` comment naming
  the ceiling and the upgrade path.
- **Portable bash.** Target macOS `bash 3.2` (no `${arr[@]}` splat on an empty array
  under `set -u` — use the `${arr[@]+"${arr[@]}"}` idiom). `test.sh` catches most of
  this via shellcheck.
- **Don't touch the invariant.** The router only ever *downgrades*; unlabeled work
  never runs unattended. Any change there needs a self-check proving it holds.
- **Adding a ticket source?** Drop `dyflo/adapters/<name>.py` exposing
  `list_open_tickets(label)` + `set_label(id, label)` returning the envelope
  `{id, title, body, labels, url}`. No core changes.

## PRs

Small, focused, green. Say what you changed and why in the description. If it changes
behavior, note it — Dyflo is used headless, so surprises are expensive.

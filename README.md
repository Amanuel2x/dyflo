# Dyflo

A repository-agnostic hybrid dev loop. Point it at **any** project and it routes
incoming tickets into two lanes:

- **Autonomous** — small, mundane, labeled `auto` → a headless watcher does the
  ticket, opens a PR, exits. No human.
- **HITL** — big or risky, labeled `hitl` (or unlabeled) → a **research stage**
  maps the system, computes **blast radius**, picks an **architecture pattern**,
  and emits a **draft ADR** you approve. Then a human-gated plan → implement →
  release flow.

One launcher (`dyflo`) is the door: from it you **assign** work (hand off a
ticket, it routes) or **do it yourself** (an interactive session with the codebase
graph, ponytail, and TRIP all loaded).

```
ticket → adapter → ROUTER (by label)
                     ├── auto ─────────────► AUTONOMOUS lane (watcher: 1 ticket → PR → exit)
                     └── hitl / unlabeled ─► RESEARCH stage
                                               │ no pattern needed → relabel auto ─┐
                                               ▼                                    │
                                            draft ADR → 👤 approve → /TRIP-1-plan …│
                                               ▲────────────────────────────────────┘
```

The router **only ever downgrades**. An unlabeled ticket never lands in the
autonomous lane unattended — it goes through research, which may *downgrade* a
small change to `auto`, but nothing escalates the other way. That's the one safety
invariant.

## What powers each part

| Part | Tool | Role |
|---|---|---|
| Persistent memory + blast radius | [Graphify](https://github.com/Graphify-Labs/graphify) | tree-sitter code graph; `affected`/`path` = "what breaks if I change X" |
| Pattern selection | vendored catalog | GoF · Fowler PoEAA · microservices.io · Hohpe EIP index; live fallback on a miss |
| Autonomous loop | `dyflo-watcher` (ships with Dyflo) | polls the source, launches headless `claude -p`, one-ticket-one-PR; generalist + Tessy (tests) + Quin (QA) briefs |
| Code-writing discipline | [ponytail](https://github.com/DietrichGebert/ponytail) | "lazy senior dev" ruleset, vendored into the repo for the headless lane |
| Human-gated flow | [TRIP](https://github.com/PiLastDigit/TRIP-workflow) | `/TRIP-1-plan → 2-implement → 3-release`, seeded by the ADR |

Dyflo itself is the **router** and the **research stage** — the two pieces none
of those tools provide — plus the glue that makes them one loop.

> **New to these tools?** [`docs/EXTERNAL-TOOLS.md`](docs/EXTERNAL-TOOLS.md)
> explains each one with a concrete before/after example (e.g. what ponytail turns
> a bloated cache class into, what Graphify's blast radius looks like).

## Install

```bash
git clone <this-repo> ~/dyflo && cd ~/dyflo
./install.sh              # graphify + MCP + /dyflo skill + `dyflo` on PATH
```

Prereqs: `uv` (or `pipx`) for Graphify, `gh` for the GitHub adapter, the `claude`
CLI. The installer fetches Graphify for you. Ponytail and TRIP are optional but
recommended — install their plugins for the full loop.

Project-scoped skill instead of global:

```bash
./install.sh --project /path/to/your/project
```

## Runtimes: Claude Code or Cursor

Dyflo's engine (router, research, catalog, docs, watcher) is a plain Python/shell
toolkit — it doesn't care which coding-agent runtime drives it. Two are supported:

```bash
./install.sh                      # Claude Code (default; skills + agents in ~/.claude)
./install.sh --runtime cursor     # Cursor (rules + commands in .cursor/, MCP in .cursor/mcp.json)
./install.sh --runtime cursor --project /path/to/repo   # project-scoped Cursor install
```

What each install writes:

| | Claude Code | Cursor |
|---|---|---|
| Instructions | `~/.claude/skills/dyflo/` | `.cursor/rules/dyflo.mdc` (always-apply) |
| Watcher | `~/.claude/skills/dyflo-watcher/` | `.cursor/rules/dyflo-watcher.mdc` |
| Doc agent | `~/.claude/agents/doc-cartographer.md` | `.cursor/rules/doc-cartographer.mdc` |
| Commands | Claude slash commands | `.cursor/commands/dyflo-research.md`, `dyflo-docs.md` |
| Graphify MCP | `claude mcp add` | `.cursor/mcp.json` |
| Headless agent | `claude -p --dangerously-skip-permissions` | `cursor-agent -p --force --sandbox disabled` |

Pick the runtime per repo via `dyflo.config.json` (`"runtime": "cursor"`), or override
anywhere with the `DYFLO_RUNTIME` env var. The launcher, the research stage, and the
watcher all honor it — so the **same repo** can be worked with Claude at home and
Cursor at work.

**Models.** Cursor exposes whatever your plan offers (`cursor-agent --list-models`).
Set the agent's model with `DYFLO_MODEL` (e.g. `DYFLO_MODEL=gpt-5`). This also unlocks
real **maker≠checker**: run the coding agent on one model family and a review pass on
another (e.g. author with Claude, review with GPT or Gemini) — a stronger independent
check than same-model self-review.

> Cursor prereqs: the `cursor-agent` CLI (`curl https://cursor.com/install -fsS | bash`)
> and a signed-in Cursor account (or `CURSOR_API_KEY` for headless/CI).

## Run it in a remote environment (container, cloud VM, CI)

One script goes from a **bare box** to a working Dyflo — no interactive login, auth
from env vars:

```bash
# on the remote box, inside your repo:
curl -fsSL https://raw.githubusercontent.com/Amanuel-Abu/dyflo/master/remote-bootstrap.sh | bash
```

It installs `uv` + `graphify`, clones/uses Dyflo, installs it for your runtime,
validates auth, self-checks, and (devbox mode) bootstraps the current repo. Two modes:

```bash
./remote-bootstrap.sh --mode devbox --runtime cursor   # persistent box you'll work on (default)
./remote-bootstrap.sh --mode ci     --runtime claude   # lean one-shot for a pipeline
```

Auth (set what you use — the script warns on missing, never stores/prints secrets):

| Env var | For |
|---|---|
| `GITHUB_TOKEN` | ticket adapter + PRs |
| `ANTHROPIC_API_KEY` | headless `claude` runtime |
| `CURSOR_API_KEY` | headless `cursor-agent` runtime |

**CI:** a ready workflow is at [`.github/workflows/dyflo.yml`](.github/workflows/dyflo.yml)
— copy it into your repo, add the secrets, and Dyflo triages tickets on a schedule or
on demand. No TTY needed anywhere; the launcher detects a non-interactive shell and
never blocks on a prompt.

## Wrap a repo

From inside the project you want to run Dyflo on:

```bash
cd /path/to/your/project
dyflo --bootstrap       # build the graph, install re-index hook, vendor ponytail, write config, ensure labels
```

Then:

```bash
dyflo --assign          # route all open tickets into auto / hitl lanes
dyflo --assign 42       # run the research stage on ticket #42 → draft ADR (or downgrade)
dyflo --self            # open an equipped interactive session and work it yourself
dyflo --docs            # document the repo → docs/ARCHITECTURE.md with Mermaid diagrams
dyflo --docs auth       # same, focused on a subsystem or entry point
dyflo --check           # run the engine self-checks
```

## Documentation from the graph

`dyflo --docs` runs the **doc-cartographer** agent: it reads the codebase's
knowledge graph and writes `docs/ARCHITECTURE.md` with Mermaid diagrams generated
from the *real* structure — a system map (subsystems), a module dependency map, and
call-flow diagrams per entry point — every claim cited to `file:line`, nothing from
memory. Diagrams are portable Mermaid (render in GitHub/Obsidian), produced by
`dyflo/docs/graph_to_mermaid.py` from `graphify-out/graph.json`. Distinct from a
README refresher: this builds architecture understanding from scratch and is safe to
re-run as the code evolves (the graph re-indexes on commit).

## Configure it around anything

`dyflo --bootstrap` writes `dyflo.config.json` in the target repo:

```json
{
  "adapter": "github",
  "labels": { "auto": "auto", "hitl": "hitl" }
}
```

- **Different labels?** Rename `auto`/`hitl` to whatever your team uses.
- **Different ticket source?** Set `adapter` to another name and drop a
  `dyflo/adapters/<name>.py` exposing `list_open_tickets(label)` and
  `set_label(id, label)` that return the normalized envelope
  `{id, title, body, labels, url}`. GitHub ships built-in; Jira/Linear/flat-file
  are each one small adapter file — no core changes. See
  `dyflo/adapters/github.py` as the template.
- **Different repo for the adapter?** `export DYFLO_REPO=owner/name` (GitHub) or
  set it per your adapter.

## The research stage in detail

For every `hitl`/unlabeled ticket, Dyflo:

1. **Blast radius** — `graphify affected "<symbol>"` / `path` over what the ticket
   touches: how far it ripples, which architectural hotspots (`god_nodes`) are in
   scope, whether it sits on a boundary to another system.
2. **Pattern match** — `dyflo/patterns/lookup.py` scores the ticket against the
   vendored catalog; a hit is cited to its canonical URL, a miss falls back to live
   retrieval for that ticket only.
3. **Ponytail gate** — *does this even need a pattern?* A small local change with a
   tight blast radius emits `NO_PATTERN`, gets relabeled `auto`, and drops to the
   autonomous lane. No ceremony.
4. **Draft ADR** — otherwise writes `docs/adr/NNN-<slug>.md` (adr.github.io format):
   context → decision drivers (the blast radius, cited `file:line`) → the chosen
   pattern → consequences. **This ADR is both the research output and the artifact
   you approve** — it seeds `/TRIP-1-plan`.

## Layout

```
dyflo.sh              launcher (symlinked to `dyflo`)
install.sh              installer
mcp-server.json         graphify MCP block, for manual registration
dyflo/                the engine
  router.py             label → lane (with the no-escalation invariant)
  adapters/             ticket-source adapters (github built-in) + selfcheck
  patterns/             catalog.json (4 sources) + lookup.py matcher
  docs/                 graph_to_mermaid.py — graph.json → portable Mermaid
  vendor-ponytail.sh    put ponytail's ruleset into the target repo's AGENTS.md
agents/                 doc-cartographer.md — the documentation agent
skill/                  the /dyflo Claude Code skill (SKILL.md + references)
  watcher/              /dyflo-watcher — the autonomous lane (engine + generalist/Tessy/Quin briefs)
docs/adr/               where research writes ADRs (template.md included)
```

## Credits

Dyflo composes several open tools — install their plugins for the full experience:
[Graphify](https://github.com/Graphify-Labs/graphify),
[ponytail](https://github.com/DietrichGebert/ponytail) (MIT — a copy of its `AGENTS.md`
is bundled in `dyflo/vendor/` so the autonomous lane works on a bare box; see
`dyflo/vendor/ponytail-LICENSE`), and
[TRIP](https://github.com/PiLastDigit/TRIP-workflow). See
[`docs/EXTERNAL-TOOLS.md`](docs/EXTERNAL-TOOLS.md) for what each does.

## Non-goals

Dyflo never merges PRs, never schedules cron/launchd, and never escalates a
ticket into unattended execution. It dispatches; humans merge; the watcher loops.

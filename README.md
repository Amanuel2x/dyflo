# DevFlow

A repository-agnostic hybrid dev loop. Point it at **any** project and it routes
incoming tickets into two lanes:

- **Autonomous** — small, mundane, labeled `auto` → a headless watcher does the
  ticket, opens a PR, exits. No human.
- **HITL** — big or risky, labeled `hitl` (or unlabeled) → a **research stage**
  maps the system, computes **blast radius**, picks an **architecture pattern**,
  and emits a **draft ADR** you approve. Then a human-gated plan → implement →
  release flow.

One launcher (`devflow`) is the door: from it you **assign** work (hand off a
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
| Autonomous loop | [agent-orchestration](https://github.com/Amanuel2x/agent-orchestration) watcher | polls the source, launches headless `claude -p`, one-ticket-one-PR |
| Code-writing discipline | [ponytail](https://github.com/DietrichGebert/ponytail) | "lazy senior dev" ruleset, vendored into the repo for the headless lane |
| Human-gated flow | [TRIP](https://github.com/PiLastDigit/TRIP-workflow) | `/TRIP-1-plan → 2-implement → 3-release`, seeded by the ADR |

DevFlow itself is the **router** and the **research stage** — the two pieces none
of those tools provide — plus the glue that makes them one loop.

## Install

```bash
git clone <this-repo> ~/devflow && cd ~/devflow
./install.sh              # graphify + MCP + /devflow skill + `devflow` on PATH
```

Prereqs: `uv` (or `pipx`) for Graphify, `gh` for the GitHub adapter, the `claude`
CLI. The installer fetches Graphify for you. Ponytail and TRIP are optional but
recommended — install their plugins for the full loop.

Project-scoped skill instead of global:

```bash
./install.sh --project /path/to/your/project
```

## Wrap a repo

From inside the project you want to run DevFlow on:

```bash
cd /path/to/your/project
devflow --bootstrap       # build the graph, install re-index hook, vendor ponytail, write config, ensure labels
```

Then:

```bash
devflow --assign          # route all open tickets into auto / hitl lanes
devflow --assign 42       # run the research stage on ticket #42 → draft ADR (or downgrade)
devflow --self            # open an equipped interactive session and work it yourself
devflow --docs            # document the repo → docs/ARCHITECTURE.md with Mermaid diagrams
devflow --docs auth       # same, focused on a subsystem or entry point
devflow --check           # run the engine self-checks
```

## Documentation from the graph

`devflow --docs` runs the **doc-cartographer** agent: it reads the codebase's
knowledge graph and writes `docs/ARCHITECTURE.md` with Mermaid diagrams generated
from the *real* structure — a system map (subsystems), a module dependency map, and
call-flow diagrams per entry point — every claim cited to `file:line`, nothing from
memory. Diagrams are portable Mermaid (render in GitHub/Obsidian), produced by
`devflow/docs/graph_to_mermaid.py` from `graphify-out/graph.json`. Distinct from a
README refresher: this builds architecture understanding from scratch and is safe to
re-run as the code evolves (the graph re-indexes on commit).

## Configure it around anything

`devflow --bootstrap` writes `devflow.config.json` in the target repo:

```json
{
  "adapter": "github",
  "labels": { "auto": "auto", "hitl": "hitl" }
}
```

- **Different labels?** Rename `auto`/`hitl` to whatever your team uses.
- **Different ticket source?** Set `adapter` to another name and drop a
  `devflow/adapters/<name>.py` exposing `list_open_tickets(label)` and
  `set_label(id, label)` that return the normalized envelope
  `{id, title, body, labels, url}`. GitHub ships built-in; Jira/Linear/flat-file
  are each one small adapter file — no core changes. See
  `devflow/adapters/github.py` as the template.
- **Different repo for the adapter?** `export DEVFLOW_REPO=owner/name` (GitHub) or
  set it per your adapter.

## The research stage in detail

For every `hitl`/unlabeled ticket, DevFlow:

1. **Blast radius** — `graphify affected "<symbol>"` / `path` over what the ticket
   touches: how far it ripples, which architectural hotspots (`god_nodes`) are in
   scope, whether it sits on a boundary to another system.
2. **Pattern match** — `devflow/patterns/lookup.py` scores the ticket against the
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
devflow.sh              launcher (symlinked to `devflow`)
install.sh              installer
mcp-server.json         graphify MCP block, for manual registration
devflow/                the engine
  router.py             label → lane (with the no-escalation invariant)
  adapters/             ticket-source adapters (github built-in) + selfcheck
  patterns/             catalog.json (4 sources) + lookup.py matcher
  docs/                 graph_to_mermaid.py — graph.json → portable Mermaid
  vendor-ponytail.sh    put ponytail's ruleset into the target repo's AGENTS.md
agents/                 doc-cartographer.md — the documentation agent
skill/                  the /devflow Claude Code skill (SKILL.md + references)
docs/adr/               where research writes ADRs (template.md included)
```

## Non-goals

DevFlow never merges PRs, never schedules cron/launchd, and never escalates a
ticket into unattended execution. It dispatches; humans merge; the watcher loops.

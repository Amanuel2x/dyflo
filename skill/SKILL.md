---
name: devflow
description: |
  Repository-agnostic hybrid dev loop. Routes an incoming ticket (GitHub Issue,
  Jira, or any adapter) into one of two lanes by label: an AUTONOMOUS lane
  (small/mundane work → the agent-orchestration watcher runs it headless,
  one-ticket-one-PR-exit) or a HITL lane (big/risky work → a research stage
  computes blast radius and picks an architecture pattern, emits a draft ADR you
  approve, then TRIP plans/implements/releases with human gates). Use when the
  user says "devflow", "assign this ticket", "research this issue before I plan
  it", "route this ticket", "set up the hybrid agent loop", "run the research
  stage", or wants the launcher that turns on assign-or-do-it-yourself. The
  research stage is the core: it fuses Graphify blast radius + the vendored
  pattern catalog and MAY conclude "no pattern needed" — downgrading a small
  ticket straight to the autonomous lane with zero ceremony. Non-goals: it does
  not merge PRs, does not schedule cron/launchd, and never escalates a small
  ticket into unattended execution — the research stage only ever downgrades.
---

# DevFlow — hybrid autonomous + HITL dev loop (`/devflow`)

One entry point wraps any repo. From it you either **assign** work (hand off a
ticket, the system routes it) or **do the work yourself** (an interactive session
with Graphify + ponytail + TRIP loaded). Small work runs headless; big work runs
through research → your approval → TRIP.

```
ticket → adapter → ROUTER (by label)
                     ├── label:auto ───────────────► AUTONOMOUS LANE (watcher: 1 ticket → PR → exit)
                     └── label:hitl / unlabeled ───► RESEARCH STAGE (this skill's core)
                                                        │ no pattern needed → relabel auto ─┐
                                                        ▼                                   │
                                                     draft ADR → 👤 approve → /TRIP-1-plan …│
                                                        ▲───────────────────────────────────┘
```

## The lanes

| Lane | Label | Who runs it | Human gate |
|------|-------|-------------|------------|
| Autonomous | `auto` | `agent-orchestration` watcher, headless `claude -p` | none (PR only; a human merges — run `/code-review <pr#>` first, plus `/security-review` if the diff touches auth/secrets/validation) |
| HITL | `hitl` / unlabeled | research stage → TRIP | ADR approval, plan, diff |

The router **only downgrades** (research may relabel `hitl`→`auto`). It never
auto-escalates a small ticket into unattended execution. That is the one safety
invariant of the whole system.

## Prerequisites (bootstrap once per repo — `devflow.sh` does this)

1. **Graph:** `graphify update .` at repo root → `graphify-out/graph.json`. Enable
   the `graphify` MCP server (install.sh registers it; `mcp-server.json` has the
   block for manual setup). Keep it current: `graphify hook install` (post-commit
   re-index, AST-only).
2. **Ponytail in the autonomous lane:** vendor ponytail's `AGENTS.md` into the repo
   (the watcher go-prompt already treats CLAUDE.md/AGENTS.md as mandatory). See the
   `vendor-ponytail` reference.
3. **Labels:** `auto`, `hitl` exist on the ticket source.
4. **Watcher:** `agent-orchestration` set up for the `auto` label (that skill's job).

## The research stage (run for every `hitl`/unlabeled ticket)

This is the component that exists in none of the upstream tools. Given a ticket
envelope `{id, title, body, labels}`, produce EITHER a `NO_PATTERN` downgrade OR a
draft ADR. Steps:

### 1 — Blast radius (Graphify)
Identify the symbols/files the ticket names or clearly touches. For each, ask the
graph what ripples:
```bash
graphify affected "<symbol>"      # reverse traversal: what breaks if this changes
graphify path "<A>" "<B>"         # how two things connect
graphify explain "<symbol>"       # a node and its neighbors
```
Or via the MCP tools in an interactive session: `get_pr_impact`, `query_graph`,
`get_neighbors`, `shortest_path`, `god_nodes`. Record: how many nodes are impacted, whether any
**god node** (architectural hotspot) is in scope, and whether the change sits on a
**boundary to another system**. This is the decision driver — small local blast
radius vs. wide cross-module ripple is what separates the two exits below.

### 2 — Pattern match (vendored catalog, live fallback)
```bash
python3 "$DEVFLOW_HOME/devflow/patterns/lookup.py" "<ticket title + body + blast-radius summary>"
```
(`DEVFLOW_HOME` is the DevFlow repo path — install.sh stamps it in a comment at the
bottom of this file.)
- A ranked hit (score ≥ threshold) → candidate pattern(s), each cited to a
  canonical URL (GoF / Fowler PoEAA / microservices.io / Hohpe EIP).
- A **MISS** → fall back to live retrieval for THIS ticket only: `WebSearch` and/or
  context7 for current best-practice patterns. Do not scrape the catalog sources —
  the vendored index already covers them; live retrieval is for genuinely novel shapes.

### 3 — Ponytail gate (mandatory — the escape hatch)
**Security carve-out first:** if the ticket or its blast radius touches auth,
secrets/credentials, or input validation, it stays `hitl` regardless of size —
small diff ≠ safe diff, and declining to downgrade is not escalation, so the
only-downgrades invariant holds. Run `/security-review` as part of the HITL pass.

Otherwise ask the ponytail question: **does this change even need a
pattern?** A small, local, single-module change with a tight blast radius and no
god node in scope does NOT. If so:
- Emit `NO_PATTERN` with a one-line reason.
- **Relabel the ticket `auto`** on the ticket source and hand it to the autonomous
  lane. Stop. No ADR, no human gate.
- (Per config: post a one-line note so the reclassification is visible.)

This gate is what keeps the research stage from becoming a ceremony generator that
staples "Strategy Pattern" onto a null check. Bias toward downgrading — most tickets
are small.

### 4 — Draft ADR (only if a pattern is warranted)
Delegate to the `backend-architect` agent if installed (design/trade-off analysis
is its job) — or, for a lightweight ticket, write it directly. The ADR uses the
adr.github.io format:

```markdown
# ADR NNN: <title>
## Status
Proposed  <!-- becomes Accepted at the human gate -->
## Context
<the ticket's need, in one paragraph>
## Decision drivers (blast radius)
<from Graphify: impacted nodes, god nodes, boundaries — cite file:line>
## Decision
Adopt **<Pattern>** (<category>). <one paragraph why it fits THIS blast radius.>
Source: <canonical URL>
## Consequences
<tradeoffs — pull the pattern's `tradeoff` line and make it concrete here>
```

Write it to `docs/adr/NNN-<slug>.md` in the repo (TRIP reads repo docs; a file on
disk is the clean seam). **This ADR is both the research deliverable and the artifact
the human approves — it seeds `/TRIP-1-plan`.**

### 5 — Hand to HITL
Surface the draft ADR for approval. On approval, `/TRIP-1-plan <the ADR>` picks it
up; the human gates then hold at plan and at diff, and `/TRIP-3-release` opens the PR.

## Reference
- `$DEVFLOW_HOME/devflow/patterns/catalog.json` — vendored pattern index (4 canonical sources).
- `$DEVFLOW_HOME/devflow/patterns/lookup.py` — matcher + `--self-check` (ranking + miss).
- `$DEVFLOW_HOME/devflow/adapters/` — ticket-source adapters (agnostic ingestion; GitHub first).
- `references/vendor-ponytail.md` (beside this file) — how ponytail reaches the autonomous lane.
- `agent-orchestration` skill — the autonomous watcher (separate skill).
- TRIP skills (`/TRIP-1-plan`, `/TRIP-2-implement`, `/TRIP-3-release`) — the HITL lane.

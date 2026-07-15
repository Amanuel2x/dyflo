# The external tools Dyflo composes

Dyflo itself is small — a **router** and a **research stage**. Almost all the
horsepower comes from five external pieces we installed and wired together. This
page explains what each one does, with a concrete before/after example.

Think of it like a kitchen: Dyflo is the *head chef* deciding what happens and in
what order. These tools are the specialist staff — one keeps the pantry mapped, one
enforces "don't over-cook it," one runs the line unattended, one is the recipe book
of proven techniques, one is the careful sous-chef for the big dishes.

| Tool | One-line job | Where it plugs into Dyflo |
|---|---|---|
| **Graphify** | Persistent map of the codebase + "what breaks if I change X" | The research stage's blast radius; the doc agent's diagrams |
| **Ponytail** | Forces the *smallest* solution that works | Rides inside every code-writing agent, both lanes |
| **agent-orchestration** (watcher) | Runs coding agents unattended, one ticket → one PR | The autonomous lane |
| **TRIP** | Human-gated plan → implement → release | The HITL lane |
| **Codex** | Second-opinion reviewer inside TRIP | TRIP's review loops |

---

## 1. Graphify — the codebase's memory and blast radius

**What it does.** Graphify uses tree-sitter to parse your code (≈40 languages, no
API key needed) into a **knowledge graph**: every function/class/file is a node,
every call/import/inheritance is an edge. Once built, you can ask it structural
questions instantly instead of grepping. Its killer feature for Dyflo is
**blast radius** — "if I change this function, what else is affected?"

**How Dyflo uses it.** The research stage runs `graphify affected` on whatever a
ticket touches to measure how far a change ripples — that's the signal that decides
"small local change → autonomous lane" vs. "wide cross-module change → needs a
plan." The doc agent turns the same graph into Mermaid diagrams.

**Example — "what depends on this function?"**

Before (what you'd do by hand — grep and hope you caught every caller):

```bash
$ grep -rn "price(" .        # miss aliased imports, indirect calls, re-exports…
pay.py:2:    total = price(cart)
```

After (Graphify, from the real graph):

```bash
$ graphify affected "price"
Affected nodes for price()
Depth: 2
- checkout() [calls] pay.py:L1
```

And the connection between any two symbols:

```bash
$ graphify path "checkout" "charge"
Shortest path (1 hops):
  checkout() --calls [EXTRACTED]--> charge()
```

`[EXTRACTED]` means Graphify read that edge directly from the source (vs.
`INFERRED`, which it resolved) — so you know what's fact vs. deduction.

> Install: `uv tool install 'graphifyy[mcp]'`. Build a graph: `graphify update .`
> Repo: https://github.com/Graphify-Labs/graphify

---

## 2. Ponytail — the "lazy senior dev" that refuses to over-build

**What it does.** Ponytail is a *ruleset*, not code. It injects a decision ladder
into a coding agent: before writing anything, stop at the first rung that holds —
(1) does this need to exist? (2) is it already in the codebase? (3) does the
standard library do it? (4) a native feature? (5) an installed dependency? (6) can
it be one line? Only then write the minimum. The result is smaller diffs and fewer
speculative abstractions.

**How Dyflo uses it.** Both lanes write code, and unattended agents especially tend
to over-engineer. Ponytail is active in the interactive (HITL) session via its
plugin hooks, and Dyflo **vendors ponytail's ruleset into the target repo's
`AGENTS.md`** so the headless autonomous agents obey it too (their `claude -p`
processes don't get the hook, but they do read `AGENTS.md`).

**Example — "add a cache for these API responses."**

Before (a typical eager first draft — a whole cache class nobody asked for):

```python
class ResponseCache:
    def __init__(self, max_size=1000, ttl=300):
        self._store = {}
        self._times = {}
        self.max_size = max_size
        self.ttl = ttl

    def get(self, key):
        if key in self._store and time.time() - self._times[key] < self.ttl:
            return self._store[key]
        return None

    def set(self, key, value):
        if len(self._store) >= self.max_size:
            oldest = min(self._times, key=self._times.get)
            del self._store[oldest]; del self._times[oldest]
        self._store[key] = value
        self._times[key] = time.time()

cache = ResponseCache()
def fetch(url):
    hit = cache.get(url)
    if hit is not None:
        return hit
    result = _do_fetch(url)
    cache.set(url, result)
    return result
```

After (ponytail — rung 3, the standard library already does this):

```python
from functools import lru_cache

@lru_cache(maxsize=1000)
def fetch(url):
    return _do_fetch(url)
# skipped: custom cache class, add when lru_cache measurably falls short.
```

Same behavior, ~30 lines deleted, one battle-tested primitive instead of a
hand-rolled eviction bug waiting to happen.

> Installed as a Claude Code plugin (v4.8.3). Modes: `/ponytail lite|full|ultra`.
> Repo: https://github.com/DietrichGebert/ponytail

---

## 3. agent-orchestration — the unattended watcher (the "autonomous lane")

**What it does.** A small Python engine that polls your ticket source (GitHub
issues with a given label) in a loop. When there's eligible work and the agent has
no open PR of its own, it launches a **fresh headless Claude Code session**
(`claude -p`) with a one-ticket mission brief. That session does exactly one ticket,
opens a PR, and exits. The watcher relaunches it for the next. It also self-heals:
if its own PR's CI fails (or the PR goes CONFLICTING), it fixes that first.

**How Dyflo uses it.** This *is* the autonomous lane. Tickets labeled `auto` (or
downgraded there by the research stage) get worked entirely without a human — the
human only reviews and merges the resulting PR.

**Example — the loop, in plain terms:**

Before (you, manually, all day):

```
see issue #42 → open editor → fix it → run tests → open PR → repeat for #43, #44…
```

After (the watcher, unattended):

```
[10:00:01] Backend Watcher started. Polling owner/repo (label: auto) every 60s.
[10:00:01] Backend on the prowl — 3 eligible.
[10:00:02] Launching Backend:  #42 — Fix null check in parser
           → (headless session: reads #42, branches, fixes, tests, opens PR, exits)
[10:14:20] Backend session ended (exit 0).
[10:14:21] Backend on the prowl — 2 eligible.   # picks #43 next…
```

The discipline ("one ticket, never merge, evidence in the PR body") lives in the
mission brief; the engine just drives the loop.

> Set up per-repo via the `agent-orchestration` skill. Runs as `python3 <name>-watcher.py`.
> Repo: https://github.com/Amanuel2x/agent-orchestration

---

## 4. TRIP — the human-gated flow (the "HITL lane")

**What it does.** TRIP is three numbered skills that structure serious work with
**human checkpoints**: `/TRIP-1-plan` (think first — a plan you approve),
`/TRIP-2-implement` (code it, with a testing gate and a Codex review loop), and
`/TRIP-3-release` (version, changelog, tag, merge, push). It keeps an `ARCHI.md`
file as the agent's long-term memory of your architecture so it doesn't re-learn the
codebase every session.

**How Dyflo uses it.** This *is* the HITL lane. When the research stage produces a
draft ADR and you approve it, that ADR seeds `/TRIP-1-plan`. The human gates hold at
the plan and again at the diff — nothing ships without your sign-off.

**Example — big change, gated:**

Before (one giant "please add auth" prompt → agent free-runs → you get a 40-file
diff and hope):

```
> add authentication to the app
  …800 lines later, across 40 files, untested, unreviewed…
```

After (TRIP, checkpoint by checkpoint):

```
> /TRIP-1-plan  add authentication              # seeded by the approved ADR
  → plan written, Codex reviews it, you APPROVE   👤 gate 1
> /TRIP-2-implement @auth-plan.md
  → code → testing gate (lint/types/tests) → Codex code review → you review diff  👤 gate 2
> /TRIP-3-release
  → version bump, changelog, tag, ff-merge, push
```

You stay in control at every step instead of judging one enormous diff after the
fact.

> Installed as skills (`~/.claude/skills/TRIP-*`), v2.1.0.
> Repo: https://github.com/PiLastDigit/TRIP-workflow

---

## 5. Codex — the second-opinion reviewer inside TRIP

**What it does.** OpenAI's Codex CLI, used by TRIP as an *independent* reviewer. The
maker (your main agent) shouldn't grade its own homework, so TRIP hands the plan and
the diff to Codex for a separate pass — `codex-plan-review`, `codex-code-review`,
`codex-implement`, `codex-ask`. Reviews iterate (`start → REQUEST_CHANGES → fix →
APPROVED`) until they converge.

**How Dyflo uses it.** Indirectly — it's what makes TRIP's review loops a real
second set of eyes rather than the same model re-reading its own work. If Codex
isn't installed, TRIP falls back to self-review; with it, the HITL lane gets
maker≠checker separation for free.

**Example — maker ≠ checker:**

Before (the agent that wrote the code reviews the code — it's blind to its own
assumptions):

```
> is this diff good?
  yes, looks correct  ✅   # of course it says that — same mind that wrote it
```

After (Codex, a separate model, reviewing against the plan):

```
codex-code-review: REQUEST_CHANGES
  - service.py:41 — charge() called before the order is persisted; a failed
    save after a successful charge leaves the customer billed with no order.
  → fix, resume → APPROVED
```

A genuine independent catch that self-review routinely misses.

> Installed as the `codex` CLI + TRIP's `codex-*` skills. Optional but recommended.
> Repo: https://github.com/PiLastDigit/TRIP-workflow (the codex-* skills ship with TRIP)

---

## How they fit together

```
              ┌─────────── Graphify (shared memory: graph + blast radius) ───────────┐
              │                                                                       │
ticket → router ──auto──► WATCHER ──► headless claude -p  [ponytail via AGENTS.md] ──► PR
              │                                                                       │
              └──hitl──► RESEARCH (Graphify blast radius + pattern catalog)           │
                              │                                                       │
                          draft ADR → 👤 → /TRIP-1 → /TRIP-2 [Codex review] → /TRIP-3 │
                                                       [ponytail in the session]      │
                                                                                      │
        doc-cartographer agent ──► reads Graphify graph ──► docs/ARCHITECTURE.md ◄────┘
```

- **Graphify** is the shared memory both lanes read (and the doc agent draws from).
- **Ponytail** rides inside whichever agent is writing code, in either lane.
- **The watcher** owns the unattended lane; **TRIP** (with **Codex**) owns the
  gated lane; **Dyflo's router** decides which lane a ticket takes.

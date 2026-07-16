---
name: dyflo-watcher
description: Dyflo's autonomous lane — set up an autonomous multi-agent watcher system in ANY repository. Headless processes poll GitHub for label-tagged issues and auto-launch Claude Code sessions to work them (one ticket → one PR → exit). Use when someone wants to "set up the agents", "add a test/QA agent", "autonomous agents on this repo", "watcher orchestration", or stand up issue-driven agent automation. Ships generalist coder briefs plus two specialists: Tessy (test author) and Quin (QA verifier). Builds the engine + per-agent configs + go-prompts adapted to the current repo, then hands back a manual-setup checklist for the interactive steps (GitHub auth, Claude login). This is the watcher Dyflo's `auto` lane relies on.
---

# Agent Orchestration Setup

Stand up an autonomous "watcher" system in the current repository. Each agent is a headless poller: it watches GitHub for open issues carrying its label, and when there's eligible work and no open PR of its own, it launches a fresh headless Claude Code session with a mission brief. The session does ONE ticket, opens a PR, and exits. The watcher relaunches it for the next.

**This is dual-use automation.** Watchers run with `--dangerously-skip-permissions` on whatever Claude account each config dir is logged into, acting unattended. Only set this up when the user clearly wants autonomous agents on their repo. Always surface the risk (below) and recommend test-running one agent before arming the rest.

## What this skill produces

1. `agent_watcher.py` — the shared engine (poll loop, GitHub API, rate-limit handling, queue priority, launch).
2. One thin config per agent (`<name>-watcher.py`) — sets repo, label, config dir, prompt + queue paths, calls `run()`.
3. One go-prompt per agent (`<name>-go.md`) — the mission brief, tailored to THIS repo's stack and rules.
4. One queue file per agent (`<name>-queue.json`) — data-driven priority (integer issue numbers only).
5. A `.gitignore` entry — watchers are local operational tooling, not committed app code.
6. A SETUP CHECKLIST of the interactive steps the user must do themselves.

## Procedure

### Step 1 — Detect the repo and stack (never hardcode)
- Repo: `git remote get-url origin` → parse `owner/name`. If no remote, ask the user.
- Stack: look for `package.json` (node), `requirements.txt`/`pyproject.toml` (python), `go.mod`, `Cargo.toml`, etc. Tailor each go-prompt's test/build/lint commands to what's actually present.
- Conventions: read `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md` if present; fold their rules into the go-prompts.

### Step 2 — Confirm the agent roster with the user
Two kinds of agent:
- **Generalist coders** — scope-agnostic; they take a ticket and fix code. Use the generic `templates/go.md.tmpl`. Give them role labels (e.g. `backend`, `frontend`) — the *label* scopes their work, the brief is the same.
- **Specialists** — a distinct job that is NOT "fix a ticket", so they get their own brief:
  - **Tessy** (test author) → `templates/go-tessy.md.tmpl`. Writes/strengthens tests, opens test-only PRs, never touches product code, files a bug instead of silently fixing one.
  - **Quin** (QA verifier) → `templates/go-quin.md.tmpl`. Exercises the change end-to-end and reports a PASS-with-evidence or a bug issue; writes no product code and no test suites.
Ask: which roles, which label per role, and does any role span a second repo. Each role gets its own `CLAUDE_CONFIG_DIR` so sessions/accounts don't collide.

### Step 3 — Write the engine
Copy `templates/agent_watcher.py` (in this skill) to the repo, unchanged — it's already generic. Read it so you understand the `AgentConfig` contract.

### Step 4 — Write each agent's config, go-prompt, queue
Use `templates/watcher.py.tmpl` + `templates/queue.json.tmpl` for every agent, and pick the go-prompt base by role: generalist → `go.md.tmpl`, Tessy → `go-tessy.md.tmpl`, Quin → `go-quin.md.tmpl`. Fill in: name, repo (from Step 1), label, `{RUNTIME}` (claude|cursor — matches the repo's `dyflo.config.json`), `{MODEL}` (e.g. `claude-sonnet-4-6`, or `gpt-5`/`gemini-2.5-pro` on Cursor), and stack-specific commands (`{TEST_CMD}`, and `{RUN_CMD}` for Quin — how the app actually runs). The config dir is derived as `~/.{runtime}-<name>` so each agent's account stays isolated. Env overrides everything: `DYFLO_RUNTIME=cursor DYFLO_MODEL=gpt-5 python3 <name>-watcher.py`. **Critical correctness rules baked into the templates — keep them:**
- `<name>-queue.json` `blocked_by` values are **integers only** (issue numbers). External/prose blockers go in `skip` + `_notes`, never `blocked_by` (non-numeric values crash the parser).
- The "fix failing PR" path acts ONLY on PRs the agent itself authored (never dependabot or others' PRs).
- Go-prompts: one ticket per session, branch per issue, evidence (file:line / output) for every claim, never weaken a test to pass, NEVER merge (open PR, stop), mandatory Evidence section in PR body.

### Step 5 — Gitignore the watchers
Append the watcher filenames (and config dirs if local) to `.gitignore`.

### Step 6 — Create labels + validate live
- `gh label create <label> --repo <owner/name> ...` for each agent.
- Validate every watcher imports and builds its config cleanly.
- Live-poll proof: for each agent, hit the repo+label and print the open-ticket count. (See `templates/validate.py`.)

### Step 7 — Hand back the SETUP CHECKLIST (do NOT run these — they're interactive)
Print clearly, marked as the user's to do:
1. **GitHub auth** — `gh auth login` (or `export GITHUB_TOKEN=...`) with `repo` + `read:org` scope.
2. **Runtime login per config dir** — for each distinct config dir:
   - claude: `CLAUDE_CONFIG_DIR=~/.claude-<name> claude` → sign in → `/exit`.
   - cursor: `CURSOR_CONFIG_DIR=~/.cursor-<name> cursor-agent` → sign in (or set `CURSOR_API_KEY`) → exit.
3. **Start each watcher** (each in its own terminal): `cd <work_dir> && python3 <name>-watcher.py`.
4. **Risk** — these run headless, skip-permissions, on the logged-in account; they consume its rate limits and act unattended. **Log in + test-run ONE agent first**, confirm it picks a ticket and opens a branch correctly, before starting the rest.

Never run `gh auth login` or the Claude logins yourself — they are interactive and account-specific. Set up everything else and hand over the checklist.

## Reference
- `templates/agent_watcher.py` — the engine (drop-in).
- `templates/watcher.py.tmpl`, `templates/queue.json.tmpl` — per-agent config + queue bases.
- `templates/go.md.tmpl` — generalist coder brief; `templates/go-tessy.md.tmpl` — test author (Tessy); `templates/go-quin.md.tmpl` — QA verifier (Quin).
- `templates/validate.py` — live poll-proof script.
- `README.md` — explainer for end users (labels + watchers workflow).

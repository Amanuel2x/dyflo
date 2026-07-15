# Agent Orchestration — autonomous issue-driven coding agents

Stand up a fleet of **headless watcher agents** in any GitHub repo. Each agent
polls GitHub for issues carrying its label and, when there's work, launches a
fresh Claude Code session to do it: **one ticket → one PR → exit.** The watcher
relaunches it for the next ticket. A human reviews and merges — agents never merge.

> ⚠️ **Dual-use.** Watchers run Claude Code with `--dangerously-skip-permissions`,
> unattended, on whatever account each config dir is logged into. They consume
> that account's rate limits and act without approval prompts. Only run this on
> repos you control, and **test-run one agent before arming the rest.**

## Install (as a Claude Code skill)

```bash
git clone <this-repo> ~/.claude/skills/agent-orchestration
```

Then in any repository, run the skill in Claude Code:

```
/agent-orchestration
```

It detects the repo + stack, writes the engine + per-agent configs + go-prompts,
creates the GitHub labels, validates everything, and hands you a setup checklist.

## How it works

| Piece | Role |
|---|---|
| `agent_watcher.py` | Shared engine: poll loop, GitHub API, rate-limit backoff, queue priority, launch |
| `<name>-watcher.py` | Per-agent config: repo, label, config dir, prompt + queue paths |
| `<name>-go.md` | The mission brief each session boots with (one-ticket discipline, evidence, never-merge) |
| `<name>-queue.json` | Data-driven priority (issue numbers only) |

## Manual steps (you do these — they're interactive)

1. **GitHub auth:** `gh auth login` with `repo` + `read:org` scope (or `export GITHUB_TOKEN=...`).
2. **Claude login, per agent config dir:** `CLAUDE_CONFIG_DIR=~/.claude-<name> claude` → sign in → `/exit`.
3. **Start each watcher** (own terminal): `cd <repo> && python3 <name>-watcher.py`.
4. **File issues with an agent's label** to give it work.

## Design notes (correctness)

- `blocked_by` in the queue takes **issue numbers only** — external blockers go in
  `skip` + `_notes` (non-numeric values crash the parser).
- The "fix failing PR" path acts **only on PRs the agent itself authored** — it
  never touches dependabot or others' PRs.
- Watchers are local operational tooling; they're gitignored, not committed app code.

## License
MIT.

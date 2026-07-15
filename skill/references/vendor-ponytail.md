# Getting ponytail into the autonomous lane

**The problem.** Ponytail makes agents lazy-correct (YAGNI, stdlib first, shortest
working diff). It injects into interactive sessions and into `Task`-spawned
subagents via a **`SubagentStart` hook**. But the autonomous lane does not spawn
subagents — the `agent-orchestration` watcher launches a fresh, **separate
top-level** Claude Code process:

```python
subprocess.Popen(["claude", "--model", …, "--dangerously-skip-permissions", "-p", prompt],
                 cwd=work_dir, env={**os.environ, "CLAUDE_CONFIG_DIR": "~/.claude-<name>"})
```

That child runs in its own `CLAUDE_CONFIG_DIR`. Ponytail's `SubagentStart` hook
never fires for it, and the parent session's context doesn't carry over. So the
autonomous coding agents would run **ponytail-unaware** — the exact over-building
those agents most need to avoid when acting unattended.

**The fix (lazy, repo-agnostic).** The watcher's go-prompt already opens with:

> *"The repo's CLAUDE.md / AGENTS.md (if present) is already in your context —
> treat its rules as mandatory."*

So we don't touch hooks or the watcher at all. We vendor ponytail's canonical
`AGENTS.md` into the target repo. The headless child loads `AGENTS.md` like any
Claude Code session and obeys it because the go-prompt says it must.

**How.**

```bash
bash "$DYFLO_HOME/dyflo/vendor-ponytail.sh" <repo-root>
```

(`dyflo.sh --bootstrap` runs this for you.) It:
- finds the newest installed ponytail `AGENTS.md` (never hardcodes a version),
- writes a marker-fenced block into `<repo>/AGENTS.md`,
- is idempotent — re-running (or after a ponytail upgrade) refreshes the block in
  place, preserving any other content in the file.

**Verify it took.** After an autonomous-lane PR lands, its diff should read
ponytail-lazy: minimal change, no speculative abstractions, stdlib over new deps.
If a headless agent over-builds, confirm `AGENTS.md` exists in the repo and
contains the ponytail block (`grep 'ponytail:begin' AGENTS.md`).

**Note on the HITL lane.** The HITL lane runs inside your interactive session, so
it already gets ponytail through the normal SubagentStart hook — no vendoring
needed there. This step is only for the headless autonomous lane.

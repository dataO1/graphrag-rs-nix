---
name: log-session-action
description: Invoked ONLY by the Stop or SubagentStop hook's end-of-turn nudge — when the nudge fires, before composing the reply, ask "did this turn (mine + any subagents I dispatched) produce one of: an architectural change, a bug fix, a non-trivial doc write or edit (new file, restructured section, distilled findings — anything beyond a one-sentence tweak), a research finding, a decision taken, an unexpected outcome that changes the user's mental model, OR a completed user-facing deliverable (new file, code change, config edit) — INCLUDING when the deliverable was produced by a subagent I dispatched?" If yes, call `mcp__memory__log_action` (or `mcp__memory__log_decision` for a turn whose substance is a choice between alternatives with rationale) — the MCP tools handle file path, schema-matching append, time stamping, and frontmatter `topics:` union server-side. NEVER invoke proactively mid-turn; wait for the hook nudge. Single-sentence tweaks, read-only operations (recall/grep/read), and trivial chores (git status, ls) do NOT trigger.
allowed-tools: "mcp__memory__log_action mcp__memory__log_decision"
---

# log-session-action

Thin wrapper. The actual write is handled by two MCP tools on the
memory plugin's stdio server (`memory-mcp` crate):

- `mcp__memory__log_action` — six-field log row (`actions`,
  `mutations`, `why`, `outcome`, `related[]`)
- `mcp__memory__log_decision` — seven-field decision row (`context`,
  `options`, `decision`, `rollout`, `rollback`, `related[]`)

The server handles:

- Log file path resolution (`<sessionLogRoot>/<YYYY-MM-DD>/<host>-<agent>-<project>-<HHMMSS>.md`), with first-write-of-day file creation
- Time column stamping on call arrival
- Schema-matching append (peeks the latest table in the file; emits a fresh header inline if the schema doesn't match the row type, so log/decision blocks alternate cleanly in one chronological file)
- Frontmatter `topics:` union with the row's `related[]` links
- Per-file serialization (concurrent parent+subagent writes get ordered chronologically)

When to call which:

- The turn made a **decision** (chose between alternatives, with rationale) → `mcp__memory__log_decision`. Decisions live in the log, not as sibling knowledge notes — this preserves their temporal context.
- Any other meaningful turn output (architectural change / bug fix / doc edit / config edit / deliverable / research finding / unexpected outcome) → `mcp__memory__log_action`.

If a turn produces both (a decision AND meaningful actions worth a
log row), fire both tools — one row each. They write to the same file
with alternating schemas; the schema-matching append rule handles the
header transitions.

If the tool returns `logging_disabled`, MEMORY_SESSION_LOG_ROOT wasn't
set when the MCP server started. Surface the error to the user and
abort — don't fall back to a manual `Bash printf` write.

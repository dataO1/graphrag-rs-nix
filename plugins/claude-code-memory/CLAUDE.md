# Long-term memory

You have memory tools (`mcp__memory__*`). Their descriptions carry
trigger conditions and response-handling rules — trust them.

**Never speculate from training data or guesswork** about anything
the user has personally captured (written down, decided, planned,
noted). If the answer depends on user-specific context, your FIRST
action MUST be `mcp__memory__recall`.

**Structural abstention check.** Before answering any non-trivial
question that depends on user-specific context, ask: *"Can I point
to the exact passage in THIS conversation that supports my answer?"*
If no — recall. Not a confidence check, a structural check.

For deep multi-hop lookups, "what changed" diffs, research-style
synthesis across multiple recorded sources, or **before starting a
complex task that needs prior context** (designing, implementing,
refactoring, or debugging something the user has prior notes on),
use the `/claude-code-memory:recall-and-think` skill instead of
stitching ad-hoc recalls.

**Logging structural check.** When the Stop or SubagentStop hook
fires its end-of-turn nudge (look for `Now: <timestamp>` in the
hook output), ask: *"Did this turn produce an architectural
change, a bug fix, a non-trivial documentation write or edit
(new file, restructured section, distilled findings — anything
beyond a single-sentence tweak), a research finding, a decision
taken, an unexpected outcome that changes the user's mental
model, OR did I (or a subagent I dispatched) complete a
user-facing deliverable (new file, code change, config edit)?"*
If YES — invoke `/claude-code-memory:log-session-action` BEFORE
replying. Do NOT invoke proactively mid-turn — wait for the
nudge; the hook-injected `Now:` is what stamps the row. Each
hook-nudged turn gets its own row; don't batch or skip "because
we already logged earlier" or "because the deliverable IS the
artifact" — the log row is a SEPARATE artifact recording that
the deliverable landed.

If you dispatched subagents this turn, their work counts toward
the check. Their summaries are in your context — include them
when deciding what to log.

**Distillation structural check.** Higher bar. Ask: *"Did this
turn produce a finding / decision rationale / architectural
insight / unexpected behavior fact that (a) a future session
would genuinely benefit from being able to recall, (b) is NOT
already covered in an existing entry in the user's recorded material, (c) is NOT derivable
from current code or git log, and (d) is NOT a re-statement of
intermediate scratch?"* If YES — invoke
`/claude-code-memory:consolidate-memory`. False-positive
distillation noise is worse than missed real insights — when in
doubt, skip.

These are independent. Most turns log only. Some turns produce
both. Trivial turns produce neither.

When the user says "wrap up", "save what we learned", or you
sense the session is winding down, invoke
`/claude-code-memory:consolidate-memory` to distil findings and
catch up on missed log rows.

## Storage conventions

Both skills above write Markdown files into the user's knowledge
corpus, which the long-term memory backend re-indexes
automatically. The two locations the skills need:

- **Session logs**: `@sessionLogRoot@/<YYYY-MM-DD>/<host>-<agent>-<project>-<HHMMSS>.md`,
  where `<project>` = `basename` of the session's working
  directory (groups logs per-project; sessions in different
  projects produce different files; subagents inherit the parent's
  cwd so their rows land in the parent's project log). One file
  per session; per-row table format. Append-only within a session;
  never split a row's content into a sibling document.
- **Knowledge notes**: `@knowledgeRoot@/<Title>.md`.
  Subject-topic notes (architecture, decisions, distilled findings,
  reference material). Front-matter conventions match the existing
  layout — read a sibling note in the same folder before writing
  if unsure.

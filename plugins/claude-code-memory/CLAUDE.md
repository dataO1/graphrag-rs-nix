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

These are independent triggers — most turns log only, some
produce both, trivial turns produce neither.

**Decisions live in the log, not in knowledge notes.** A decision
(choice between alternatives, with rationale + rollout +
rollback) is appended as a row in the **Decisions** sub-table of
today's log file, NOT as a sibling document in the knowledge
corpus. Reason: temporal context (when the decision was made,
what surrounded it) is load-bearing for understanding the WHY
later. The memory backend recall is cross-session and indexes log
chunks just as well as knowledge notes, so retrieval doesn't
suffer; what you gain is a chronological view that knowledge
notes can't give. Knowledge notes are reserved for non-decision
content (research findings, architectural insights, behavior
facts the user will want to recall by topic rather than by date).

**Order when both apply.** Run `consolidate-memory` FIRST, then
`log-session-action`. The log row's `Related` column is meant to
cite knowledge notes that document the turn's substance — if
logging runs first, that column can only reference pre-existing
notes, and any note distilled from THIS turn would be unreachable
from its own log row. (Note: for turns whose only durable output
IS a decision, no `consolidate-memory` call is needed — the
decision row in the Decisions sub-table IS the durable artifact.)

When the user says "wrap up", "save what we learned", or you
sense the session is winding down, invoke
`/claude-code-memory:consolidate-memory` to distil non-decision
findings and catch up on missed log rows.

## Storage conventions

Both skills above write Markdown files into the user's knowledge
corpus, which the long-term memory backend re-indexes
automatically. The two locations the skills need:

- **Session logs**: `@sessionLogRoot@/<YYYY-MM-DD>/<host>-<agent>-<project>-<HHMMSS>.md`,
  where `<project>` = `basename` of the session's working
  directory (groups logs per-project; sessions in different
  projects produce different files; subagents inherit the parent's
  cwd so their rows land in the parent's project log). One file
  per session; append-only.

  Layout — two alternating table schemas in one chronological
  file:

  Log entries (six columns):

  ```
  | Time | Actions | Mutations | Why | Outcome | Related |
  ```

  Decisions (seven columns):

  ```
  | Time | Context | Options | Decision | Rollout | Rollback | Related |
  ```

  When appending, match the schema of the latest table in the
  file. If the new entry's type doesn't match, start a new table
  with the right header and append the entry there. Result is an
  alternating chronological flow of log / decision / log /
  decision blocks. Never split a row's content into a sibling
  document — append a new table inline instead.

- **Knowledge notes**: `@knowledgeRoot@/<Title>.md`.
  Subject-topic notes for non-decision content: research
  findings, architectural insights, behavior facts, reference
  material. Decisions do NOT go here (see above). Front-matter
  conventions match the existing layout — read a sibling note in
  the same folder before writing if unsure.

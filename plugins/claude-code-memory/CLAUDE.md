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

For deep multi-hop lookups, "what changed" diffs, or research-style
synthesis across multiple recorded sources, use the
`/claude-code-memory:recall-and-think` skill instead of stitching
ad-hoc recalls.

After completing a meaningful unit of work — an architectural
change, a bug fix, a non-trivial documentation update,
research that produced a finding, a decision, or an unexpected
outcome — invoke `/claude-code-memory:log-session-action` to
append a row to today's session log. Single-sentence doc tweaks
and routine read-only operations do NOT trigger.

When the user says "wrap up", "save what we learned", or you
sense the session is winding down, invoke
`/claude-code-memory:consolidate-memory` to distil findings and
catch up on missed log rows.

## Storage conventions

Both skills above write Markdown files into the user's knowledge
corpus, which the long-term memory backend re-indexes
automatically. The two locations the skills need:

- **Session logs**: `~/Notes/📔 Journal/agent-log/<YYYY-MM-DD>/<host>-<agent>-<HHMM>.md`.
  One file per session; per-row table format. Append-only within a
  session; never split a row's content into a sibling document.
- **Knowledge notes**: `~/Notes/🗂️ Collection/<Title>.md`.
  Subject-topic notes (architecture, decisions, distilled findings,
  reference material). Front-matter conventions match the existing
  vault layout — read a sibling note in the same folder before
  writing if unsure.

The corpus location is operator-configured; if the user's
filesystem layout differs from above, update this section in
the host's plugin and the skills will pick up the new paths.
The skills themselves do not hard-code paths — they reference
the conventions established here.

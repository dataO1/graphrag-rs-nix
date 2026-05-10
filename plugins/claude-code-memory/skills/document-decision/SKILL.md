---
name: document-decision
description: Capture a decision (alternatives considered, rationale, rollout/rollback plan) into long-term memory as a structured note. MUST trigger after the user (or the agent) has chosen between options. Call this BEFORE moving on to implementation. Use even if the user does not explicitly say "document this" — the trigger is the act of choosing, not the request to write it down.
allowed-tools: "Read Write Edit Glob Grep Bash(date *)"
---

# document-decision

Capture a decision in a structured form so future sessions can
recall not just *what* was decided but *why*, what was rejected,
and how to roll back.

## When to trigger

MUST trigger after:

- The user picks between two or more named options ("let's go with
  B", "use Postgres not SQLite", "skip the wrapper").
- The agent recommends one path and the user accepts it without
  pushback (silent acceptance is still a decision).
- A non-obvious choice is made between approaches the agent
  considered (e.g. "I'll use a hook here, not a skill, because
  …").
- The user changes a prior decision ("actually, let's switch to
  X").

DO NOT trigger after:
- Trivial choices (file naming, variable names, comment wording).
- Decisions fully captured in code (the diff is the decision).
- Pure aesthetic preferences with no engineering trade-off.

## Procedure

### Step 1 — Recall first

Search long-term memory for prior related decisions on the same
topic. If a prior decision exists, the new note explicitly
supersedes or amends it (link to it; note the change).

### Step 2 — Determine target file

Use the storage conventions from the plugin's CLAUDE.md "Storage
conventions" section. In short:

- Ongoing project topics → append a `## Decision: <date> — <one-liner>`
  section to the existing topic note in the user's reference
  material.
- New standalone decision → create a new note titled
  `Decision — <Title>` alongside the rest of the reference
  material.
- If unclear which topic owns the decision, ask the user before
  writing.

### Step 3 — Compose the note

Use this structure:

```markdown
## Decision: 2026-05-10 — Use --plugin-dir wrapper for plugin loading

**Context.** [What problem prompted the choice. 1-2 sentences.]

**Options considered.**
- **A: <name>** — [one-line description] — [why rejected, or why kept]
- **B: <name>** — [one-line description] — [why rejected, or why kept]
- **C: <name>** — [one-line description] — [why rejected, or why kept]

**Decision.** Chose [option]. [One paragraph rationale.]

**Rollout.** [How this gets rolled out. Specific steps if non-trivial.]

**Rollback.** [What to do if this turns out wrong. Specific reverse steps.]

**Related.** [[doc-a]], [[doc-b]]
```

All fields required. If a field is genuinely empty (e.g. no
rollback needed for a one-shot tool choice), write "N/A — <reason>"
rather than omitting.

### Step 4 — Append a log row

After writing the decision note, also append a row to today's
session log via the `log-session-action` skill format. The row's
`Related` column links to the decision note. The decision note's
`Related` field can link to other knowledge docs but never to a
log file.

The decision note and the log row are both Markdown files in the
user's recorded material; the long-term memory layer auto-indexes
them shortly after the write. The files are the artifacts — there
is no separate ingest step.

## Quality bar

- **Alternatives must be real.** "Option A: do it. Option B:
  don't" is not a real alternative space. List only options that
  were genuinely considered.
- **Rationale must be falsifiable.** "Because it's better" is
  not a rationale. "Because it's the only mechanism documented
  for this case (see [research note])" is.
- **Rollback is a real plan.** Even if it's "rip out the wrapper
  + restore the prior managed-mcp.json".

## Anti-patterns

- Decision notes that summarise the conversation rather than
  capturing the *choice*.
- Skipping rejected options because "they weren't really
  considered". If they were mentioned, they were considered.
- Writing the rationale in terms of who said what ("the user
  chose X because they wanted Y") rather than the engineering
  reasoning ("X is the only mechanism that survives the 2KB
  truncation").

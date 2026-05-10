---
name: consolidate-memory
description: Distil the current session's findings, decisions, and meaningful actions into long-term memory. Use at session end, before context compaction (auto-fires on PreCompact), or when the user says "wrap up", "save what we learned", "consolidate", "document this", or similar. MUST trigger if the session produced any of: a research finding worth keeping, a decision with rationale, an architectural insight, an unexpected outcome that changes the user's mental model, or noteworthy actions that were not yet logged via log-session-action.
allowed-tools: "Bash(date *) Bash(ls *) Read Write Edit Glob Grep"
---

# consolidate-memory

End-of-session reflection: distil findings into long-term memory
and catch up on any meaningful actions that were not logged
mid-session.

## Two outputs, distinct

This skill produces two kinds of artifact, and conflating them is
the most common failure:

1. **Distilled knowledge** — durable findings, decisions,
   architectural insights, project models. Written as Markdown
   notes in the appropriate vault folder (`~/Notes/🗂️ Collection/`
   for technical/reference material; `~/Notes/📔 Journal/` for
   dated reflections). Upserted via `mcp__memory__remember` if
   the same topic already has a note (the server's similarity
   check handles dedup).
2. **Catch-up log rows** — rows for meaningful actions that
   should have been logged via the `log-session-action` skill but
   weren't. Written as table rows in today's session log file
   (same format as `log-session-action`).

Different files. Different cadences. Don't write a knowledge
note that should be a log row. Don't write a log row that should
be a knowledge note.

## When to trigger

- User says "wrap up", "save what we learned", "consolidate",
  "document this", "let's checkpoint".
- `PreCompact` hook fires (auto-invokes this skill).
- Session is winding down: user thanks the agent, says they're
  going AFK, says "ship it".
- The session produced a research finding, a decision, an
  architectural insight, or an unexpected outcome and these have
  not yet been distilled.

## Procedure

### Step 1 — Audit the session

Review the conversation. Identify:

- **Research findings worth keeping** — investigations that
  resolved with a concrete answer the user will want to recall
  later. Distil into a knowledge note.
- **Decisions** — choices between options. If not already
  captured via `/claude-code-memory:document-decision`, capture
  here with the same template (alternatives, rationale,
  rollout/rollback).
- **Architectural insights** — new mental-model facts about how
  a system is composed or behaves.
- **Unexpected outcomes** — things that behaved differently from
  prior expectations.
- **Unlogged meaningful actions** — meaningful units of work
  (architectural change, bug fix, non-trivial doc update,
  research) that were not logged via `log-session-action`.

If none of the above: nothing to consolidate. Exit without
writing.

### Step 2 — For each finding, recall first

Before writing a new knowledge note, call `mcp__memory__recall`
with a tight query about the topic. If a strongly similar note
already exists:

- Read it via the `absolutePath` field (only safe filesystem
  input from a recall result).
- Edit it in place to integrate the new finding.
- Pass the updated content through `mcp__memory__remember` so
  the server's similarity check confirms the merge target.

If no similar note exists:

- Write a new Markdown note in the appropriate folder with
  proper frontmatter (tags, created, updated, related links).
- Call `mcp__memory__remember` with the new note's path.

### Step 3 — Catch up missed log rows

For each meaningful unlogged action, append a row to today's
session log following the `log-session-action` skill's format
exactly. Multiple unlogged actions = multiple rows. Do not
consolidate them into a single fat row.

### Step 4 — Update vault frontmatter

Each new or updated knowledge note carries a `related: [[...]]`
list pointing at relevant other notes. Each new log row
contributes its `Related` topics to the session file's
frontmatter `topics:` union.

## Quality bar

The agent will be tempted to over-distil ("we discussed three
things, write three notes"). Resist:

- A finding is "worth keeping" only if a future session will
  benefit from recalling it. Throwaway diagnostics, rejected
  hypotheses, and intermediate scratch don't qualify.
- A note that summarises what's already in the codebase or
  `git log` is noise. Only distil what's *not* derivable from
  current state.
- Prefer updating one canonical note over creating a new one.
  Server-side dedup will catch obvious duplicates; client-side
  search-before-write avoids the round-trip.

## Anti-patterns

- Writing a session-summary note that lists every turn. Use the
  log table for that.
- Writing knowledge notes with the same structure as log rows.
  Knowledge is prose with a thesis; logs are tabular records.
- Conflating distillation with logging. Two outputs, two files.
- Adding a `Related` link in a log row that points to a
  *consolidation note* — `Related` only points to durable
  knowledge docs. The consolidation note IS the durable
  knowledge doc; it's the destination of links, not a source.

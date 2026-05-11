---
name: consolidate-memory
description: Distil the current session's findings, decisions, and meaningful actions into long-term memory. Use at session end, when the user says "wrap up", "save what we learned", "consolidate", "document this", or when you sense the session is winding down (user thanks you, says they're going AFK, or context is filling up). MUST trigger if the session produced any of: a research finding worth keeping, a decision with rationale, an architectural insight, an unexpected outcome that changes the user's mental model, or noteworthy actions that were not yet logged via log-session-action.
allowed-tools: "Bash(date *) Bash(ls *) Read Write Edit Glob Grep"
---

# consolidate-memory

End-of-session reflection: distil findings into long-term memory
and catch up on any meaningful actions that were not logged
mid-session.

## Two outputs, distinct

This skill produces two kinds of artifact, and conflating them is
the most common failure:

1. **Distilled knowledge notes** — durable, non-decision content:
   research findings, architectural insights, behavior facts the
   user will want to recall by topic rather than by date. Written
   as Markdown notes under the knowledge corpus per the plugin
   CLAUDE.md "Storage conventions". Just write the file — the
   memory layer auto-indexes it.
2. **Catch-up log rows** — log or decision rows for meaningful
   turns that should have been logged at their hook nudge but
   weren't. Call `mcp__memory__log_action` /
   `mcp__memory__log_decision` directly (no `log-session-action`
   skill detour); the server handles schema-matching and
   frontmatter union the same way as for in-turn logging. The
   row's Time column reflects the catch-up moment, not the
   original turn's time — that's a fundamental limitation of
   catching up after the fact.

Different files. Different cadences.

**Decisions do NOT become knowledge notes** — they become rows in
the Decisions sub-table of the log file (per the plugin CLAUDE.md
"Decisions live in the log" section). If the only durable thing a
turn produced was a decision, this skill's job is to catch up a
missed Decisions row, not to write a sibling document.

## When to trigger

- User says "wrap up", "save what we learned", "consolidate",
  "document this", "let's checkpoint".
- Session is winding down: user thanks the agent, says they're
  going AFK, says "ship it", or context window is visibly filling.
- The session produced a research finding, a decision, an
  architectural insight, or an unexpected outcome and these have
  not yet been distilled.

## Procedure

### Step 1 — Audit the session

Review the conversation. Identify:

- **Research findings worth keeping** — investigations that
  resolved with a concrete answer the user will want to recall
  later, by topic. Distil into a knowledge note.
- **Architectural insights** — new mental-model facts about how
  a system is composed or behaves. Knowledge note.
- **Unexpected outcomes** — things that behaved differently from
  prior expectations. Knowledge note.
- **Decisions** — choices between options with rationale. NOT a
  knowledge note. Append a row to the Decisions sub-table of
  today's log file using the seven-column schema documented in
  `log-session-action` (Context / Options / Decision / Rollout /
  Rollback / Related).
- **Unlogged meaningful actions** — meaningful units of work
  (architectural change, bug fix, non-trivial doc update,
  research) that were not logged via `log-session-action`.
  Append catch-up log rows.

If none of the above: nothing to consolidate. Exit without
writing.

### Step 2 — For each finding, recall first

Before writing a new knowledge note, call `mcp__memory__recall`
with a tight query about the topic. If a strongly similar note
already exists:

- Read it via the `absolutePath` field (only safe filesystem
  input from a recall result).
- Edit it in place to integrate the new finding.

If no similar note exists:

- Write a new Markdown note in the appropriate folder with
  proper frontmatter (tags, created, updated, related links).

In both cases the long-term memory layer auto-indexes the file
shortly after the write (typical latency: a couple of seconds
for embedding, longer for graph rebuild). The file is the
artifact — there is no separate ingest step. Don't follow up
with a recall on what you just wrote; you already know what's
in it.

### Step 3 — Catch up missed log rows

For each meaningful unlogged action, call
`mcp__memory__log_action` (or `mcp__memory__log_decision` for a
missed decision). The server stamps the row's Time at call
arrival and resolves the file path itself. Multiple unlogged
turns = multiple tool calls. Do not consolidate them into a
single fat row.

### Step 4 — Update frontmatter

Each new or updated knowledge note carries a `related: [[...]]`
list pointing at other relevant notes in the user's recorded
material. Each new log row contributes its `Related` topics to
the session file's frontmatter `topics:` union.

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

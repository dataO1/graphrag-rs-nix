---
name: log-session-action
description: Append a row to today's session log table BEFORE replying to the user, whenever the just-completed turn produced any of: an architectural change, a bug fix, a non-trivial documentation update (more than a sentence), a research finding, a decision taken, or an unexpected outcome that changes the user's mental model. MUST be invoked structurally — before composing the reply, ask "did this turn produce one of those?" and if yes, fire this skill first. Each meaningful turn gets its own row, even if you logged a different one earlier in the session. Single-sentence tweaks, read-only operations (recall/grep/read), and trivial chores (git status, ls) do NOT trigger.
allowed-tools: "Bash(date *) Bash(mkdir *) Bash(ls *) Bash(test *) Bash(printf *) Read Write Edit Glob"
---

# log-session-action

Append a row to today's session-log table after a meaningful unit of work.

## When to trigger

MUST trigger after one of:

- **Architectural change** — a non-trivial modification to how a system is
  composed (new module, refactored boundary, removed component).
- **Bug fix** — a defect was identified and patched.
- **Non-trivial documentation update** — more than a single-sentence
  edit or typo. New section, restructured doc, distilled findings
  into a doc.
- **Research session that produced a finding** — investigation
  concluded with something concrete worth keeping.
- **Decision taken** — chose between options. (Pair with
  `/claude-code-memory:document-decision` for the rationale.)
- **Unexpected outcome** — something behaved differently than
  expected; user's mental model needs updating.

DO NOT trigger after:
- Single-sentence doc tweaks, typo fixes, formatting changes.
- Read-only operations (recall, search, grep, read, status).
- Tool-call sequences that did not modify any system or document.
- Routine chores (`git status`, `ls`, `cat`).

## Procedure

1. **Determine session log file path.** Use the session-log
   convention from the always-on memory guidance (the plugin's
   CLAUDE.md "Storage conventions" section). At time of writing
   the convention is one file per session with date / host /
   agent / start-time keys; the skill must follow whatever the
   guidance currently says, not hard-code a path here.

2. **Check if today's session log file exists.** If yes → append a
   row. If no → create with frontmatter + table header, then append
   the first row.

3. **Resolve topics.** From the work just done, list the topics
   touched (entity / project / concept names as wiki-links, e.g.
   `[[project-a]]`, `[[component-x]]`, `[[concept-y]]`). These go
   in the row's `Related` column (knowledge docs only — never
   another log file) AND get unioned into the file's frontmatter
   `topics:` list.

4. **Compose the row.** Five-column markdown table row:

   | Time | Actions | Mutations | Why | Outcome | Related |

   Cell rules:
   - `Time` — `HH:MM:SS` local time. MUST be the output of
     `Bash(date +%H:%M:%S)` run at this step. NEVER infer or copy
     from context: the model has no built-in clock — without an
     explicit `date` call, any timestamp is a guess (often
     detectable later as a round `:00`-second value). If the
     Stop-hook block reason that triggered this skill carries a
     "Now: ..." timestamp, use that exact value (it was captured
     when the hook fired and is authoritative for this turn);
     otherwise run `date` yourself.
   - `Actions` — one-line verb-phrase summary of what was done.
     If the action actually happened earlier in the session and
     you're catching up, qualify the cell text (e.g. "Earlier this
     session: …"); the `Time` column always reflects when the
     row was written, never the historical action time.
   - `Mutations` — comma-separated list of files/configs/paths
     touched. `(none)` permitted only for design-discussion rows.
   - `Why` — one sentence: the motivation in business / technical
     terms. Not the literal task ("user asked X"); the underlying
     reason ("legal flagged the auth flow for compliance").
   - `Outcome` — one phrase: what concretely landed. Not "done";
     "switch landed clean" / "tests pass" / "diff merged".
   - `Related` — `[[wiki-link]]` references to knowledge docs
     (other notes in the user's recorded material — design docs,
     reference notes, READMEs). NEVER a link to another log
     file. If multiple, comma-separated.

5. **Append at the END of the file.** Strictly. Use
   `Bash(printf '| ...row... |\n' >> "$FILE")` — `>>` redirection
   is append-only by definition and cannot insert in the middle.
   Do NOT use `Edit` with an anchor on an earlier row; that
   silently places the new row in the wrong position relative to
   any rows appended by parallel agents (subagents, concurrent
   sessions) in between. Result: rows in the file are strictly
   chronological by `Time`, since `Time` is the row-write moment
   and writes are append-only.

6. **Cells stay terse.** If a row would need spillover content,
   split into multiple rows instead. Do NOT create a sibling log
   document and reference it.

7. **Update frontmatter `topics:`** (via `Edit`, anchored on the
   `topics:` line) to include any new topics from this row's
   `Related`. Frontmatter is the union of all topics in all rows
   of the session. The latest activity time is the last row's
   `Time` column — no separate `session_end` field is needed.

## File format reference

```markdown
---
date: <YYYY-MM-DD>
session_start: <RFC3339 timestamp>
host: <hostname>
agent: <agent name>
topics: [[topic-a]], [[topic-b]]
---

# Agent log — <YYYY-MM-DD HH:MM> — <host> / <agent>

| Time | Actions | Mutations | Why | Outcome | Related |
|------|---------|-----------|-----|---------|---------|
| <HH:MM:SS> | <verb-phrase action> | <files / configs touched> | <one-sentence motivation> | <what concretely landed> | [[knowledge-doc]] |
```

## What the row is NOT

- A transcript. Cells are summaries.
- An intent statement. Rows are written *after* the action lands,
  describing what happened.
- A pointer to fuller content. The row IS the content.

If a row's `Why` or `Outcome` won't fit in one phrase, split the
work into multiple rows. The table format is the discipline.

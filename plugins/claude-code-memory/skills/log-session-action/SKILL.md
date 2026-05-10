---
name: log-session-action
description: Append a row to today's session log table after a meaningful unit of work concludes. MUST trigger after an architectural change, a bug fix, a non-trivial documentation update (more than a sentence), a research session that produced a finding, a decision taken, or an unexpected outcome that changes how the user should think about the system. Single-sentence doc tweaks, routine read-only operations, and trivial chores do NOT trigger.
allowed-tools: "Bash(date *) Bash(mkdir *) Bash(ls *) Bash(test *) Read Write Edit Glob"
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

1. **Determine session log file path.** Today's date in `YYYY-MM-DD`
   format (use `Bash(date +%Y-%m-%d)`); host (read from `$HOSTNAME`);
   agent is `claude-code`; session start time is the timestamp from
   the first log entry of this session if known, else now in `HHMM`.
   Path: `~/Notes/📔 Journal/agent-log/<YYYY-MM-DD>/<host>-claude-code-<HHMM>.md`.

2. **Check if today's session log file exists.** If yes → append a
   row. If no → create with frontmatter + table header, then append
   the first row.

3. **Resolve topics.** From the work just done, list the topics
   touched (entity / project / concept names, e.g. `[[mesh]]`,
   `[[graphrag-rs-nix]]`, `[[memory-system]]`). These go in the
   row's `Related` column (knowledge docs only — never another log
   file) AND get unioned into the file's frontmatter `topics:` list.

4. **Compose the row.** Five-column markdown table row:

   | Time | Actions | Mutations | Why | Outcome | Related |

   Cell rules:
   - `Time` — `HH:MM:SS` local time (use `Bash(date +%H:%M:%S)`).
   - `Actions` — one-line verb-phrase summary of what was done.
   - `Mutations` — comma-separated list of files/configs/paths
     touched. `(none)` permitted only for design-discussion rows.
   - `Why` — one sentence: the motivation in business / technical
     terms. Not the literal task ("user asked X"); the underlying
     reason ("legal flagged the auth flow for compliance").
   - `Outcome` — one phrase: what concretely landed. Not "done";
     "switch landed clean" / "tests pass" / "diff merged".
   - `Related` — `[[wiki-link]]` references to knowledge docs
     (vault notes, design docs, READMEs). NEVER a link to another
     log file. If multiple, comma-separated.

5. **Cells stay terse.** If a row would need spillover content,
   split into multiple rows instead. Do NOT create a sibling log
   document and reference it.

6. **Update frontmatter `topics:`** to include any new topics
   from this row's `Related`. Frontmatter is the union of all
   topics in all rows of the session.

7. **Update `session_end:` timestamp** in frontmatter to now
   (RFC3339 format with timezone) on every append, so the file
   reflects the latest activity.

## File format reference

```markdown
---
date: 2026-05-10
session_start: 2026-05-10T14:32:11+02:00
session_end: 2026-05-10T16:08:47+02:00
host: neo-16
agent: claude-code
topics: [[memory-system]], [[graphrag-rs-nix]]
---

# Agent log — 2026-05-10 14:32 — neo-16 / claude-code

| Time | Actions | Mutations | Why | Outcome | Related |
|------|---------|-----------|-----|---------|---------|
| 14:32:11 | Renamed `knowledge-mcp` → `memory-mcp` across both repos | `crates/memory-mcp/`, `flake.nix`, `flake.lock` | "knowledge graph" leaked implementation; "long-term memory" matches agent mental model | switch landed clean | [[Agent Extension Primitives]] |
```

## What the row is NOT

- A transcript. Cells are summaries.
- An intent statement. Rows are written *after* the action lands,
  describing what happened.
- A pointer to fuller content. The row IS the content.

If a row's `Why` or `Outcome` won't fit in one phrase, split the
work into multiple rows. The table format is the discipline.

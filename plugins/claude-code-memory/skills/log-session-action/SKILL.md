---
name: log-session-action
description: Append a row to today's session log table BEFORE replying to the user, whenever the just-completed turn produced any of: an architectural change, a bug fix, a non-trivial doc write or edit (new file, restructured section, distilled findings — anything beyond a one-sentence tweak), a research finding, a decision taken, an unexpected outcome that changes the user's mental model, OR a completed user-facing deliverable (new file, code change, config edit) — INCLUDING when the deliverable was produced by a subagent you dispatched (their work counts; the log row is a SEPARATE artifact from the deliverable itself). MUST be invoked structurally — before composing the reply, ask "did this turn (mine + any subagents I dispatched) produce one of those?" and if yes, fire this skill first. Each meaningful turn gets its own row, even if logged earlier in the session. Single-sentence tweaks, read-only operations (recall/grep/read), and trivial chores (git status, ls) do NOT trigger.
allowed-tools: "Bash(date *) Bash(mkdir *) Bash(printf *) Read Edit"
---

# log-session-action

## File path

One file per session, grouped by project. Follow the "Storage
conventions" section of the always-on memory guidance (plugin's
CLAUDE.md) — do not hard-code the path here. At time of writing
the filename includes `basename` of the session's cwd
(`Bash(basename "$PWD")` or `Bash(basename "$(pwd)")`), so
sessions in different projects produce different files.

On first write of a session: glob for an existing file matching
this session's cwd+date (the agent's first row might be a
continuation of an earlier same-day session in the same project,
in which case append; otherwise create fresh with frontmatter +
table header).

## Row format

```
| Time | Actions | Mutations | Why | Outcome | Related |
```

- **Time** — `HH:MM:SS`. Use the `Now:` value from the Stop-hook
  block reason that triggered this skill. If not present
  (skill invoked outside a hook), run `Bash(date +%H:%M:%S)`.
  NEVER infer from context — the model has no clock.
- **Actions** — one-line verb-phrase. For earlier-session actions,
  qualify in text ("Earlier this session: …"); `Time` always
  reflects row-write moment, not action time.
- **Mutations** — files/configs/paths touched, comma-separated.
  `(none)` only for design-discussion rows.
- **Why** — one sentence: motivation in technical/business terms,
  not the literal task. ("Legal flagged the auth flow", not
  "user asked me to fix auth".)
- **Outcome** — one phrase, what concretely landed.
- **Related** — `[[wiki-link]]` references to knowledge docs.
  NEVER another log file. Comma-separated if multiple.

Cells stay terse. If too conflated, split into multiple rows —
do NOT create a sibling log document.

## Append

Append at the file's end with
`Bash(printf '| ... |\n' >> "$FILE")` — `>>` is append-only and
cannot insert in the middle. Do NOT use `Edit` with a row-anchor
(silently misplaces rows when parallel agents have appended in
between). Order is strictly chronological because `Time` =
row-write moment and writes are append-only.

After append, `Edit` the frontmatter `topics:` line to union in
any new wiki-links from this row's `Related` column.

## File template

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
```

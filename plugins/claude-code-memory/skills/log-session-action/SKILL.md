---
name: log-session-action
description: Invoked ONLY by the Stop or SubagentStop hook's end-of-turn nudge — the nudge supplies the authoritative `Now:` timestamp that stamps the row. NEVER invoke proactively mid-turn; wait for the nudge. Append a row to today's session log table BEFORE replying to the user when the just-completed turn produced any of: an architectural change, a bug fix, a non-trivial doc write or edit (new file, restructured section, distilled findings — anything beyond a one-sentence tweak), a research finding, a decision taken, an unexpected outcome that changes the user's mental model, OR a completed user-facing deliverable (new file, code change, config edit) — INCLUDING when the deliverable was produced by a subagent you dispatched (their work counts; the log row is a SEPARATE artifact from the deliverable itself). MUST be invoked structurally — when the hook nudge fires, before composing the reply, ask "did this turn (mine + any subagents I dispatched) produce one of those?" and if yes, fire this skill first. Each hook-nudged turn that meets criteria gets its own row, even if logged earlier in the session. Single-sentence tweaks, read-only operations (recall/grep/read), and trivial chores (git status, ls) do NOT trigger.
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

## Row formats

The log file carries **two alternating table schemas** in
chronological order. Pick the schema that matches the turn's
output type.

### Log entries — six columns

```
| Time | Actions | Mutations | Why | Outcome | Related |
```

- **Time** — `YYYY-MM-DD HH:MM:SS`. Use the `Now:` value
  verbatim from the Stop or SubagentStop hook block reason that
  triggered this skill (e.g. nudge `Now: 2026-05-11 09:44:28.`
  → cell `2026-05-11 09:44:28`). If no `Now:` is present, the
  skill is being invoked outside its supported entry point —
  abort and do NOT log. NEVER infer from context — the model
  has no clock.
- **Actions** — one-line verb-phrase. For earlier-session actions,
  qualify in text ("Earlier this session: …"); `Time` always
  reflects row-write moment, not action time.
- **Mutations** — files/configs/paths touched, comma-separated.
  `(none)` only for design-discussion rows.
- **Why** — one sentence: motivation in technical/business terms,
  not the literal task.
- **Outcome** — one phrase, what concretely landed.
- **Related** — `[[wiki-link]]` references to knowledge docs.
  NEVER another log file. Comma-separated if multiple.

Cells stay terse. If too conflated, split into multiple rows.

### Decisions — seven columns

```
| Time | Context | Options | Decision | Rollout | Rollback | Related |
```

Use this schema when the turn produced a decision (choice between
alternatives, with rationale). Decisions live in the log, not in
knowledge notes — see the plugin CLAUDE.md "Decisions live in the
log" section for the rationale.

- **Time** — same source rule as above.
- **Context** — what problem prompted the choice. 1–2 sentences.
- **Options** — alternatives genuinely considered. Inline format:
  `A: <name> — <one-line reason rejected/kept> / B: … / C: …`.
  Only options that were really on the table; do not invent a
  rejected option to look thorough.
- **Decision** — chosen option + one-paragraph rationale. Why
  the chosen path beats the others. Falsifiable reasoning, not
  "because it's better".
- **Rollout** — concrete steps the decision triggers (or
  triggered). N/A only when there's nothing to roll out.
- **Rollback** — concrete reverse steps if the decision turns out
  wrong. N/A only when truly inapplicable; state the reason.
- **Related** — `[[wiki-link]]` to other notes/decisions worth
  linking. Same rules as the log Related column.

Cells in the Decisions table run longer than log cells (Options
and Decision often need a few clauses). The "Cells stay terse"
rule loosens here — the schema's whole purpose is to hold prose
that wouldn't fit in a log row.

## Append

Append at the file's end with
`Bash(printf '| ... |\n' >> "$FILE")` — `>>` is append-only and
cannot insert in the middle. Do NOT use `Edit` with a row-anchor
(silently misplaces rows when parallel agents have appended in
between).

**Schema-matching rule:** before appending, check the schema of
the latest table block in the file. If it matches your entry's
type, append directly. If it doesn't, first append the matching
table's header (blank line, header row, separator row), then
append your row. Result is alternating chronological blocks of
log → decision → log → decision (no awkward content fragmented
across files).

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

(Decisions table headers are appended inline by the
schema-matching rule when the first decision of the session
fires.)

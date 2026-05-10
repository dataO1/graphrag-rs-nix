---
name: recall-and-think
description: Deep multi-hop lookup against long-term memory. Use when a question requires synthesis across multiple recorded sources, when a single recall left sub-claims unsupported, when the user asks "what changed in X" or diff-style questions, or when answering needs both broad and narrow recall passes. NOT for routine "look up X" questions — those should use mcp__memory__recall directly.
disable-model-invocation: true
allowed-tools: "Read Glob Grep"
---

# recall-and-think

Multi-hop deep recall. User-invoked. Replaces ad-hoc stitching
of recall calls when the answer needs synthesis or the first
recall returned partial coverage.

## Mode selection

`mcp__memory__recall` accepts a `mode` parameter:

- `default` — relational + semantic recall. 95% of questions.
- `thorough` — relational + semantic + verbatim. Compound or
  "wide" searches; first call in this skill defaults here.
- `local` — entity-centric. For a specific named entity already
  known to memory.
- `simple` — verbatim-only, no synthesis (~350 ms). Cheap probe
  for topic existence.

Use `as_of` (RFC 3339) for time-bound questions. Set
`max_versions_per_doc ≥ 2` for diff-style questions ("what
changed in X").

## Procedure (IRCoT-style interleaved retrieval)

1. **First recall** — `mode: thorough`, query is the user's
   question rephrased as a search-friendly statement. If multiple
   distinct topics are involved, fire multiple recall calls in
   parallel (one per topic).

2. **Read the results.** The chunk IS the answer. Do not follow
   up with `read` / `cat` / `find` against the source URI — the
   `excerpt` field carries what you need. Only fall back to
   filesystem reads via the result's `absolutePath` field
   (verbatim, never reconstructed) when the user explicitly
   asked for the *full* document.

3. **Identify unsupported sub-claims.** For each piece of the
   answer you would write, ask: *"Can I point to a specific
   passage in the recall results that supports this?"* If no →
   that sub-claim is unsupported.

4. **Recall again, tighter.** For each unsupported sub-claim,
   issue a fresh recall with a tighter query targeting that
   specific gap. Do NOT synthesise across the gap with general
   knowledge. If the second recall also returns nothing
   relevant, report the gap to the user — do not invent.

5. **Resolve conflicts by recency.** When recall results
   disagree, prefer the entry with the most recent
   `lastModified`; treat older entries as superseded. Older-but-
   not-removed entries are stale, not "conflicting".

6. **Compose the answer with citations.** Each non-trivial
   claim links to the supporting recall result by `source` (a
   citation URI for provenance — do NOT pass to a shell tool).

## When to fan out vs serialise

- **Fan out** when the user's question covers multiple distinct
  topics. Recall is wait-free server-side; serialising
  independent topics wastes wall-clock time.
- **Serialise** when each recall depends on the previous (e.g.
  recall returns an entity name → next recall queries that
  entity).

If a single recall returns 0 hits, do NOT auto-fan-out to 5
paraphrases. Try ONE rephrasing or `mode: thorough`; if still
nothing, report the gap.

## Diff-style questions

For "what changed in X", "diff Y over time", or "history of Z":

- `mode: thorough`, `max_versions_per_doc: 5` (or higher).
- Use `as_of` to anchor the "before" snapshot if asked for a
  bounded comparison.
- Compose the answer as a structured diff (added / removed /
  changed) with explicit version references.

## Quality bar

This skill is for cases where ad-hoc recall has *failed* to
produce a confidently-sourced answer. If a single
`mcp__memory__recall` would suffice, the user should use that
directly. Don't over-invoke this skill on routine questions.

## What this skill is NOT

- A general "search harder" toggle.
- A way to bypass recall's recency-wins handling.
- A scratchpad for speculation. Every claim in the answer must
  have a concrete recall result behind it.

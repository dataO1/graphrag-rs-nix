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

1. **Plan the recall fan-out.** Enumerate every distinct angle
   the question touches:
   - **Topics / entities** (project names, concepts, components)
   - **Techniques / approaches** (algorithms, patterns, tools)
   - **Temporal axes** (state-of, history-of, latest-move,
     since-when, what-changed)
   
   The recalls below run in parallel — fire all of them in a
   single response. Recall is wait-free server-side; serialising
   independent angles wastes wall-clock time. Only serialise
   when one recall's result names the next recall's seed (e.g.
   "X depends on Y" → then recall Y).

2. **For each angle, dual recall by default — knowledge AND
   timeline.** Two recalls per angle, in parallel:
   - **Knowledge recall** — the user's question as the query.
     Returns durable findings, decisions, project models, concept
     notes. This is "what's known".
   - **Timeline recall** — query phrased to capture activity
     ("recent activity on X", "what happened with Y", "where did
     we leave off on Z"), `max_versions_per_doc: 5`. Order by
     `lastModified` desc. This surfaces chronological/session
     entries — "what's been done, when, where the trail stops".

   Pick the `mode` per angle (see Mode selection above) — match
   the question shape, don't default to thorough. Knowledge
   recalls often benefit from `thorough` or `local`; timeline
   recalls usually do fine on `default` or `simple` since the
   relevance signal is recency, not synthesis.

   Always do BOTH passes. The agent rarely knows in advance
   whether prior session work touched the topic — assume yes
   until the timeline pass returns empty. Zero-hit recalls are
   cheap; the cost of always-fan-out is much lower than the
   cost of missing "we already covered this; here's where we
   left off".

3. **Read the results.** The chunk IS the answer. Do not follow
   up with `read` / `cat` / `find` against the source URI — the
   `excerpt` field carries what you need. Only fall back to
   filesystem reads via the result's `absolutePath` field
   (verbatim, never reconstructed) when the user explicitly
   asked for the *full* document. Distinguish chunks by content
   shape, not by hard-coded paths: tabular rows with explicit
   timestamps / agents / per-row mutations = activity timeline;
   prose with a thesis = durable knowledge; everything else =
   adjacent corpus material.

4. **Identify unsupported sub-claims AND gaps.** For each piece
   of the answer you would write, ask: *"Can I point to a specific
   passage in the recall results that supports this?"* If no →
   unsupported. Also: scan the timeline rows for **gaps** —
   claims mentioned but not yet investigated, hypotheses raised
   but not resolved, decisions deferred. Surface those
   explicitly; they ARE the value-add for "state of X" prompts.

5. **Recall again, tighter.** For each unsupported sub-claim or
   gap worth probing, issue a fresh recall with a tighter query.
   Independent gaps → parallel recalls (same fan-out rule as
   step 1). Do NOT synthesise across the gap with general
   knowledge. If the second recall also returns nothing
   relevant, report the gap to the user — do not invent.

6. **Resolve conflicts by recency.** When recall results
   disagree, prefer the entry with the most recent
   `lastModified`; treat older entries as superseded. Older-but-
   not-removed entries are stale, not "conflicting". For
   diff-style questions ("what changed in X"), use
   `max_versions_per_doc ≥ 5` and `as_of` to anchor the "before"
   snapshot; compose as structured diff (added / removed /
   changed) with explicit version references.

7. **Compose the answer with citations + state report.** Each
   non-trivial claim links to the supporting recall result by
   `source` (a citation URI for provenance — do NOT pass to a
   shell tool). For state-of-work questions, structure the
   answer: "Known: … | Last moves: … | Open gaps: …".

If a single recall returns 0 hits, do NOT auto-fan-out to 5
paraphrases. Try ONE rephrasing or a different mode; if still
nothing, report the gap.

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

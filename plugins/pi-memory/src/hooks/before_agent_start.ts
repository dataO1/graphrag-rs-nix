// before_agent_start hook — grounding rules + catalog hints + staleness notes.
//
// Injects systemPrompt addenda the LLM sees alongside the user's
// prompt for THIS turn. No extra LLM call; no auto-firing of tools.
// ---------------------------------------------------------------------------

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

import { HINT_RECALL_ENABLED } from "../config";
import { matchCatalog } from "../catalog";
import { drainStalenessNotes } from "../sse";

export function registerBeforeAgentStartHook(
  pi: ExtensionAPI,
): void {
  pi.on("before_agent_start", async (event, _ctx) => {
    const parts: string[] = [];

    // Always-on grounding rule — the single biggest failure pattern
    // is under-triggering.
    parts.push(
      "[memory] Never answer questions about the user's stored memory " +
        "from training data or guesswork. If the user's question depends " +
        "on something they have written down, decided, planned, or noted, " +
        "your FIRST action MUST be `memory_recall`. Trigger even when the " +
        "user doesn't say \"recall\" / \"check\" / \"look up\".",
    );

    // Abstention rule — structural check, not confidence check.
    parts.push(
      "[memory] Before answering any non-trivial user-specific " +
        "question, check: \"Can I point to the exact passage in THIS " +
        "conversation that supports my answer?\" If no — recall. This is " +
        "a structural check, not a confidence check.",
    );

    // Anti-filesystem-chase rule.
    parts.push(
      "[memory] When `memory_recall` returns content, the chunk " +
        "excerpt IS the answer for the user's question — don't follow up " +
        "with `read`/`cat`/`find`/`grep` on the source. The `source` " +
        "field is a citation URI for provenance, not a filesystem path; " +
        "do not pass it to a shell tool. If the chunk is genuinely " +
        "insufficient (user asked for the full document, or the excerpt " +
        "truncates content the user needs), use the `absolutePath` field " +
        "on the result — the only safe filesystem input. If `absolutePath` " +
        "is absent, the source is external; recall again with a sharper " +
        "query.",
    );

    // Recency rule.
    parts.push(
      "[memory] When recall results disagree about a fact, prefer the " +
        "chunk with the most recent `lastModified`; treat older chunks " +
        "as superseded.",
    );

    // Multi-hop / deep recall guidance.
    parts.push(
      "[memory] For deep multi-hop lookups, 'what changed' diffs, " +
        "research-style synthesis across multiple sources, or BEFORE " +
        "starting a complex task that needs prior context (designing, " +
        "implementing, refactoring, or debugging something the user " +
        "has prior notes on), use `memory_recall` with `reason: true` " +
        "to decompose the question into sub-queries. Do NOT stitch " +
        "ad-hoc individual recalls when a compound question needs " +
        "cross-referencing. After recall returns, synthesise the hits " +
        "into a coherent answer WITH CITATIONS — cite the chunk's " +
        "`source` field for each claim. If any sub-claim is " +
        "unsupported, recall again with a tighter query rather than " +
        "bridging the gap yourself. For diff-style questions 'what " +
        "changed in X', set `maxVersionsPerDoc` ≥ 2.",
    );

    // ── Catalog hint ──────────────────────────────────────────
    if (HINT_RECALL_ENABLED) {
      const promptText: string = event.prompt ?? "";
      if (promptText) {
        const matches = matchCatalog(promptText);
        if (matches.length > 0) {
          const titles = matches
            .map((m) => `"${m.title}"`)
            .join(", ");
          parts.push(
            `[memory] Catalog has potentially relevant docs: ${titles}. ` +
              `If relevant to the user's request, call memory_recall before proceeding.`,
          );
        }
      }
    }

    // ── Stale-context notes ───────────────────────────────────
    const staleness = drainStalenessNotes();
    if (staleness) parts.push(staleness);

    if (parts.length === 0) return;
    return { systemPrompt: parts.join("\n\n") };
  });
}

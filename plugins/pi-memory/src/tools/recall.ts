// memory_recall — query the user's long-term memory.
// ---------------------------------------------------------------------------

import { Type } from "typebox";
import { StringEnum } from "@mariozechner/pi-ai";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

import { memoryRequest } from "../memory-client";
import {
  incRecall,
  decRecall,
  refreshBadge,
  recallCallTag,
  recallCallTagError,
  recallOutcomeLine,
} from "../ui";
import { getMemoryState } from "../sse";
import { getTypeSection } from "../kinds";

export function registerRecall(pi: ExtensionAPI) {
  const typeSection = getTypeSection();
  pi.registerTool({
    name: "memory_recall",
    label: "recall",
    description:
      "Use whenever the user's question depends on something in their long-term memory — anything they have written down, decided, planned, or noted. Use even if the user does not explicitly say \"recall\" / \"check\" / \"look up\". Even if you think you already know the answer, if it depends on user-specific facts you MUST recall first.\n\n" +
      "**THE CHUNK IS THE ANSWER.** When this returns content, the `A:` block + the excerpts under `Top N hits:` are what you respond from. Do NOT follow up with `read`/`cat`/`find`/`grep` against the source. The classic failure: agent gets a good excerpt, gets nervous, guesses a path from the `source` URI, hits ENOENT, runs `find /` to recover — eating 30+ seconds when the excerpt was already sufficient.\n\n" +
      "ABSTENTION RULE: before answering any non-trivial question that depends on user-specific context, check whether you can point to the exact passage in THIS conversation that supports your answer. If you cannot — recall. This is a structural check, not a confidence check.\n\n" +
      "If the excerpt is genuinely insufficient (user asked for the full document, or the excerpt visibly truncates content the user needs), each hit has an `absolutePath` field — the resolved local-readable filesystem path. Pass it VERBATIM to your read tool. NEVER reconstruct paths from the `source` URI; NEVER prepend cwd; NEVER guess from training data. If a hit has no `absolutePath`, the source is external — recall again with a sharper query instead.\n\n" +
      "Mode picks the retrieval strategy: `default` (full multi-hop synthesis via HippoRAG, ~6s), `quick` (fast vector-keyword excerpts, ~50ms). Set `reason: true` for compound multi-hop questions (forces HippoRAG).\n\n" +
      "Time/history filters (use whenever the user references time):\n" +
      "  • `asOf` — RFC 3339; only consider entries valid at-or-after this time.\n" +
      "  • `maxVersionsPerDoc` — defaults to 1 (current only). ≥2 for diff-style questions.\n\n" +
      "PARALLELISE — independent recall questions go in one tool-call batch. Sequential is wasted wall-clock time." +
      typeSection,
    promptSnippet:
      "memory_recall — first action when the user's question depends on long-term memory; excerpt IS the answer; absolutePath is the only safe filesystem input. Modes: default|quick. reason=true for multi-hop. SAFE TO PARALLELISE.",
    promptGuidelines: [
      "Recall is the FIRST action whenever the user's question depends on something in their long-term memory — even when they don't explicitly say \"recall\" / \"check\" / \"look up\".",
      "Before answering any non-trivial user-specific question, check: \"Can I point to the exact passage in THIS conversation that supports my answer?\" If no — recall. This is a structural check, not a confidence check.",
      "The excerpt IS the answer for most queries — answer the user from it directly without a follow-up `read`.",
      "If you must read the source, use `absolutePath` from the hit verbatim. Never reconstruct from `source` (a citation URI, not a path); never prepend cwd; never guess.",
      "If a hit has no `absolutePath`, the source is external — you cannot filesystem-read it; recall again with a sharper query.",
      "Start with mode=default. Use quick only for fast existence checks or straightforward lookups.",
      "When recall results disagree about a fact, prefer the chunk with the most recent `lastModified`; treat older chunks as superseded.",
      "Time-bound queries (\"today\", \"yesterday\", \"since X\", \"this week\") MUST set `asOf` to the appropriate RFC 3339 timestamp.",
      "Diff-style questions (\"what changed in entry X\") MUST set `maxVersionsPerDoc` ≥ 2 so prior versions are visible.",
      "PARALLELISE: when the user asks about several distinct topics, fire one memory_recall per topic in the same tool batch. Don't serialise independent questions.",
      "For deep multi-hop lookups, 'what changed' diffs, or research-style synthesis across multiple sources, use `reason: true` to decompose the question into sub-queries. After recall returns, synthesise the hits with citations — cite the chunk's `source` field for each claim.",
      "If an excerpt leaves any sub-claim unsupported, recall again with a tighter query. Do not synthesise across the gap.",
    ],
    parameters: Type.Object({
      question: Type.String({
        description: "Natural-language question.",
      }),
      mode: Type.Optional(
        StringEnum(["default", "quick"] as const, {
          description:
            "`default`: Full multi-hop synthesis via HippoRAG (~6s). `quick`: Fast vector-keyword excerpts (~50ms).",
        }),
      ),
      reason: Type.Optional(
        Type.Boolean({
          description:
            "Decompose into sub-queries for compound multi-hop questions (slowest). Forces default mode. Use when a recall leaves sub-claims unsupported or you need research-style synthesis across multiple sources.",
        }),
      ),
      topK: Type.Optional(
        Type.Integer({
          default: 8,
          minimum: 1,
          maximum: 50,
          description: "Top-K seeds.",
        }),
      ),
      asOf: Type.Optional(
        Type.String({
          description:
            "RFC 3339 (e.g. '2026-05-06T00:00:00Z'). Only consider chunks valid at-or-after this time. Use for 'today', 'yesterday', 'since X'.",
        }),
      ),
      maxVersionsPerDoc: Type.Optional(
        Type.Integer({
          default: 1,
          minimum: 1,
          maximum: 10,
          description:
            "Per source doc, how many recent versions to consider. 1 = current only (default). Set ≥2 for diff-style questions ('what changed in X').",
        }),
      ),
      // type / recencyBoost are always present in the schema but only
      // meaningful when kinds are configured (typeSection non-empty).
      // The TYPE section in the description carries the operator-defined
      // kind names; when no kinds are configured the params are silently
      // accepted but the server will reject unknown sourceKind values (400).
      type: Type.Optional(
        Type.String({
          description:
            "Kind filter: restricts recall to documents of this kind. See the TYPE section in the tool description for available kinds.",
        }),
      ),
      recencyBoost: Type.Optional(
        Type.Boolean({
          description:
            "Override the kind's default recency-rerank setting. true = apply recency decay; false = disable it.",
        }),
      ),
    }),
    executionMode: "parallel",
    renderCall: (args, theme, ctx) => {
      const r: any = (ctx as any)?.result;
      return r?.isError
        ? recallCallTagError(theme as any, args)
        : recallCallTag(theme as any, args);
    },
    renderResult: (result, _opts, theme) =>
      recallOutcomeLine(theme as any, result),
    async execute(
      _toolCallId,
      params,
      _signal,
      _onUpdate,
      ctx,
    ) {
      incRecall();
      refreshBadge();
      try {
        const {
          question,
          mode,
          reason,
          topK,
          asOf,
          maxVersionsPerDoc,
          type: sourceKind,
          recencyBoost,
        } = params as Record<string, any>;
        const agentMode = mode ?? "default";
        const serverMode =
          reason || agentMode === "default"
            ? "hipporag"
            : agentMode === "quick"
              ? "search"
              : "hipporag";

        const body: Record<string, unknown> = {
          query: question,
          mode: serverMode,
          top_k: topK ?? 8,
        };
        if (asOf) body.asOf = asOf;
        if (maxVersionsPerDoc && maxVersionsPerDoc > 1)
          body.maxVersionsPerDoc = maxVersionsPerDoc;
        if (sourceKind !== undefined && sourceKind !== null)
          body.sourceKind = sourceKind;
        if (recencyBoost !== undefined && recencyBoost !== null)
          body.recencyBoost = recencyBoost;
        const ms = getMemoryState();
        if (ms?.sessionId) body.sessionId = ms.sessionId;

        const result = await memoryRequest(
          "POST",
          "/api/query",
          body,
        );

        // Build agent-facing text.
        let text = "";

        // Preamble: list every distinct absolutePath.
        const seenPaths = new Set<string>();
        const absPaths: string[] = [];
        for (const r of result.results ?? []) {
          if (
            r.absolutePath &&
            !seenPaths.has(r.absolutePath)
          ) {
            seenPaths.add(r.absolutePath);
            absPaths.push(r.absolutePath);
          }
        }
        if (absPaths.length > 0) {
          text +=
            "READABLE FILES (pass these absolute paths VERBATIM to your read " +
            "tool ONLY if the chunk excerpts below are insufficient. Do NOT " +
            "guess paths from the `source` URI; do NOT prepend cwd; do NOT " +
            "transform the `source` URI into a filesystem path — the " +
            "resolved path is right here):\n";
          for (const p of absPaths) text += `  • ${p}\n`;
          text +=
            "\nTHE CHUNK EXCERPTS BELOW ARE THE ANSWER for most queries. " +
            "Read them and respond. Only escalate to a file `read` if the " +
            "user explicitly asked for the full document or the excerpt " +
            "clearly truncates content the user needs.\n\n";
        }

        text += `Q: ${question}\nMode: ${result.mode}\n`;
        if (result.answer)
          text += `\nA: ${result.answer}\n`;
        if (
          result.confidence !== undefined &&
          result.confidence !== null
        ) {
          text += `Confidence: ${result.confidence.toFixed(2)}\n`;
        }
        if (
          result.keyEntities &&
          result.keyEntities.length > 0
        ) {
          text += `Entities: ${result.keyEntities.join(", ")}\n`;
        }
        if (
          result.reasoningSteps &&
          result.reasoningSteps.length > 0
        ) {
          text += "\nReasoning:\n";
          for (const step of result.reasoningSteps) {
            text += `  ${step.step}. ${step.description} (conf ${step.confidence.toFixed(2)})\n`;
            if (step.evidence) text += `     ${step.evidence}\n`;
          }
        }
        if (result.sources && result.sources.length > 0) {
          text += "\nSources:\n";
          for (const src of result.sources) {
            text += `  - ${src.kind} (${src.id}): ${src.relevance.toFixed(2)} — ${src.excerpt.slice(0, 200)}\n`;
          }
        }
        text += `\nTop ${result.results.length} hits:\n`;
        for (const r of result.results) {
          const src = r.source ? ` ← ${r.source}` : "";
          const lines =
            r.lineStart && r.lineEnd
              ? r.lineStart === r.lineEnd
                ? `:${r.lineStart}`
                : `:${r.lineStart}-${r.lineEnd}`
              : "";
          const head =
            Array.isArray(r.headingPath) &&
            r.headingPath.length > 0
              ? ` [${r.headingPath.join(" > ")}]`
              : "";
          const ts = r.lastModified
            ? ` @ ${r.lastModified}`
            : "";
          const abs = r.absolutePath
            ? `\n    readable @ ${r.absolutePath}`
            : "";
          text += `  - "${r.title}" (sim ${r.similarity.toFixed(3)})${ts}${src}${lines}${head}${abs}\n    ${r.excerpt}\n`;
        }
        text += `\n${result.processingTimeMs}ms`;
        return {
          content: [{ type: "text", text }],
        };
      } finally {
        decRecall();
        refreshBadge();
      }
    },
  });
}

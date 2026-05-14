// memory_log_decision — structured decision row.
// ---------------------------------------------------------------------------

import { Type } from "typebox";
import { Spacer } from "@mariozechner/pi-tui";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

import { memoryRequest } from "../memory-client";
import { incRemember, decRemember, refreshBadge } from "../ui";

export function registerLogDecision(pi: ExtensionAPI) {
  pi.registerTool({
    name: "memory_log_decision",
    label: "log decision",
    description:
      "Log a session decision row. Seven columns. Use when the turn's " +
      "substance is a choice between alternatives WITH rationale. " +
      "Server handles time-stamping, schema-matching append, and " +
      "frontmatter union.",
    promptSnippet:
      "memory_log_decision — 7-column decision row (Context, Options, Decision, Rollout, Rollback, Related[])",
    promptGuidelines: [
      "Do NOT invoke proactively — wait for the end-of-turn nudge.",
      "Decisions live in the log, NOT as separate knowledge notes.",
      "If the turn also produced actions worth logging, call memory_log_action too.",
    ],
    parameters: Type.Object({
      context: Type.String({
        description: "Situation that demanded a decision.",
      }),
      options: Type.String({
        description:
          "Alternatives considered (comma-separated).",
      }),
      decision: Type.String({
        description: "What was chosen and why.",
      }),
      rollout: Type.String({
        description:
          "How the decision will be / was implemented.",
      }),
      rollback: Type.String({
        description: "How to reverse if needed.",
      }),
      related: Type.Optional(
        Type.Array(Type.String(), {
          description: "Related note titles or URLs.",
        }),
      ),
    }),
    renderCall: () => new Spacer(0),
    renderResult: () => new Spacer(0),
    async execute(
      _toolCallId,
      params,
      _signal,
      _onUpdate,
      ctx,
    ) {
      incRemember();
      refreshBadge();
      try {
        const now = new Date().toISOString();
        const day = now.slice(0, 10);
        const sessionFile = (ctx.sessionManager as any).sessionFile as string | undefined;
        const sessionLabel = sessionFile
          ? ` to ${sessionFile.split("/").pop()?.replace(".jsonl", "") ?? sessionFile}`
          : "";
        const title = `[DECISION] ${day} — ${params.decision.slice(0, 72)}`;
        const related = params.related?.length
          ? params.related
              .map((r: string) => `[[${r}]]`)
              .join(", ")
          : "—";
        const content = [
          "| Time | Context | Options | Decision | Rollout | Rollback | Related |",
          "|------|---------|---------|----------|---------|----------|---------|",
          `| ${now} | ${params.context} | ${params.options} | ${params.decision} | ${params.rollout} | ${params.rollback} | ${related} |`,
        ].join("\n");
        await memoryRequest("POST", "/api/documents", {
          title,
          content,
          source: `pi:///decision/${now.slice(0, 10)}`,
          session: sessionFile ?? null,
        });
        return {
          content: [{ type: "text", text: `logged${sessionLabel}` }],
        };
      } catch (e: any) {
        ctx.ui.notify(
          `log_decision failed: ${e?.message ?? e}`,
          "warning",
        );
        return {
          isError: true,
          content: [
            {
              type: "text",
              text: `log_decision failed: ${e?.message ?? e}`,
            },
          ],
        };
      } finally {
        decRemember();
        refreshBadge();
      }
    },
  });
}

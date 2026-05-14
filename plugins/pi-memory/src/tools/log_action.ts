// memory_log_action — structured action row.
// ---------------------------------------------------------------------------

import { Type } from "typebox";
import { Spacer } from "@mariozechner/pi-tui";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

import { memoryRequest } from "../memory-client";
import { incRemember, decRemember, refreshBadge } from "../ui";

export function registerLogAction(pi: ExtensionAPI) {
  pi.registerTool({
    name: "memory_log_action",
    label: "log action",
    description:
      "Log a session action row. Six columns. Use when the turn produced " +
      "an architectural change, bug fix, doc edit, research finding, " +
      "deliverable, or unexpected outcome. Server handles time-stamping, " +
      "schema-matching append, and frontmatter union.",
    promptSnippet:
      "memory_log_action — 6-column action row (Actions, Mutations, Why, Outcome, Related[])",
    promptGuidelines: [
      "Do NOT invoke proactively — wait for the end-of-turn nudge.",
      "If the turn also produced a decision, call memory_log_decision too.",
      "The `related` array should cite knowledge notes when applicable.",
    ],
    parameters: Type.Object({
      actions: Type.String({
        description: "What was done (one sentence).",
      }),
      mutations: Type.String({
        description: "What changed (files, config, state).",
      }),
      why: Type.String({
        description: "Why this was done (context, trigger).",
      }),
      outcome: Type.String({
        description: "Result / deliverable / next step.",
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
        const title = `[LOG] ${day} — ${params.actions.slice(0, 72)}`;
        const related = params.related?.length
          ? params.related
              .map((r: string) => `[[${r}]]`)
              .join(", ")
          : "—";
        const content = [
          "| Time | Actions | Mutations | Why | Outcome | Related |",
          "|------|---------|-----------|-----|---------|---------|",
          `| ${now} | ${params.actions} | ${params.mutations} | ${params.why} | ${params.outcome} | ${related} |`,
        ].join("\n");
        await memoryRequest("POST", "/api/documents", {
          title,
          content,
          source: `pi:///log/${now.slice(0, 10)}`,
          session: sessionFile ?? null,
        });
        return {
          content: [{ type: "text", text: `logged${sessionLabel}` }],
        };
      } catch (e: any) {
        ctx.ui.notify(
          `log_action failed: ${e?.message ?? e}`,
          "warning",
        );
        return {
          isError: true,
          content: [
            {
              type: "text",
              text: `log_action failed: ${e?.message ?? e}`,
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

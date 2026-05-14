// /recall and /remember slash commands — explicit user control.
// ---------------------------------------------------------------------------

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

import { memoryRequest } from "../memory-client";
import { incRecall, decRecall, incRemember, decRemember, refreshBadge, getLastAssistantText } from "../ui";
import { getMemoryState } from "../sse";

export function registerCommands(pi: ExtensionAPI): void {
  pi.registerCommand("recall", {
    description:
      "Recall from your long-term memory. Usage: `/recall <question>`. " +
      "Uses default mode (relational + semantic).",
    handler: async (args: string, ctx) => {
      const q = (args ?? "").trim();
      if (!q) {
        ctx.ui.notify("Usage: /recall <question>", "warning");
        return;
      }
      incRecall();
      refreshBadge();
      try {
        const r = await memoryRequest("POST", "/api/query", {
          query: q,
          mode: "hipporag",
          top_k: 8,
          ...(getMemoryState()?.sessionId
            ? { sessionId: getMemoryState()!.sessionId }
            : {}),
        });
        const ans = r?.answer ?? "(no answer)";
        const conf =
          r?.confidence != null
            ? ` (conf ${r.confidence.toFixed(2)})`
            : "";
        ctx.ui.notify(
          `Recall${conf}: ${ans}`,
          "info",
        );
      } catch (e: any) {
        ctx.ui.notify(
          `Recall failed: ${e?.message ?? e}`,
          "error",
        );
      } finally {
        decRecall();
        refreshBadge();
      }
    },
  });

  pi.registerCommand("remember", {
    description:
      "Commit something to long-term memory. Usage: `/remember <title>` " +
      "captures the LAST assistant message; `/remember <title> | <content>` " +
      "stores explicit content. Pipe is the separator.",
    handler: async (args: string, ctx) => {
      const raw = (args ?? "").trim();
      if (!raw) {
        ctx.ui.notify(
          "Usage: /remember <title> [| <content>]",
          "warning",
        );
        return;
      }
      const pipeIdx = raw.indexOf("|");
      const title = (
        pipeIdx >= 0 ? raw.slice(0, pipeIdx) : raw
      ).trim();
      const explicit =
        pipeIdx >= 0 ? raw.slice(pipeIdx + 1).trim() : "";
      const content = explicit || getLastAssistantText();
      if (!content) {
        ctx.ui.notify(
          "No content to remember (provide '| <content>' or send a turn first).",
          "warning",
        );
        return;
      }
      incRemember();
      refreshBadge();
      try {
        await memoryRequest("POST", "/api/documents", {
          title,
          content,
          id: title,
          source: `pi:///command/${title}`,
        });
        ctx.ui.notify(`Remembered: ${title}`, "info");
      } catch (e: any) {
        ctx.ui.notify(
          `Remember failed: ${e?.message ?? e}`,
          "error",
        );
      } finally {
        decRemember();
        refreshBadge();
      }
    },
  });
}

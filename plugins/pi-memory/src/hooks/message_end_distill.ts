// message_end hook — rewrite distillation-turn responses as compact
// muted-gray summaries. Only rewrites when the assistant message has
// NO tool calls (tool_use/tool_result pairing must never be broken).
//
// The LLM responds to the DISTILL_NUDGE with a compact one-liner:
//   ✓ nothing to distill
//   📝 logged: 1 action + 2 decisions
//   📝 consolidated: <title>
// We wrap it in a custom message type so it renders dimmer than
// normal assistant text, matching the "Thinking..." aesthetic.
// ---------------------------------------------------------------------------

import { Text } from "@mariozechner/pi-tui";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

import { isDistillTurn } from "../distill";

export function registerDistillSummaryRenderer(
  pi: ExtensionAPI,
): void {
  pi.registerMessageRenderer(
    "memory-distill-summary",
    (_entry: any, theme: any) => {
      const text = typeof _entry?.content === "string"
        ? _entry.content
        : "";
      return new Text(theme.fg("muted", text));
    },
  );
}

export function registerDistillSummaryHook(
  pi: ExtensionAPI,
): void {
  pi.on("message_end", async (event) => {
    if (!isDistillTurn()) return undefined;

    const msg = event.message;
    if (msg?.role !== "assistant") return;

    const content = msg.content ?? [];

    // SAFETY: never rewrite a message that contains tool calls.
    // Tool_use/tool_result pairing must stay intact (pi-mono #4189).
    const hasToolCalls = content.some(
      (part: any) => part?.type === "toolCall",
    );
    if (hasToolCalls) return undefined;

    // Extract the LLM's text response — this is the summary line.
    const text = content
      .filter(
        (part: any) =>
          part?.type === "text" && typeof part.text === "string",
      )
      .map((part: any) => part.text.trim())
      .join(" ")
      .trim();

    // If the LLM didn't produce text (unusual), leave unchanged.
    if (!text) return undefined;

    // Replace the message with a custom-typed summary that our
    // renderer styles in muted gray. The original tool-call-free
    // content is safe to replace — no pairing to break.
    return {
      message: {
        ...msg,
        // customType tells pi to use our registered renderer
        customType: "memory-distill-summary",
        content: text,
      },
    };
  });
}

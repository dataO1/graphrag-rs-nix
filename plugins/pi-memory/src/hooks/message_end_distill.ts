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
      // content is a content-block array (e.g. [{type:"text", text:"..."}])
      const content = _entry?.content;
      let text = "";
      if (Array.isArray(content)) {
        text = content
          .filter((p: any) => p?.type === "text" && typeof p.text === "string")
          .map((p: any) => p.text.trim())
          .join(" ");
      } else if (typeof content === "string") {
        text = content;
      }
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

    // SAFETY: content might be a bare string or plain object `{}`.
    // `.some()` / `.filter()` on non-arrays crashes with
    // "message.content.some is not a function".
    // The filter hook (runs before this one) should have normalized
    // it, but we guard defensively — no dependency ordering guarantee.
    const content: Array<any> = Array.isArray(msg.content)
      ? msg.content
      : typeof msg.content === "string"
        ? [{ type: "text", text: msg.content }]
        : [];

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
    //
    // SAFETY: content MUST be a content-block array (not a bare string).
    // Pi's AssistantMessageComponent.updateContent calls .some() on it,
    // and a string crashes with "message.content.some is not a function".
    return {
      message: {
        ...msg,
        // customType tells pi to use our registered renderer
        customType: "memory-distill-summary",
        content: [{ type: "text", text }],
      },
    };
  });
}

// message_end hook — strip empty-name toolCall artifacts + normalize
// non-array content.
//
// The LLM (particularly MTP-capable models) sometimes emits `toolCall`
// content parts with `name: ""` (empty string) alongside legitimate tool
// calls. Pi's tool router cannot resolve `""` → returns `Tool  not found`,
// which leaks into the chat as `{}` / "Tool  not found" artifacts.
//
// CRITICAL: Pi's AssistantMessageComponent.updateContent calls `.some()`
// on `message.content`. If content is a plain object `{}` or a bare string,
// `.some` is undefined → crash:
//   TypeError: message.content.some is not a function
//
// This hook normalizes non-array content to prevent that crash. If content
// was `{}` (empty tool-result object), it becomes `[]`. If content was a
// bare string, it becomes `[{type:"text", text:"..."}]`.
//
// SAFETY: we never collapse message content to empty — that would
// orphan tool_use/tool_result blocks and cause unrecoverable session
// corruption (pi-mono issue #4189).
// ---------------------------------------------------------------------------

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

/**
 * Normalize `content` to always be a content-block array.
 *
 * Handles every shape we've seen in the wild:
 *   — array → pass through
 *   — string → wrap in single text block
 *   — object `{}` → empty array
 *   — null/undefined → empty array
 */
function normalizeContent(raw: any): Array<any> {
  if (Array.isArray(raw)) return raw;
  if (typeof raw === "string") return [{ type: "text", text: raw }];
  // Plain object, number, boolean, etc. → empty array.
  // A bare `{}` is a tool-router placeholder that carries no useful data.
  return [];
}

export function registerMessageEndFilterHook(
  pi: ExtensionAPI,
): void {
  pi.on("message_end", async (event) => {
    const msg = event.message;
    if (msg?.role !== "assistant") return;

    const normalized = normalizeContent(msg.content);
    const filtered = normalized.filter(
      (part: any) =>
        part?.type !== "toolCall" ||
        (part.name ?? "").length > 0,
    );

    // Return the normalized (and possibly filtered) message when:
    // 1. Content was NOT an array → MUST normalize to prevent the
    //    `.some()` crash in Pi's UI (regression safety net).
    // 2. Content was an array but we stripped empty-name tool calls
    //    (original purpose of this hook).
    if (filtered.length !== normalized.length || !Array.isArray(msg.content)) {
      return { message: { ...msg, content: filtered } };
    }
    return undefined;
  });
}

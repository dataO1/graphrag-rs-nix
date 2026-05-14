// message_end hook — strip empty-name toolCall artifacts.
//
// The LLM (particularly MTP-capable models) sometimes emits `toolCall`
// content parts with `name: ""` (empty string) alongside legitimate tool
// calls. Pi's tool router cannot resolve `""` → returns `Tool  not found`,
// which leaks into the chat as `{}` / "Tool  not found" artifacts.
//
// SAFETY: we never collapse message content to empty — that would
// orphan tool_use/tool_result blocks and cause unrecoverable session
// corruption (pi-mono issue #4189).
// ---------------------------------------------------------------------------

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

export function registerMessageEndFilterHook(
  pi: ExtensionAPI,
): void {
  pi.on("message_end", async (event) => {
    const msg = event.message;
    if (msg?.role !== "assistant") return;
    const content = msg.content ?? [];
    const filtered = content.filter(
      (part: any) =>
        part?.type !== "toolCall" ||
        (part.name ?? "").length > 0,
    );
    if (filtered.length !== content.length) {
      return { message: { ...msg, content: filtered } };
    }
    return undefined;
  });
}

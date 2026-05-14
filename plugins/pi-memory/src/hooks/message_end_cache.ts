// message_end hook — cache last assistant text for /remember command.
// ---------------------------------------------------------------------------

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

import { extractAssistantText, setLastAssistantText } from "../ui";

export function registerMessageEndCacheHook(
  pi: ExtensionAPI,
): void {
  pi.on("message_end", async (event, _ctx) => {
    const msg = event.message;
    if (msg?.role !== "assistant") return;
    const text = extractAssistantText(msg);
    if (text) {
      setLastAssistantText(text);
    }
  });
}

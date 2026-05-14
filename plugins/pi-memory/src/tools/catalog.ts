// memory_catalog — page through entries in long-term memory.
// ---------------------------------------------------------------------------

import { Type } from "typebox";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

import { memoryRequest } from "../memory-client";

export function registerCatalog(pi: ExtensionAPI) {
  pi.registerTool({
    name: "memory_catalog",
    label: "catalog",
    description:
      "Page through entries currently in long-term memory. Use to discover what's already there before deciding to `remember` something that may already be present.",
    promptSnippet: "memory_catalog — list stored entries",
    parameters: Type.Object({}),
    async execute(_toolCallId) {
      const result = await memoryRequest("GET", "/api/documents");
      let text = `${result.total} document(s):\n`;
      if (result.documents.length === 0) {
        text += "  (none)\n";
      } else {
        for (const d of result.documents) {
          const extra = d.excerpt
            ? ` — ${d.excerpt.slice(0, 120)}…`
            : d.contentLength
              ? ` (${d.contentLength} chars)`
              : "";
          text += `  - "${d.title}" [${d.id}]${extra}\n`;
        }
      }
      return { content: [{ type: "text", text }] };
    },
  });
}

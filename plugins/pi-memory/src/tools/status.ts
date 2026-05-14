// memory_status — health / sanity check for the memory backend.
// ---------------------------------------------------------------------------

import { Type } from "typebox";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

import { memoryRequest } from "../memory-client";

export function registerStatus(pi: ExtensionAPI) {
  pi.registerTool({
    name: "memory_status",
    label: "status",
    description:
      "Memory health stats (entry counts, entity counts, relationship counts, vector counts) + lastBuiltAt. DO NOT call as a warm-up before recall — the toolbar `mem ●/○` badge already shows reachability. Only call when the user explicitly asks about memory size / build state, or to disambiguate an empty-memory vs no-match recall.",
    promptSnippet:
      "memory_status — only on explicit user request or 0-hit disambiguation",
    parameters: Type.Object({}),
    async execute(_toolCallId) {
      const result = await memoryRequest(
        "GET",
        "/api/graph/stats",
      );
      let text = `Status:\n`;
      text += `  Documents: ${result.documentCount}\n`;
      text += `  Entities: ${result.entityCount}\n`;
      text += `  Relationships: ${result.relationshipCount}\n`;
      text += `  Vectors: ${result.vectorCount}\n`;
      text += `  Built: ${result.graphBuilt ? "yes" : "no"}\n`;
      if (result.lastBuiltAt)
        text += `  Last built: ${result.lastBuiltAt}\n`;
      text += `  Backend: ${result.backend}`;
      return { content: [{ type: "text", text }] };
    },
  });
}

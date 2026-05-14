// memory_forget — remove an entry from long-term memory.
// ---------------------------------------------------------------------------

import { Type } from "typebox";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

import { memoryRequest } from "../memory-client";

export function registerForget(pi: ExtensionAPI) {
  pi.registerTool({
    name: "memory_forget",
    label: "forget",
    description:
      "Remove an entry from the user's long-term memory. Use sparingly — prefer asking the user before deleting personal material.",
    promptSnippet: "memory_forget — remove an entry by id",
    parameters: Type.Object({
      id: Type.String({
        description:
          "User-supplied id (path, custom string) or server UUID.",
      }),
    }),
    async execute(_toolCallId, params) {
      const result = await memoryRequest(
        "DELETE",
        `/api/documents/${encodeURIComponent(params.id)}`,
      );
      return {
        content: [
          {
            type: "text",
            text: `Forgot: ${result.message ?? params.id}`,
          },
        ],
      };
    },
  });
}

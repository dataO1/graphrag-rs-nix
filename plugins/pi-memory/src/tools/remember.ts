// memory_remember — ingest doc(s) into long-term memory.
// ---------------------------------------------------------------------------

import { Type } from "typebox";
import { Spacer } from "@mariozechner/pi-tui";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

import { memoryRequest } from "../memory-client";
import { incRemember, decRemember, refreshBadge } from "../ui";

export function registerRemember(pi: ExtensionAPI) {
  pi.registerTool({
    name: "memory_remember",
    label: "remember",
    description:
      "Commit material to the user's long-term memory. Pick one: `path` / `pathsGlob` / `paths` (on-disk files), or `content`+`title` (generated/pasted text). Recallable shortly after — no follow-up call needed.",
    promptSnippet:
      "memory_remember — prefer `path`/`pathsGlob` for on-disk files; `content` only for generated text",
    promptGuidelines: [
      "On-disk file → use `path` (or `pathsGlob`). Don't Read+forward via `content`.",
      "`content`+`title` is for generated/pasted text only.",
      "Batch response: `results[]` with status ∈ {ingested, duplicate, unsupported, rejected, error}.",
    ],
    parameters: Type.Object({
      path: Type.Optional(
        Type.String({
          description: "Absolute path to one file.",
        }),
      ),
      pathsGlob: Type.Optional(
        Type.String({
          description:
            "Glob, e.g. '/abs/dir/**/*.md' or relative + `globRoot`.",
        }),
      ),
      globRoot: Type.Optional(
        Type.String({
          description: "Anchor for relative `pathsGlob`.",
        }),
      ),
      paths: Type.Optional(
        Type.Array(Type.String(), {
          description: "Explicit list of absolute paths.",
        }),
      ),
      title: Type.Optional(
        Type.String({
          description: "Required for `content`.",
        }),
      ),
      content: Type.Optional(
        Type.String({
          description:
            "Inline body. Use only for generated/pasted text.",
        }),
      ),
      id: Type.Optional(
        Type.String({
          description:
            "Optional caller-supplied id for later `forget`.",
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

      const body: Record<string, unknown> = {};
      if (params.path !== undefined) body.path = params.path;
      if (params.pathsGlob !== undefined)
        body.pathsGlob = params.pathsGlob;
      if (params.globRoot !== undefined)
        body.globRoot = params.globRoot;
      if (params.paths !== undefined) body.paths = params.paths;
      if (params.content !== undefined)
        body.content = params.content;
      if (params.title !== undefined)
        body.title = params.title;
      if (params.id !== undefined) body.id = params.id;

      const hasContent = body.content !== undefined;
      if (hasContent && !body.source) {
        body.source = `pi://generated/${crypto.randomUUID?.() ?? `pi-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`}`;
      }

      // Fire-and-forget: schedule the POST, return immediately.
      void (async () => {
        try {
          await memoryRequest(
            "POST",
            "/api/documents",
            body,
          );
        } catch (e: any) {
          ctx.ui.notify(
            `memory_remember failed: ${e?.message ?? e}`,
            "warning",
          );
        } finally {
          decRemember();
          refreshBadge();
        }
      })();

      return {
        content: [{ type: "text", text: "queued" }],
      };
    },
  });
}

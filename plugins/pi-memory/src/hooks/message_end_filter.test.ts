// Tests for message_end_filter — strips empty-name toolCall artifacts.
//
// Safety properties:
//  • Never collapses content to empty (would orphan tool_use/tool_result)
//  • Always returns content as an array (not a bare string)
//  • Returns undefined when nothing to filter (no unnecessary rewrites)
// ---------------------------------------------------------------------------

import { describe, it, expect, vi, beforeEach } from "vitest";

type HookHandler = (event: any, ctx?: any) => Promise<any>;

interface MockPi {
  _messageEndHandlers: HookHandler[];
  on: ReturnType<typeof vi.fn>;
}

function createMockPi(): MockPi {
  const handlers: HookHandler[] = [];
  return {
    _messageEndHandlers: handlers,
    on: vi.fn((_event: string, handler: HookHandler) => {
      handlers.push(handler);
    }),
  };
}

import { registerMessageEndFilterHook } from "./message_end_filter";

describe("registerMessageEndFilterHook", () => {
  let pi: MockPi;

  beforeEach(() => {
    pi = createMockPi();
    registerMessageEndFilterHook(pi as any);
  });

  async function fireHook(message: any): Promise<any> {
    const handler = pi._messageEndHandlers[0];
    return handler({ message }, {});
  }

  // ── Content shape contract ───────────────────────────────────

  describe("content shape", () => {
    it("always returns content as an array (never a bare string)", async () => {
      const result = await fireHook({
        role: "assistant",
        content: [
          { type: "text", text: "hello" },
          { type: "toolCall", name: "", id: "x" },
        ],
      });

      expect(result).toBeDefined();
      expect(Array.isArray(result.message.content)).toBe(true);
    });

    it("survives .some() pi call — literal crash test", async () => {
      const result = await fireHook({
        role: "assistant",
        content: [
          { type: "text", text: "hello" },
          { type: "toolCall", name: "", id: "x" },
        ],
      });

      expect(() => {
        const content = result.message.content;
        const hasVisibleContent = content.some(
          (c: any) =>
            (c.type === "text" && c.text.trim()) ||
            (c.type === "thinking" && c.thinking.trim()),
        );
        expect(hasVisibleContent).toBe(true);
      }).not.toThrow();
    });
  });

  // ── Empty-name filtering ─────────────────────────────────────

  describe("empty-name toolCall removal", () => {
    it("removes toolCall blocks with name: ''", async () => {
      const result = await fireHook({
        role: "assistant",
        content: [
          { type: "text", text: "Let me check." },
          { type: "toolCall", name: "", id: "bad1" },
          { type: "text", text: "Done." },
        ],
      });

      expect(result).toBeDefined();
      const content = result.message.content;
      expect(content).toHaveLength(2);
      expect(content[0]).toEqual({ type: "text", text: "Let me check." });
      expect(content[1]).toEqual({ type: "text", text: "Done." });
    });

    it("removes toolCall blocks with missing name field", async () => {
      const result = await fireHook({
        role: "assistant",
        content: [
          { type: "text", text: "ok" },
          { type: "toolCall", id: "no-name" },
        ],
      });

      expect(result).toBeDefined();
      expect(result.message.content).toHaveLength(1);
      expect(result.message.content[0]).toEqual({ type: "text", text: "ok" });
    });

    it("keeps toolCall blocks with non-empty names", async () => {
      const result = await fireHook({
        role: "assistant",
        content: [
          { type: "text", text: "Let me recall." },
          { type: "toolCall", name: "memory_recall", id: "tc1" },
        ],
      });

      // No empty-name toolCalls → nothing to filter
      expect(result).toBeUndefined();
    });

    it("keeps legitimate toolCalls while removing empty-name ones", async () => {
      const result = await fireHook({
        role: "assistant",
        content: [
          { type: "text", text: "Working..." },
          { type: "toolCall", name: "", id: "bad" },
          { type: "toolCall", name: "bash", id: "good" },
          { type: "toolCall", name: "", id: "also-bad" },
        ],
      });

      expect(result).toBeDefined();
      const content = result.message.content;
      expect(content).toHaveLength(2);
      expect(content[0]).toEqual({ type: "text", text: "Working..." });
      expect(content[1]).toEqual({ type: "toolCall", name: "bash", id: "good" });
    });

    it("removes toolCall with name: '' at start of content", async () => {
      const result = await fireHook({
        role: "assistant",
        content: [
          { type: "toolCall", name: "", id: "bad-first" },
          { type: "text", text: "after" },
        ],
      });

      expect(result).toBeDefined();
      expect(result.message.content).toHaveLength(1);
      expect(result.message.content[0]).toEqual({ type: "text", text: "after" });
    });
  });

  // ── Role guard ───────────────────────────────────────────────

  describe("role guard", () => {
    it("ignores non-assistant messages", async () => {
      const result = await fireHook({
        role: "user",
        content: [{ type: "toolCall", name: "", id: "x" }],
      });
      expect(result).toBeUndefined();
    });

    it("ignores system messages", async () => {
      const result = await fireHook({
        role: "system",
        content: [{ type: "toolCall", name: "", id: "x" }],
      });
      expect(result).toBeUndefined();
    });
  });

  // ── No-op when nothing to filter ─────────────────────────────

  describe("returns undefined when clean", () => {
    it("no empty-name toolCalls", async () => {
      const result = await fireHook({
        role: "assistant",
        content: [
          { type: "text", text: "hello" },
          { type: "toolCall", name: "recall", id: "tc1" },
        ],
      });
      expect(result).toBeUndefined();
    });

    it("empty content array", async () => {
      const result = await fireHook({
        role: "assistant",
        content: [],
      });
      expect(result).toBeUndefined();
    });

    it("normalizes missing content field to empty array (prevent crash)",
      async () => {
        // msg.content === undefined → normalize to [] to prevent
        // Pi's .some() crash on non-array content.
        const result = await fireHook({
          role: "assistant",
          // no content field → msg.content === undefined
        });
        expect(result).toBeDefined();
        expect(Array.isArray(result.message.content)).toBe(true);
        expect(result.message.content).toHaveLength(0);
      });

    it("text-only content", async () => {
      const result = await fireHook({
        role: "assistant",
        content: [{ type: "text", text: "just text" }],
      });
      expect(result).toBeUndefined();
    });
  });

  // ── Edge cases ───────────────────────────────────────────────

  describe("edge cases", () => {
    it("handles toolCall with name: '' among many text blocks", async () => {
      const result = await fireHook({
        role: "assistant",
        content: [
          { type: "text", text: "a" },
          { type: "text", text: "b" },
          { type: "toolCall", name: "", id: "x" },
          { type: "text", text: "c" },
          { type: "text", text: "d" },
        ],
      });

      expect(result).toBeDefined();
      expect(result.message.content).toHaveLength(4);
    });

    it("handles only empty-name toolCalls (no text)", async () => {
      // Content becomes empty after filtering. NOT a problem here
      // because there are no tool_use/tool_result pairs to orphan.
      // But pi should still handle empty content arrays gracefully.
      const result = await fireHook({
        role: "assistant",
        content: [
          { type: "toolCall", name: "", id: "a" },
          { type: "toolCall", name: "", id: "b" },
        ],
      });

      expect(result).toBeDefined();
      // Content is now empty — pi survives this (it's different from
      // orphaned tool_use/tool_result).
      expect(result.message.content).toHaveLength(0);
    });

    it("keeps toolCall with name: '   ' (whitespace only) — current behavior", async () => {
      // Whitespace-only name has length > 0 so the current filter passes it.
      // This is a minor gap (whitespace names should arguably be filtered too)
      // but NOT a crash bug — pi just gets a "Tool    not found" artifact.
      // Documented: future improvement would trim() before checking length.
      const result = await fireHook({
        role: "assistant",
        content: [
          { type: "text", text: "ok" },
          { type: "toolCall", name: "   ", id: "ws" },
        ],
      });

      // No empty-name (length===0) toolCalls → nothing filtered → undefined
      expect(result).toBeUndefined();
    });

    it("preserves unknown block types", async () => {
      const result = await fireHook({
        role: "assistant",
        content: [
          { type: "text", text: "ok" },
          { type: "custom-thing", data: 42 },
          { type: "toolCall", name: "", id: "x" },
        ],
      });

      expect(result).toBeDefined();
      expect(result.message.content).toHaveLength(2);
      expect(result.message.content[0]).toEqual({ type: "text", text: "ok" });
      expect(result.message.content[1]).toEqual({ type: "custom-thing", data: 42 });
    });

    it("preserves other message fields", async () => {
      const result = await fireHook({
        role: "assistant",
        content: [
          { type: "text", text: "hi" },
          { type: "toolCall", name: "", id: "x" },
        ],
        id: "msg-456",
        model: "test-v1",
      });

      expect(result.message).toHaveProperty("id", "msg-456");
      expect(result.message).toHaveProperty("model", "test-v1");
      expect(result.message).toHaveProperty("role", "assistant");
    });
  });

  // ── Crash-prevention: non-array content normalization ──────
  // These are the cases that caused:
  //   TypeError: message.content.some is not a function
  // Pi's AssistantMessageComponent.updateContent calls .some() on
  // message.content. If it's a plain object `{}` or bare string,
  // `.some` is undefined → crash.
  //
  // Our hook MUST normalize non-array content to an array to prevent this.

  describe("non-array content normalization (crash prevention)", () => {
    it("normalizes plain object content `{}` to empty array", async () => {
      // This is the EXACT shape that caused the crash:
      // Pi creates an assistant message with content: {}
      // after a failed tool-call resolution.
      const result = await fireHook({
        role: "assistant",
        content: {},
      });

      // MUST return a normalized message, not undefined
      expect(result).toBeDefined();
      expect(Array.isArray(result.message.content)).toBe(true);
      expect(result.message.content).toHaveLength(0);

      // The returned content must survive Pi's .some() call
      expect(() => {
        result.message.content.some(
          (c: any) =>
            (c.type === "text" && c.text.trim()) ||
            (c.type === "thinking" && c.thinking.trim()),
        );
      }).not.toThrow();
    });

    it("normalizes bare string content to text block array", async () => {
      const result = await fireHook({
        role: "assistant",
        content: "just a string",
      });

      expect(result).toBeDefined();
      expect(Array.isArray(result.message.content)).toBe(true);
      expect(result.message.content).toEqual([
        { type: "text", text: "just a string" },
      ]);

      // Survive Pi's .some() call
      expect(() => {
        result.message.content.some(
          (c: any) =>
            (c.type === "text" && c.text.trim()) ||
            (c.type === "thinking" && c.thinking.trim()),
        );
      }).not.toThrow();
    });

    it("normalizes null content to empty array", async () => {
      const result = await fireHook({
        role: "assistant",
        content: null,
      });

      expect(result).toBeDefined();
      expect(Array.isArray(result.message.content)).toBe(true);
      expect(result.message.content).toHaveLength(0);
    });

    it("normalizes number content to empty array", async () => {
      const result = await fireHook({
        role: "assistant",
        content: 42,
      });

      expect(result).toBeDefined();
      expect(Array.isArray(result.message.content)).toBe(true);
      expect(result.message.content).toHaveLength(0);
    });

    it("normalizes boolean content to empty array", async () => {
      const result = await fireHook({
        role: "assistant",
        content: true,
      });

      expect(result).toBeDefined();
      expect(Array.isArray(result.message.content)).toBe(true);
      expect(result.message.content).toHaveLength(0);
    });

    it("normalizes object content with empty toolCall → removes it",
      async () => {
      // Edge case: if somehow a non-array object had tool-call-like
      // structure, we normalize to [] which has nothing to filter.
      // The normalization alone is the fix.
      const result = await fireHook({
        role: "assistant",
        content: { someField: "value" },
      });

      expect(result).toBeDefined();
      expect(result.message.content).toEqual([]);
    });

    it("preserves message identity when normalizing (spreads msg fields)",
      async () => {
      const result = await fireHook({
        role: "assistant",
        content: {},
        id: "msg-789",
        model: "crash-model",
        stopReason: "stop",
      });

      expect(result.message).toHaveProperty("id", "msg-789");
      expect(result.message).toHaveProperty("model", "crash-model");
      expect(result.message).toHaveProperty("role", "assistant");
      expect(Array.isArray(result.message.content)).toBe(true);
    });

    it("survives the EXACT crash reproduction from Pi's code", async () => {
      // This is the EXACT code path from assistant-message.js:54 that
      // crashed with "message.content.some is not a function":
      //   const hasVisibleContent = message.content.some((c) =>
      //     (c.type === "text" && c.text.trim()) ||
      //     (c.type === "thinking" && c.thinking.trim()));
      const result = await fireHook({
        role: "assistant",
        content: {}, // THE crash-causing shape
      });

      // Verify the hook returns a properly normalized message
      expect(result).toBeDefined();
      expect(Array.isArray(result.message.content)).toBe(true);

      // This is the EXACT crash site — must NOT throw
      expect(() => {
        const hasVisibleContent = result.message.content.some(
          (c: any) =>
            (c.type === "text" && c.text.trim()) ||
            (c.type === "thinking" && c.thinking.trim()),
        );
        expect(typeof hasVisibleContent).toBe("boolean");
      }).not.toThrow();
    });
  });

  // ── Structural invariants (applied to ALL return paths) ──────

  describe("structural invariants", () => {
    it("every return path produces either undefined or {message: {..., content: array}}",
      async () => {
        const scenarios: Array<{
          label: string;
          msg: any;
        }> = [
          {
            label: "normal array with text",
            msg: {
              role: "assistant",
              content: [{ type: "text", text: "hello" }],
            },
          },
          {
            label: "array with empty toolCall",
            msg: {
              role: "assistant",
              content: [
                { type: "text", text: "hi" },
                { type: "toolCall", name: "", id: "x" },
              ],
            },
          },
          {
            label: "plain object content",
            msg: { role: "assistant", content: {} },
          },
          {
            label: "string content",
            msg: { role: "assistant", content: "hello" },
          },
          {
            label: "null content",
            msg: { role: "assistant", content: null },
          },
          {
            label: "undefined content",
            msg: { role: "assistant" },
          },
          {
            label: "number content",
            msg: { role: "assistant", content: 42 },
          },
        ];

        for (const { label, msg } of scenarios) {
          const result = await fireHook(msg);

          if (result !== undefined) {
            expect(result.message, `scenario: ${label}`).toBeDefined();
            // Content MUST be an array — this is the crash-prevention invariant
            expect(
              Array.isArray(result.message.content),
              `scenario: ${label} — content must be array, got ${typeof result.message.content}`,
            ).toBe(true);

            // Every content block must have a type
            for (const block of result.message.content) {
              expect(
                block.type,
                `scenario: ${label} — block missing type`,
              ).toBeDefined();
            }
          }
        }
      });
  });
});

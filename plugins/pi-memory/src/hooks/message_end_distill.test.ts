// Tests for message_end_distill — the hook that rewrites distillation
// turn responses as muted-gray summaries. The critical safety property:
// content MUST be a content-block array, never a bare string.
//
// Regression: registerDistillSummaryHook returned content: text (bare
// string). Pi's AssistantMessageComponent.updateContent calls .some()
// on it, crashing with "message.content.some is not a function".
// ---------------------------------------------------------------------------

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Mock helpers ──────────────────────────────────────────────────
// We construct a minimal mock of ExtensionAPI so we can test the hook
// handler in isolation — no real pi runtime required.

type HookHandler = (event: any, ctx?: any) => Promise<any>;

interface MockPi {
  _messageEndHandlers: HookHandler[];
  on: ReturnType<typeof vi.fn>;
  registerMessageRenderer: ReturnType<typeof vi.fn>;
}

function createMockPi(): MockPi {
  const handlers: HookHandler[] = [];
  return {
    _messageEndHandlers: handlers,
    on: vi.fn((_event: string, handler: HookHandler) => {
      handlers.push(handler);
    }),
    registerMessageRenderer: vi.fn(),
  };
}

// ── Stub isDistillTurn (module-level mock) ────────────────────────
const distillMod = { isDistillTurn: () => false };

vi.mock("../distill", () => ({
  isDistillTurn: () => distillMod.isDistillTurn(),
}));

// ── Import under test ─────────────────────────────────────────────
import {
  registerDistillSummaryRenderer,
  registerDistillSummaryHook,
} from "./message_end_distill";

// ── Renderer tests ────────────────────────────────────────────────

describe("registerDistillSummaryRenderer", () => {
  it("renders array content (the correct form) — doesn't crash", () => {
    const pi = createMockPi();
    registerDistillSummaryRenderer(pi as any);

    // The renderer was registered with a callback; grab it.
    const renderFn = (
      pi.registerMessageRenderer as any
    ).mock.calls[0][1];

    // Act — pass proper content-block array. Must NOT throw.
    expect(() => {
      renderFn(
        { content: [{ type: "text", text: "📝 logged: 1 action" }] },
        { fg: (_: string, t: string) => t },
      );
    }).not.toThrow();
  });

  it("renders legacy string content (backward compat) — doesn't crash", () => {
    const pi = createMockPi();
    registerDistillSummaryRenderer(pi as any);
    const renderFn = (
      pi.registerMessageRenderer as any
    ).mock.calls[0][1];

    // Old buggy form — bare string. Must NOT throw.
    expect(() => {
      renderFn(
        { content: "✓ nothing to distill" },
        { fg: (_: string, t: string) => t },
      );
    }).not.toThrow();
  });

  it("handles missing content gracefully — doesn't crash", () => {
    const pi = createMockPi();
    registerDistillSummaryRenderer(pi as any);
    const renderFn = (
      pi.registerMessageRenderer as any
    ).mock.calls[0][1];

    expect(() => {
      renderFn({}, { fg: (_: string, t: string) => t });
    }).not.toThrow();
  });

  it("handles null content gracefully — doesn't crash", () => {
    const pi = createMockPi();
    registerDistillSummaryRenderer(pi as any);
    const renderFn = (
      pi.registerMessageRenderer as any
    ).mock.calls[0][1];

    expect(() => {
      renderFn(
        { content: null },
        { fg: (_: string, t: string) => t },
      );
    }).not.toThrow();
  });

  it("concatenates multiple text blocks — doesn't crash", () => {
    const pi = createMockPi();
    registerDistillSummaryRenderer(pi as any);
    const renderFn = (
      pi.registerMessageRenderer as any
    ).mock.calls[0][1];

    expect(() => {
      renderFn(
        {
          content: [
            { type: "text", text: "📝 consolidated: " },
            { type: "text", text: "My Note" },
          ],
        },
        { fg: (_: string, t: string) => t },
      );
    }).not.toThrow();
  });

  it("skips non-text content blocks — doesn't crash", () => {
    const pi = createMockPi();
    registerDistillSummaryRenderer(pi as any);
    const renderFn = (
      pi.registerMessageRenderer as any
    ).mock.calls[0][1];

    expect(() => {
      renderFn(
        {
          content: [
            { type: "thinking", thinking: "internal thought" },
            { type: "text", text: "📝 logged: 1 action" },
          ],
        },
        { fg: (_: string, t: string) => t },
      );
    }).not.toThrow();
  });
});

// ── Hook tests — THE CRITICAL SECTION ─────────────────────────────

describe("registerDistillSummaryHook", () => {
  let pi: MockPi;

  beforeEach(() => {
    pi = createMockPi();
    registerDistillSummaryHook(pi as any);
  });

  afterEach(() => {
    distillMod.isDistillTurn = () => false;
  });

  // Helper: fire the hook with a synthetic event
  async function fireHook(message: any): Promise<any> {
    const handler = pi._messageEndHandlers[0];
    return handler({ message }, {});
  }

  // ── Content shape contract ───────────────────────────────────

  describe("content shape contract", () => {
    it("returns content as an array (not a bare string) — THE REGRESSION", async () => {
      distillMod.isDistillTurn = () => true;

      const result = await fireHook({
        role: "assistant",
        content: [{ type: "text", text: "📝 logged: 1 action" }],
      });

      expect(result).toBeDefined();
      expect(result.message).toBeDefined();
      const c = result.message.content;

      // THE CRITICAL ASSERTION: content must be an array
      expect(Array.isArray(c)).toBe(true);

      // And each element must be a content block with type "text"
      expect(c.length).toBeGreaterThanOrEqual(1);
      for (const block of c) {
        expect(block).toHaveProperty("type", "text");
        expect(typeof block.text).toBe("string");
      }
    });

    it("survives the .some() call that pi makes — literal crash test", async () => {
      distillMod.isDistillTurn = () => true;

      const result = await fireHook({
        role: "assistant",
        content: [{ type: "text", text: "📝 logged: 2 actions + 1 decision" }],
      });

      // This is exactly what AssistantMessageComponent.updateContent does:
      //   message.content.some((c) => ...)
      // If this throws, THE BUG IS BACK.
      expect(() => {
        if (!result) return; // non-distill turn → no rewrite
        const content = result.message.content;
        const hasVisibleContent = content.some(
          (c: any) =>
            (c.type === "text" && c.text.trim()) ||
            (c.type === "thinking" && c.thinking.trim()),
        );
        expect(hasVisibleContent).toBe(true);
      }).not.toThrow();
    });

    it("preserves the summary text verbatim in the content block", async () => {
      distillMod.isDistillTurn = () => true;

      const result = await fireHook({
        role: "assistant",
        content: [{ type: "text", text: "📝 consolidated: Important Finding" }],
      });

      const text = result.message.content[0].text;
      expect(text).toBe("📝 consolidated: Important Finding");
    });

    it("concatenates multiple text blocks before wrapping", async () => {
      distillMod.isDistillTurn = () => true;

      const result = await fireHook({
        role: "assistant",
        content: [
          { type: "text", text: "📝 consolidated: " },
          { type: "text", text: "Arch Decision" },
        ],
      });

      const text = result.message.content[0].text;
      expect(text).toContain("📝 consolidated:");
      expect(text).toContain("Arch Decision");
    });
  });

  // ── Safety: never rewrite when tool calls present ────────────

  describe("tool-call safety", () => {
    it("returns undefined when content has toolCall blocks", async () => {
      distillMod.isDistillTurn = () => true;

      const result = await fireHook({
        role: "assistant",
        content: [
          { type: "text", text: "Let me check that." },
          { type: "toolCall", name: "memory_recall", id: "tc1" },
        ],
      });

      // Must NOT rewrite — tool_use/tool_result pairing must stay intact
      expect(result).toBeUndefined();
    });

    it("returns undefined for toolCall-only content (no text)", async () => {
      distillMod.isDistillTurn = () => true;

      const result = await fireHook({
        role: "assistant",
        content: [
          { type: "toolCall", name: "memory_recall", id: "tc1" },
        ],
      });

      expect(result).toBeUndefined();
    });

    it("returns undefined when content has no text blocks at all", async () => {
      distillMod.isDistillTurn = () => true;

      const result = await fireHook({
        role: "assistant",
        content: [
          { type: "thinking", thinking: "hmm" },
        ],
      });

      expect(result).toBeUndefined();
    });
  });

  // ── Role guard ───────────────────────────────────────────────

  describe("role guard", () => {
    it("ignores non-assistant messages", async () => {
      distillMod.isDistillTurn = () => true;

      const result = await fireHook({
        role: "user",
        content: [{ type: "text", text: "hello" }],
      });

      // User messages are never rewritten
      expect(result).toBeUndefined();
    });

    it("ignores system messages", async () => {
      distillMod.isDistillTurn = () => true;

      const result = await fireHook({
        role: "system",
        content: [{ type: "text", text: "system note" }],
      });

      expect(result).toBeUndefined();
    });
  });

  // ── isDistillTurn guard ──────────────────────────────────────

  describe("distill-turn guard", () => {
    it("skips when isDistillTurn returns false", async () => {
      distillMod.isDistillTurn = () => false;

      const result = await fireHook({
        role: "assistant",
        content: [{ type: "text", text: "✓ nothing to distill" }],
      });

      // Not a distill turn → pass through unchanged
      expect(result).toBeUndefined();
    });
  });

  // ── Edge cases ───────────────────────────────────────────────

  describe("edge cases", () => {
    it("handles empty content array", async () => {
      distillMod.isDistillTurn = () => true;

      const result = await fireHook({
        role: "assistant",
        content: [],
      });

      // No text to extract → leave unchanged
      expect(result).toBeUndefined();
    });

    it("handles content array with only whitespace text", async () => {
      distillMod.isDistillTurn = () => true;

      const result = await fireHook({
        role: "assistant",
        content: [{ type: "text", text: "   " }],
      });

      // Whitespace-only text → treated as no text
      expect(result).toBeUndefined();
    });

    it("handles missing content field (defaults to [])", async () => {
      distillMod.isDistillTurn = () => true;

      const result = await fireHook({
        role: "assistant",
        // no content field
      });

      expect(result).toBeUndefined();
    });

    it("preserves other message fields in the rewritten message", async () => {
      distillMod.isDistillTurn = () => true;

      const result = await fireHook({
        role: "assistant",
        content: [{ type: "text", text: "✓ nothing to distill" }],
        id: "msg-123",
        model: "test-model",
      });

      expect(result.message).toHaveProperty("id", "msg-123");
      expect(result.message).toHaveProperty("model", "test-model");
      expect(result.message).toHaveProperty("customType", "memory-distill-summary");
    });

    it("suppresses ✓ nothing to distill (empty content, invisible in TUI)", async () => {
      distillMod.isDistillTurn = () => true;

      const result = await fireHook({
        role: "assistant",
        content: [{ type: "text", text: "✓ nothing to distill" }],
      });

      expect(result.message.content).toEqual([]);
      expect(result.message.customType).toBe("memory-distill-summary");
    });
  });

  // ── Structural invariants (applied to ALL return paths) ──────

  describe("structural invariants", () => {
    it("every return path produces either undefined or {message: {..., content: array}}", async () => {
      const scenarios: Array<{ label: string; msg: any; isDistill: boolean }> = [
        {
          label: "normal distill turn with text",
          msg: { role: "assistant", content: [{ type: "text", text: "✓ nothing to distill" }] },
          isDistill: true,
        },
        {
          label: "distill turn with tool calls (blocked)",
          msg: {
            role: "assistant",
            content: [
              { type: "text", text: "ok" },
              { type: "toolCall", name: "recall", id: "x" },
            ],
          },
          isDistill: true,
        },
        {
          label: "non-distill turn (skipped)",
          msg: { role: "assistant", content: [{ type: "text", text: "hello" }] },
          isDistill: false,
        },
        {
          label: "user message (skipped)",
          msg: { role: "user", content: [{ type: "text", text: "hello" }] },
          isDistill: true,
        },
        {
          label: "empty content",
          msg: { role: "assistant", content: [] },
          isDistill: true,
        },
        {
          label: "whitespace-only text",
          msg: { role: "assistant", content: [{ type: "text", text: "  \n " }] },
          isDistill: true,
        },
      ];

      for (const { label, msg, isDistill } of scenarios) {
        distillMod.isDistillTurn = () => isDistill;
        const result = await fireHook(msg);

        if (result !== undefined) {
          // Must have message property
          expect(result.message, `scenario: ${label}`).toBeDefined();
          // Content must be an array
          expect(
            Array.isArray(result.message.content),
            `scenario: ${label} — content must be array, got ${typeof result.message.content}`,
          ).toBe(true);
          // Every content block must have type
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

  // ── Crash-prevention: non-array content ──────────────────────
  // The distill hook also calls .some() / .filter() on content.
  // Non-array content MUST NOT crash the hook.

  describe("non-array content (crash prevention)", () => {
    it("does not crash on plain object content `{}`", async () => {
      distillMod.isDistillTurn = () => true;

      // Must NOT throw — content is {} not an array
      await expect(fireHook({ role: "assistant", content: {} })).resolves
        .not.toThrow();
    });

    it("does not crash on bare string content", async () => {
      distillMod.isDistillTurn = () => true;

      // The hook should normalize string content to [{type:"text", text:"..."}]
      // and then process it normally.
      const result = await fireHook({
        role: "assistant",
        content: "📝 consolidated: Finding",
      });

      // The string is normalized to a text block, so it gets rewritten
      expect(result).toBeDefined();
      expect(Array.isArray(result.message.content)).toBe(true);
    });

    it("does not crash on null content", async () => {
      distillMod.isDistillTurn = () => true;

      await expect(fireHook({ role: "assistant", content: null })).resolves
        .not.toThrow();
    });

    it("does not crash on undefined content", async () => {
      distillMod.isDistillTurn = () => true;

      await expect(
        fireHook({ role: "assistant" }),
      ).resolves.not.toThrow();
    });

    it("does not crash on number content", async () => {
      distillMod.isDistillTurn = () => true;

      await expect(
        fireHook({ role: "assistant", content: 42 }),
      ).resolves.not.toThrow();
    });

    it("rewrites string content as a text block", async () => {
      distillMod.isDistillTurn = () => true;

      const result = await fireHook({
        role: "assistant",
        content: "📝 consolidated: Arch Decision",
      });

      expect(result).toBeDefined();
      expect(Array.isArray(result.message.content)).toBe(true);
      expect(result.message.content[0].type).toBe("text");
      expect(result.message.content[0].text).toContain("Arch Decision");
    });

    it("returns undefined for object content (no text to extract)", async () => {
      distillMod.isDistillTurn = () => true;

      const result = await fireHook({ role: "assistant", content: {} });

      // {} → normalized to [] → no text → returns undefined
      expect(result).toBeUndefined();
    });
  });
});

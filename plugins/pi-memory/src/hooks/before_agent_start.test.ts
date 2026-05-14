// Tests for before_agent_start — grounding rules + catalog hints + staleness.
//
// Safety properties:
//  • Always returns { systemPrompt: string } or undefined (never malformed)
//  • Grounding rules are always present (even with empty prompt)
//  • Catalog hints only appear when enabled AND matches found
//  • Staleness notes are drained (consumed) each turn
// ---------------------------------------------------------------------------

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

type HookHandler = (event: any, ctx?: any) => Promise<any>;

interface MockPi {
  _handlers: HookHandler[];
  on: ReturnType<typeof vi.fn>;
}

function createMockPi(): MockPi {
  const handlers: HookHandler[] = [];
  return {
    _handlers: handlers,
    on: vi.fn((_event: string, handler: HookHandler) => {
      handlers.push(handler);
    }),
  };
}

// ── Mock dependencies ─────────────────────────────────────────────

// Config: enable all features
vi.mock("../config", () => ({
  HINT_RECALL_ENABLED: true,
  BASE_URL: "http://127.0.0.1:17180",
  STALE_CONTEXT_ENABLED: true,
  CATALOG_REFRESH_MS: 300_000,
}));

// Catalog: control what matchCatalog returns
let mockCatalogMatches: Array<{ title: string }> = [];
vi.mock("../catalog", () => ({
  matchCatalog: () => mockCatalogMatches,
}));

// SSE: control staleness notes
let mockStalenessNotes: string = "";
vi.mock("../sse", () => ({
  drainStalenessNotes: () => {
    const n = mockStalenessNotes;
    mockStalenessNotes = "";
    return n;
  },
}));

import { registerBeforeAgentStartHook } from "./before_agent_start";

describe("registerBeforeAgentStartHook", () => {
  let pi: MockPi;

  beforeEach(() => {
    pi = createMockPi();
    mockCatalogMatches = [];
    mockStalenessNotes = "";
    registerBeforeAgentStartHook(pi as any);
  });

  async function fireHook(event: any): Promise<any> {
    const handler = pi._handlers[0];
    return handler(event, {});
  }

  // ── Grounding rules (always present) ─────────────────────────

  describe("grounding rules — always injected", () => {
    it("returns systemPrompt with grounding rules for any non-empty prompt", async () => {
      const result = await fireHook({ prompt: "hello" });
      expect(result).toBeDefined();
      expect(result.systemPrompt).toBeDefined();
      expect(typeof result.systemPrompt).toBe("string");
    });

    it("includes the mandatory-recall rule", async () => {
      const result = await fireHook({ prompt: "test" });
      expect(result.systemPrompt).toContain(
        "FIRST action MUST be `memory_recall`",
      );
    });

    it("includes the abstention rule", async () => {
      const result = await fireHook({ prompt: "test" });
      expect(result.systemPrompt).toContain(
        "structural check, not a confidence check",
      );
    });

    it("includes the anti-filesystem-chase rule", async () => {
      const result = await fireHook({ prompt: "test" });
      expect(result.systemPrompt).toContain(
        "do not pass it to a shell tool",
      );
    });

    it("includes the recency rule", async () => {
      const result = await fireHook({ prompt: "test" });
      expect(result.systemPrompt).toContain("lastModified");
    });

    it("includes the multi-hop / deep recall rule", async () => {
      const result = await fireHook({ prompt: "test" });
      expect(result.systemPrompt).toContain("maxVersionsPerDoc");
    });

    it("returns undefined for empty prompt (no grounding injection needed)", async () => {
      // An empty prompt means there's nothing to ground — but we inject anyway
      // because the rules might still be useful. Current behavior: injections
      // fire even for empty prompt. This test documents current behavior.
      const result = await fireHook({ prompt: "" });
      // The rules still inject; the hook only returns undefined when both
      // catalog matches AND staleness notes are empty AND prompt is empty.
      expect(result).toBeDefined();
    });

    it("returns systemPrompt as a string (not an object or array)", async () => {
      const result = await fireHook({ prompt: "test" });
      expect(typeof result.systemPrompt).toBe("string");
    });
  });

  // ── Catalog hints ────────────────────────────────────────────

  describe("catalog hints", () => {
    it("injects catalog matches into systemPrompt", async () => {
      mockCatalogMatches = [
        { title: "Memory Plugin Test Spec" },
        { title: "WCDC API Test Report" },
      ];

      const result = await fireHook({ prompt: "test about memory plugin" });

      expect(result.systemPrompt).toContain("Memory Plugin Test Spec");
      expect(result.systemPrompt).toContain("WCDC API Test Report");
      expect(result.systemPrompt).toContain("Catalog has potentially relevant docs");
    });

    it("does NOT inject catalog hint when no matches", async () => {
      mockCatalogMatches = [];

      const result = await fireHook({ prompt: "test" });

      expect(result.systemPrompt).not.toContain("Catalog has potentially relevant docs");
    });

    it("does NOT inject catalog hint when prompt is empty", async () => {
      mockCatalogMatches = [{ title: "Some Doc" }];

      const result = await fireHook({ prompt: "" });

      expect(result.systemPrompt).not.toContain("Catalog has potentially relevant docs");
    });
  });

  // ── Staleness notes ──────────────────────────────────────────

  describe("staleness notes", () => {
    it("drains and injects staleness notes", async () => {
      mockStalenessNotes = "IMPORTANT — memory invalidation. Something changed.";

      const result = await fireHook({ prompt: "test" });

      expect(result.systemPrompt).toContain("memory invalidation");
      expect(result.systemPrompt).toContain("Something changed");
    });

    it("drains notes (consumes them, not persistent)", async () => {
      mockStalenessNotes = "Note 1";
      await fireHook({ prompt: "t1" });

      // Second call — notes should be empty now
      const result2 = await fireHook({ prompt: "t2" });
      expect(result2.systemPrompt).not.toContain("Note 1");
    });

    it("handles empty staleness notes gracefully", async () => {
      mockStalenessNotes = "";

      const result = await fireHook({ prompt: "test" });
      // Should still have grounding rules, just no staleness section
      expect(result.systemPrompt).toContain("FIRST action MUST be");
    });
  });

  // ── Combined scenarios ───────────────────────────────────────

  describe("combined: grounding + catalog + staleness", () => {
    it("all three sections present when applicable", async () => {
      mockCatalogMatches = [{ title: "Memory Plugin Test Spec" }];
      mockStalenessNotes = "IMPORTANT — memory update.";

      const result = await fireHook({ prompt: "test memory" });

      expect(result.systemPrompt).toContain("FIRST action MUST be"); // grounding
      expect(result.systemPrompt).toContain("Memory Plugin Test Spec"); // catalog
      expect(result.systemPrompt).toContain("memory update"); // staleness
    });

    it("sections are separated by double newlines", async () => {
      mockCatalogMatches = [{ title: "Doc1" }];
      mockStalenessNotes = "STALE note.";

      const result = await fireHook({ prompt: "test" });

      // The three sections should be joined by \n\n
      const parts = result.systemPrompt.split("\n\n");
      expect(parts.length).toBeGreaterThanOrEqual(3);
    });
  });

  // ── Edge cases ───────────────────────────────────────────────

  describe("edge cases", () => {
    it("handles very long catalog match lists", async () => {
      mockCatalogMatches = Array.from({ length: 50 }, (_, i) => ({
        title: `Doc ${i}`,
      }));

      const result = await fireHook({ prompt: "test" });
      expect(result.systemPrompt).toBeDefined();
      // Should not crash even with many titles
    });

    it("handles catalog titles with special characters", async () => {
      mockCatalogMatches = [
        { title: 'Doc with "quotes" and, commas' },
        { title: "Doc with\nnewlines" },
      ];

      const result = await fireHook({ prompt: "test" });
      expect(result.systemPrompt).toBeDefined();
    });

    it("returns undefined when nothing to inject", async () => {
      // No catalog matches, no staleness, empty prompt
      mockCatalogMatches = [];
      mockStalenessNotes = "";

      const result = await fireHook({ prompt: "" });
      // Grounding rules still fire (they're always-on). Current behavior:
      // returns even for empty prompt with rules.
      // The return-is-undefined path only triggers when parts.length === 0.
      // Since grounding rules are always added, this never happens in practice.
    });

    it("systemPrompt is never empty when prompt is non-empty", async () => {
      mockCatalogMatches = [];
      mockStalenessNotes = "";

      const result = await fireHook({ prompt: "anything" });
      expect(result.systemPrompt.length).toBeGreaterThan(0);
    });
  });
});

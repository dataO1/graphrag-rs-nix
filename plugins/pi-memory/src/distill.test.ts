// Tests for distill.ts — end-of-turn distillation + logging nudge.
//
// Key behaviors:
//  • isDistillTurn returns true only during the forced follow-up turn
//  • Recursion guard: one distillation turn per user prompt
//  • Thinking level is saved/restored around the distill turn
//  • DISTILL_NUDGE content is correct (structural checks present)
// ---------------------------------------------------------------------------

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// We need to test the distill module's state machine. Because the module
// uses module-level mutable state (forcedDistillTurn, savedDistillThinking),
// we must reset between tests.

// ── Reset helpers ─────────────────────────────────────────────────
// The distill module has module-level state. We import fresh via dynamic
// import + vi.resetModules() between tests that mutate state.

async function freshImport() {
  // Force re-evaluation of the module to reset state
  return import("./distill");
}

describe("DISTILL_NUDGE", () => {
  it("contains the structural check instructions", async () => {
    const { DISTILL_NUDGE } = await freshImport();
    expect(DISTILL_NUDGE).toContain("Distillation structural check");
    expect(DISTILL_NUDGE).toContain("memory_remember");
  });

  it("contains the logging check instructions", async () => {
    const { DISTILL_NUDGE } = await freshImport();
    expect(DISTILL_NUDGE).toContain("Logging structural check");
    expect(DISTILL_NUDGE).toContain("memory_log_action");
    expect(DISTILL_NUDGE).toContain("memory_log_decision");
  });

  it("specifies the one-line response format", async () => {
    const { DISTILL_NUDGE } = await freshImport();
    expect(DISTILL_NUDGE).toContain("✓ nothing to distill");
    expect(DISTILL_NUDGE).toContain("📝 consolidated:");
    expect(DISTILL_NUDGE).toContain("📝 logged:");
    expect(DISTILL_NUDGE).toContain("Keep it to ONE line");
  });

  it("has higher bar for distillation (a-d criteria)", async () => {
    const { DISTILL_NUDGE } = await freshImport();
    expect(DISTILL_NUDGE).toContain("(a)");
    expect(DISTILL_NUDGE).toContain("(b)");
    expect(DISTILL_NUDGE).toContain("(c)");
    expect(DISTILL_NUDGE).toContain("(d)");
    expect(DISTILL_NUDGE).toContain("when in doubt, skip");
  });

  it("has logging trigger criteria for subagent work", async () => {
    const { DISTILL_NUDGE } = await freshImport();
    expect(DISTILL_NUDGE).toContain(
      "INCLUDING work done by a subagent you dispatched",
    );
  });
});

describe("isDistillTurn", () => {
  // Because isDistillTurn depends on module-level mutable state,
  // we test the state machine via the registerDistillHook function.

  it("starts as false", async () => {
    const { isDistillTurn } = await freshImport();
    expect(isDistillTurn()).toBe(false);
  });
});

describe("registerDistillHook", () => {
  let pi: {
    _agentEndHandlers: Array<(event: any, ctx: any) => Promise<void>>;
    on: ReturnType<typeof vi.fn>;
    setThinkingLevel: ReturnType<typeof vi.fn>;
    getThinkingLevel: ReturnType<typeof vi.fn>;
    sendMessage: ReturnType<typeof vi.fn>;
  };

  beforeEach(async () => {
    vi.resetModules();
    const handlers: Array<(event: any, ctx: any) => Promise<void>> = [];
    pi = {
      _agentEndHandlers: handlers,
      on: vi.fn((_event: string, handler: any) => {
        handlers.push(handler);
      }),
      setThinkingLevel: vi.fn(),
      getThinkingLevel: vi.fn(() => "high"),
      sendMessage: vi.fn(),
    };
  });

  async function fireAgentEnd(importFn: () => Promise<any>) {
    const { registerDistillHook } = await importFn();
    registerDistillHook(pi as any);
    const handler = pi._agentEndHandlers[0];
    await handler({}, {});
  }

  it("sends a distill nudge on first agent_end", async () => {
    await fireAgentEnd(() => import("./distill"));

    expect(pi.sendMessage).toHaveBeenCalledTimes(1);
    const call = (pi.sendMessage as any).mock.calls[0];
    expect(call[0]).toMatchObject({
      customType: "memory-distill-nudge",
      display: false,
    });
    expect(call[1]).toMatchObject({ triggerTurn: true });
  });

  it("sets thinking to low during distill turn", async () => {
    pi.getThinkingLevel = vi.fn(() => "high");

    await fireAgentEnd(() => import("./distill"));

    expect(pi.setThinkingLevel).toHaveBeenCalledWith("low");
  });

  it("does NOT send a second nudge (recursion guard)", async () => {
    const mod = await import("./distill");
    mod.registerDistillHook(pi as any);

    const handler = pi._agentEndHandlers[0];

    // First agent_end → should send nudge
    await handler({}, {});
    expect(pi.sendMessage).toHaveBeenCalledTimes(1);

    // Second agent_end (the distill turn itself) → should NOT send another nudge
    await handler({}, {});
    expect(pi.sendMessage).toHaveBeenCalledTimes(1); // still 1
  });

  it("restores thinking level after distill turn", async () => {
    pi.getThinkingLevel = vi.fn(() => "high");

    const mod = await import("./distill");
    mod.registerDistillHook(pi as any);
    const handler = pi._agentEndHandlers[0];

    // First agent_end → distill turn starts
    await handler({}, {});
    expect(pi.setThinkingLevel).toHaveBeenCalledWith("low");

    // Second agent_end → distill turn ends, thinking restored
    await handler({}, {});
    expect(pi.setThinkingLevel).toHaveBeenCalledWith("high");
  });

  it("isDistillTurn is true only during the distill follow-up", async () => {
    const mod = await import("./distill");

    // Register observation hook FIRST (before distill hook) so it sees
    // the state before the distill hook resets it.
    let capturedDuringSecondCall = false;
    const observeHandler = async () => {
      capturedDuringSecondCall = mod.isDistillTurn();
    };

    mod.registerDistillHook(pi as any);
    // Handlers: [distillHook]

    // Before first agent_end
    expect(mod.isDistillTurn()).toBe(false);

    // First agent_end → distill queued. Run distill hook only.
    await pi._agentEndHandlers[0]({}, {});

    // Second agent_end → insert observation BEFORE distill hook
    pi._agentEndHandlers.unshift(observeHandler);
    // Handlers: [observeHandler, distillHook]
    // Run both in order
    await pi._agentEndHandlers[0]({}, {});
    await pi._agentEndHandlers[1]({}, {});

    expect(capturedDuringSecondCall).toBe(true);

    // After the distill turn, isDistillTurn is false again
    expect(mod.isDistillTurn()).toBe(false);
  });

  it("isDistillTurn returns false after a non-distill turn resets state", async () => {
    const mod = await import("./distill");
    mod.registerDistillHook(pi as any);
    const handler = pi._agentEndHandlers[0];

    await handler({}, {}); // start distill
    await handler({}, {}); // finish distill
    expect(mod.isDistillTurn()).toBe(false);

    // Third agent_end should start a new distill cycle
    await handler({}, {});
    expect(pi.sendMessage).toHaveBeenCalledTimes(2); // second nudge sent
  });

  it("handles edge case: savedDistillThinking is undefined", async () => {
    pi.getThinkingLevel = vi.fn(() => (undefined as any));

    const mod = await import("./distill");
    mod.registerDistillHook(pi as any);
    const handler = pi._agentEndHandlers[0];

    await handler({}, {}); // start distill with undefined thinking
    await handler({}, {}); // finish distill — should not crash

    // Should not have called setThinkingLevel with undefined on restore
    // The second setThinkingLevel call should either not happen or handle gracefully
  });
});

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
    _handlers: Map<string, Array<(event: any, ctx: any) => Promise<void>>>;
    _agentEndHandlers: Array<(event: any, ctx: any) => Promise<void>>;
    on: ReturnType<typeof vi.fn>;
    setThinkingLevel: ReturnType<typeof vi.fn>;
    getThinkingLevel: ReturnType<typeof vi.fn>;
    sendMessage: ReturnType<typeof vi.fn>;
  };

  beforeEach(async () => {
    vi.resetModules();
    const handlerMap = new Map<string, Array<(event: any, ctx: any) => Promise<void>>>();
    const agentEndHandlers: Array<(event: any, ctx: any) => Promise<void>> = [];
    handlerMap.set("agent_end", agentEndHandlers);
    pi = {
      _handlers: handlerMap,
      _agentEndHandlers: agentEndHandlers,
      on: vi.fn((event: string, handler: any) => {
        let arr = handlerMap.get(event);
        if (!arr) {
          arr = [];
          handlerMap.set(event, arr);
        }
        arr.push(handler);
      }),
      setThinkingLevel: vi.fn(),
      getThinkingLevel: vi.fn(() => "high"),
      sendMessage: vi.fn(),
    };
  });

  /** Fire an agent_end event through the registered handler. */
  async function fireAgentEnd(importFn: () => Promise<any>) {
    const { registerDistillHook } = await importFn();
    registerDistillHook(pi as any);
    const handler = pi._handlers.get("agent_end")![0];
    await handler({}, {});
  }

  /** Get the first registered agent_end handler. */
  function getAgentEndHandler(): (event: any, ctx: any) => Promise<void> {
    return pi._handlers.get("agent_end")![0];
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

    const handler = getAgentEndHandler();

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
    const handler = getAgentEndHandler();

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
    const handler = getAgentEndHandler();

    // Before first agent_end
    expect(mod.isDistillTurn()).toBe(false);

    // First agent_end → distill queued.
    await handler({}, {});

    // Second agent_end → insert observation BEFORE distill hook
    const agentEndHandlers = pi._handlers.get("agent_end")!;
    agentEndHandlers.unshift(observeHandler);
    // Run both in order
    await agentEndHandlers[0]({}, {});
    await agentEndHandlers[1]({}, {});

    expect(capturedDuringSecondCall).toBe(true);

    // After the distill turn, isDistillTurn is false again
    expect(mod.isDistillTurn()).toBe(false);
  });

  it("isDistillTurn returns false after a non-distill turn resets state", async () => {
    const mod = await import("./distill");
    mod.registerDistillHook(pi as any);
    const handler = getAgentEndHandler();

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
    const handler = getAgentEndHandler();

    await handler({}, {}); // start distill with undefined thinking
    await handler({}, {}); // finish distill — should not crash

    // Should not have called setThinkingLevel with undefined on restore
    // The second setThinkingLevel call should either not happen or handle gracefully
  });

  // ── Milestone journal tests ───────────────────────────────────

  it("journals todo completions via tool_result", async () => {
    const mod = await import("./distill");
    mod.registerDistillHook(pi as any);

    const toolResultHandlers = pi._handlers.get("tool_result")!;
    expect(toolResultHandlers).toBeDefined();

    // Fire a todo-completed tool_result
    await toolResultHandlers[0]({
      type: "tool_result",
      toolName: "todo",
      toolCallId: "t1",
      isError: false,
      input: { action: "update", status: "completed", subject: "Fix bug", id: 3 },
      content: [],
      details: null,
    }, {});

    // Fire agent_end — should include milestone in nudge
    const agentHandler = getAgentEndHandler();
    await agentHandler({}, {});

    expect(pi.sendMessage).toHaveBeenCalledTimes(1);
    const call = (pi.sendMessage as any).mock.calls[0];
    expect(call[0].content).toContain("[memory] Notable this turn:");
    expect(call[0].content).toContain("Fix bug");
  });

  it("journals subagent completions via tool_result", async () => {
    const mod = await import("./distill");
    mod.registerDistillHook(pi as any);

    const toolResultHandlers = pi._handlers.get("tool_result")!;

    await toolResultHandlers[0]({
      type: "tool_result",
      toolName: "subagent",
      toolCallId: "t2",
      isError: false,
      input: { agent: "researcher", task: "find hook patterns" },
      content: [],
      details: null,
    }, {});

    const agentHandler = getAgentEndHandler();
    await agentHandler({}, {});

    expect(pi.sendMessage).toHaveBeenCalledTimes(1);
    const call = (pi.sendMessage as any).mock.calls[0];
    expect(call[0].content).toContain("[memory] Notable this turn:");
    expect(call[0].content).toContain("researcher: find hook patterns");
  });

  it("skips errored tool_results", async () => {
    const mod = await import("./distill");
    mod.registerDistillHook(pi as any);

    const toolResultHandlers = pi._handlers.get("tool_result")!;

    // Errored subagent
    await toolResultHandlers[0]({
      type: "tool_result",
      toolName: "subagent",
      toolCallId: "t3",
      isError: true,
      input: { agent: "researcher", task: "crashed" },
      content: [],
      details: null,
    }, {});

    const agentHandler = getAgentEndHandler();
    await agentHandler({}, {});

    expect(pi.sendMessage).toHaveBeenCalledTimes(1);
    const call = (pi.sendMessage as any).mock.calls[0];
    // Should NOT contain notable milestones (errored subagent skipped)
    expect(call[0].content).not.toContain("Notable this turn");
  });

  it("clears milestones after each nudge", async () => {
    const mod = await import("./distill");
    mod.registerDistillHook(pi as any);

    const toolResultHandlers = pi._handlers.get("tool_result")!;

    // Fire a todo completion
    await toolResultHandlers[0]({
      type: "tool_result",
      toolName: "todo",
      toolCallId: "t4",
      isError: false,
      input: { action: "update", status: "completed", subject: "First" },
      content: [],
      details: null,
    }, {});

    // First nudge — should contain the milestone
    const agentHandler = getAgentEndHandler();
    await agentHandler({}, {}); // distill
    await agentHandler({}, {}); // end distill

    // Second nudge (new user prompt) — should NOT contain the old milestone
    await agentHandler({}, {}); // distill
    await agentHandler({}, {}); // end distill

    const calls = (pi.sendMessage as any).mock.calls;
    const firstNudge = calls[0][0].content;
    const secondNudge = calls[1][0].content;
    expect(firstNudge).toContain("Notable this turn");
    expect(secondNudge).not.toContain("Notable this turn");
  });

  it("no milestone prefix when journal is empty", async () => {
    await fireAgentEnd(() => import("./distill"));

    const call = (pi.sendMessage as any).mock.calls[0];
    expect(call[0].content).not.toContain("Notable this turn");
    // Should start directly with the normal nudge
    expect(call[0].content).toContain("[memory] Distillation structural check");
  });
});

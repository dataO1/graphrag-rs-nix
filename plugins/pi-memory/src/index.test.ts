// Tests for index.ts — subagent gating.
//
// pi-subagents sets PI_SUBAGENT_CHILD=1 when spawning subagent
// processes. Our plugin must:
//   • Main agent: register all 7 tools + all hooks + distill
//   • Subagent:   register only 3 read tools + crash guard
//                 NO write tools, NO distill, NO logging hooks
// ---------------------------------------------------------------------------

import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Helpers ──────────────────────────────────────────────────────

/** Load index.ts with a fresh module cache and the given PI_SUBAGENT_CHILD value. */
async function loadPlugin(subagentChild: string | undefined) {
  vi.resetModules();

  if (subagentChild !== undefined) {
    vi.stubEnv("PI_SUBAGENT_CHILD", subagentChild);
  } else {
    // vitest stubEnv persists across tests; explicitly clear the stub
    // so the module sees PI_SUBAGENT_CHILD as absent (not "1" leaking from
    // a previous subagent test). vi.stubEnv(key, undefined) is the
    // supported un-set path.
    vi.stubEnv("PI_SUBAGENT_CHILD", undefined);
  }

  const tools: string[] = [];
  const hooks: string[] = [];
  const renderers: string[] = [];
  let commandCount = 0;

  const mockPi: Record<string, any> = {
    registerTool: (def: any) => {
      tools.push(def.name);
    },
    registerCommand: () => {
      commandCount++;
    },
    registerMessageRenderer: () => {
      renderers.push("renderer");
    },
    on: (event: string) => {
      hooks.push(event);
    },
    sendMessage: () => {},
    setThinkingLevel: () => {},
    getThinkingLevel: () => "high",
    setStatus: () => {},
  };

  const mod = await import("./index");
  mod.default(mockPi);

  return { tools, hooks, renderers, commandCount };
}

// ── Main agent (PI_SUBAGENT_CHILD absent or != "1") ─────────────

describe("main agent (PI_SUBAGENT_CHILD unset or not '1')", () => {
  it("registers all 7 tools", async () => {
    const { tools } = await loadPlugin(undefined);
    expect(tools).toHaveLength(7);
    expect(tools).toContain("memory_recall");
    expect(tools).toContain("memory_remember");
    expect(tools).toContain("memory_catalog");
    expect(tools).toContain("memory_forget");
    expect(tools).toContain("memory_status");
    expect(tools).toContain("memory_log_action");
    expect(tools).toContain("memory_log_decision");
  });

  it("registers all expected hooks", async () => {
    const { hooks } = await loadPlugin(undefined);
    // Core hooks
    expect(hooks).toContain("message_end");       // filter + cache + distill
    expect(hooks).toContain("session_start");     // lifecycle
    expect(hooks).toContain("agent_start");       // lifecycle
    expect(hooks).toContain("session_shutdown");  // lifecycle
    expect(hooks).toContain("before_agent_start");// context injection
    expect(hooks).toContain("agent_end");         // distill
    expect(hooks).toContain("tool_result");       // milestone journal
  });

  it("registers commands", async () => {
    const { commandCount } = await loadPlugin(undefined);
    expect(commandCount).toBeGreaterThanOrEqual(2); // /recall + /remember
  });

  it("registers the distill renderer", async () => {
    const { renderers } = await loadPlugin(undefined);
    expect(renderers.length).toBeGreaterThanOrEqual(1);
  });

  it("also works with PI_SUBAGENT_CHILD=0", async () => {
    const { tools } = await loadPlugin("0");
    expect(tools).toHaveLength(7); // main agent when not exactly "1"
  });
});

// ── Subagent (PI_SUBAGENT_CHILD=1) ──────────────────────────────

describe("subagent (PI_SUBAGENT_CHILD=1)", () => {
  it("registers only 3 read tools", async () => {
    const { tools } = await loadPlugin("1");
    expect(tools).toHaveLength(3);
    expect(tools).toContain("memory_recall");
    expect(tools).toContain("memory_catalog");
    expect(tools).toContain("memory_status");
  });

  it("does NOT register write tools", async () => {
    const { tools } = await loadPlugin("1");
    expect(tools).not.toContain("memory_remember");
    expect(tools).not.toContain("memory_forget");
    expect(tools).not.toContain("memory_log_action");
    expect(tools).not.toContain("memory_log_decision");
  });

  it("registers the crash guard (message_end filter)", async () => {
    const { hooks } = await loadPlugin("1");
    expect(hooks).toContain("message_end");
  });

  it("does NOT register distill or logging hooks", async () => {
    const { hooks } = await loadPlugin("1");
    expect(hooks).not.toContain("agent_end");
    expect(hooks).not.toContain("tool_result");
    expect(hooks).not.toContain("before_agent_start");
    expect(hooks).not.toContain("session_start");
    expect(hooks).not.toContain("session_shutdown");
  });

  it("does NOT register commands", async () => {
    const { commandCount } = await loadPlugin("1");
    expect(commandCount).toBe(0);
  });

  it("does NOT register the distill renderer", async () => {
    const { renderers } = await loadPlugin("1");
    expect(renderers).toHaveLength(0);
  });
});

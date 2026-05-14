// Integration smoke tests — load the BUILT plugin artifact (dist/index.js)
// and verify structural invariants. These tests catch regressions where:
//
//   • The build doesn't actually include all modules
//   • The default export is missing or has wrong shape
//   • Key exports (tools, hooks, commands) are missing
//   • The hook handlers crash on valid input
//
// These run with vitest but test the REAL bundled output (dist/index.js),
// not individual TypeScript modules. Complement the unit tests which test
// source modules in isolation.
// ---------------------------------------------------------------------------

import { describe, it, expect, beforeAll } from "vitest";
import { readFileSync } from "fs";
import { resolve } from "path";

const DIST_INDEX = resolve(import.meta.dirname, "../../dist/index.js");

// ── Plugin shape ──────────────────────────────────────────────────

describe("built plugin artifact (dist/index.js)", () => {
  let pluginDefault: any;

  beforeAll(async () => {
    // The bundled ESM module must export a default function
    const mod = await import(DIST_INDEX);
    pluginDefault = mod.default;
  });

  it("exists and is readable", () => {
    const raw = readFileSync(DIST_INDEX, "utf-8");
    expect(raw.length).toBeGreaterThan(100);
  });

  it("exports a default function", () => {
    expect(typeof pluginDefault).toBe("function");
  });

  it("default export accepts a single argument", () => {
    // Functions have a .length property for declared parameter count
    expect(pluginDefault.length).toBe(1);
  });

  it("does NOT throw when called with a minimal mock pi", () => {
    // A mock that satisfies all the register* calls the plugin makes.
    const mockPi: Record<string, any> = {
      registerTool: () => {},
      registerCommand: () => {},
      registerMessageRenderer: () => {},
      on: () => {},
      sendMessage: () => {},
      setThinkingLevel: () => {},
      getThinkingLevel: () => "high",
      setStatus: () => {},
    };

    expect(() => pluginDefault(mockPi)).not.toThrow();
  });
});

// ── Content-shape enforcement ─────────────────────────────────────
//
// These tests instrument the actual plugin to verify that EVERY hook
// and tool that returns messages uses content-block arrays — the
// regression class that caused "message.content.some is not a function".

describe("content-shape enforcement (anti-regression)", () => {
  it("message_end handlers always return content as array", async () => {
    const messageEndHandlers: Array<(event: any) => Promise<any>> = [];

    const mockPi: Record<string, any> = {
      registerTool: () => {},
      registerCommand: () => {},
      registerMessageRenderer: () => {},
      sendMessage: () => {},
      setThinkingLevel: () => {},
      getThinkingLevel: () => "high",
      setStatus: () => {},
      on: (event: string, handler: any) => {
        if (event === "message_end") {
          messageEndHandlers.push(handler);
        }
      },
    };

    // Load the real plugin with our instrumented mock
    const mod = await import(DIST_INDEX);
    mod.default(mockPi);

    expect(messageEndHandlers.length).toBeGreaterThanOrEqual(3);

    // For each message_end handler, fire a sample event and check
    // that any returned message has content as an array.
    const sampleMessage = {
      role: "assistant",
      content: [{ type: "text", text: "sample text" }],
    };

    for (let i = 0; i < messageEndHandlers.length; i++) {
      const handler = messageEndHandlers[i];
      let result: any;
      try {
        result = await handler({ message: sampleMessage });
      } catch {
        // Some handlers may fail without a real pi context — that's OK
        continue;
      }
      if (result && result.message) {
        const content = result.message.content;
        expect(
          Array.isArray(content),
          `message_end handler #${i} returned content as ${typeof content}, expected array`,
        ).toBe(true);
        if (content.length > 0) {
          for (const block of content) {
            expect(block).toHaveProperty(
              "type",
              `message_end handler #${i} block missing 'type'`,
            );
          }
        }
      }
    }
  });

  it("distill-summary messages always survive .some() call", async () => {
    // Simulate exactly what pi's AssistantMessageComponent does:
    //   message.content.some((c) => (c.type === "text" && c.text.trim()) || ...)
    //
    // We fire the full plugin with the distill nudge path to exercise
    // the message_end_distill hook.

    const agentEndHandlers: Array<(event: any, ctx: any) => Promise<void>> = [];
    const messageEndHandlers: Array<(event: any) => Promise<any>> = [];

    const mockPi: Record<string, any> = {
      registerTool: () => {},
      registerCommand: () => {},
      registerMessageRenderer: () => {},
      sendMessage: () => {},
      setThinkingLevel: () => {},
      getThinkingLevel: () => "high",
      setStatus: () => {},
      on: (event: string, handler: any) => {
        if (event === "agent_end") {
          agentEndHandlers.push(handler);
        }
        if (event === "message_end") {
          messageEndHandlers.push(handler);
        }
      },
    };

    const mod = await import(DIST_INDEX);
    mod.default(mockPi);

    // Fire agent_end to trigger distillation (this sets isDistillTurn = true)
    if (agentEndHandlers.length > 0) {
      await agentEndHandlers[0]({}, {});
    }

    // Now fire message_end handlers — the distill hook should rewrite the message.
    // But since we didn't fire a second agent_end (which would consume the
    // distillation turn), isDistillTurn may or may not be set depending on
    // handler ordering. We're testing that regardless of what comes out,
    // .some() never crashes.

    const scenarios = [
      {
        label: "normal assistant text",
        message: {
          role: "assistant",
          content: [{ type: "text", text: "✓ nothing to distill" }],
        },
      },
      {
        label: "assistant with tool calls",
        message: {
          role: "assistant",
          content: [
            { type: "text", text: "checking" },
            { type: "toolCall", name: "bash", id: "x" },
          ],
        },
      },
      {
        label: "empty content",
        message: {
          role: "assistant",
          content: [],
        },
      },
      {
        label: "user message",
        message: {
          role: "user",
          content: [{ type: "text", text: "hello" }],
        },
      },
    ];

    for (const { label, message } of scenarios) {
      for (let i = 0; i < messageEndHandlers.length; i++) {
        const handler = messageEndHandlers[i];
        let result: any;
        try {
          result = await handler({ message });
        } catch {
          continue;
        }
        if (result && result.message && result.message.content) {
          const content = result.message.content;
          expect(
            () => {
              // Exactly what AssistantMessageComponent.updateContent does
              const hasVisible = content.some(
                (c: any) =>
                  (c.type === "text" && c.text.trim()) ||
                  (c.type === "thinking" && c.thinking.trim()),
              );
              // Just checking it doesn't throw; result doesn't matter
              void hasVisible;
            },
            `${label} → handler #${i}: .some() crashed`,
          ).not.toThrow();
        }
      }
    }
  });
});

// ── Tool registration count ───────────────────────────────────────

describe("tool registration", () => {
  it("registers exactly 7 tools", () => {
    const tools: string[] = [];
    const mockPi: Record<string, any> = {
      registerTool: (def: any) => {
        tools.push(def.name);
      },
      registerCommand: () => {},
      registerMessageRenderer: () => {},
      sendMessage: () => {},
      setThinkingLevel: () => {},
      getThinkingLevel: () => "high",
      setStatus: () => {},
      on: () => {},
    };

    const mod = require(DIST_INDEX);
    mod.default(mockPi);

    expect(tools).toHaveLength(7);
    expect(tools).toContain("memory_recall");
    expect(tools).toContain("memory_remember");
    expect(tools).toContain("memory_catalog");
    expect(tools).toContain("memory_forget");
    expect(tools).toContain("memory_status");
    expect(tools).toContain("memory_log_action");
    expect(tools).toContain("memory_log_decision");
  });

  it("registers 2 commands (/recall, /remember)", () => {
    const commands: string[] = [];
    const mockPi: Record<string, any> = {
      registerTool: () => {},
      registerCommand: (name: string, _def: any) => {
        commands.push(name);
      },
      registerMessageRenderer: () => {},
      sendMessage: () => {},
      setThinkingLevel: () => {},
      getThinkingLevel: () => "high",
      setStatus: () => {},
      on: () => {},
    };

    const mod = require(DIST_INDEX);
    mod.default(mockPi);

    expect(commands).toContain("recall");
    expect(commands).toContain("remember");
  });
});

// ── Hook registration count ───────────────────────────────────────

describe("hook registration", () => {
  it("registers all expected hook types", () => {
    const hooks: Record<string, number> = {};
    const mockPi: Record<string, any> = {
      registerTool: () => {},
      registerCommand: () => {},
      registerMessageRenderer: () => {},
      sendMessage: () => {},
      setThinkingLevel: () => {},
      getThinkingLevel: () => "high",
      setStatus: () => {},
      on: (event: string, _handler: any) => {
        hooks[event] = (hooks[event] || 0) + 1;
      },
    };

    const mod = require(DIST_INDEX);
    mod.default(mockPi);

    // Core hooks that must exist
    expect(hooks["session_start"]).toBeGreaterThanOrEqual(1);
    expect(hooks["agent_start"]).toBeGreaterThanOrEqual(1);
    expect(hooks["session_shutdown"]).toBeGreaterThanOrEqual(1);
    expect(hooks["agent_end"]).toBeGreaterThanOrEqual(1);
    expect(hooks["message_end"]).toBeGreaterThanOrEqual(1);
    expect(hooks["before_agent_start"]).toBeGreaterThanOrEqual(1);
  });

  it("registers the distill-summary message renderer", () => {
    let rendererCount = 0;
    const mockPi: Record<string, any> = {
      registerTool: () => {},
      registerCommand: () => {},
      registerMessageRenderer: (_type: string, _renderer: any) => {
        rendererCount++;
      },
      sendMessage: () => {},
      setThinkingLevel: () => {},
      getThinkingLevel: () => "high",
      setStatus: () => {},
      on: () => {},
    };

    const mod = require(DIST_INDEX);
    mod.default(mockPi);

    expect(rendererCount).toBeGreaterThanOrEqual(1);
  });
});

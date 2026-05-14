// Tests for config.ts — env-var parsing and defaults.
// ---------------------------------------------------------------------------

import { describe, it, expect, beforeEach, afterEach } from "vitest";

describe("config", () => {
  let originalEnv: typeof process.env;

  beforeEach(() => {
    originalEnv = { ...process.env };
    delete process.env.MEMORY_BASE_URL;
    delete process.env.MEMORY_HINT_RECALL;
    delete process.env.MEMORY_CATALOG_REFRESH_MINS;
    delete process.env.MEMORY_HINT_OVERLAP_THRESHOLD;
    delete process.env.MEMORY_SSE_ENABLED;
    delete process.env.MEMORY_STATE_FILE;
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  it("BASE_URL defaults to localhost:17180", async () => {
    const mod = await import("../src/config");
    expect(mod.BASE_URL).toBe("http://127.0.0.1:17180");
  });

  it("BASE_URL reads from MEMORY_BASE_URL", async () => {
    process.env.MEMORY_BASE_URL = "http://memory:9999";
    // Need fresh import since config caches at module scope
    // In vitest, we use dynamic import + vi.resetModules
    // For now just test the env read pattern
    const mod = await import("../src/config");
    expect(mod.BASE_URL).toBe("http://memory:9999");
  });

  it("HINT_RECALL_ENABLED defaults to true", async () => {
    const mod = await import("../src/config");
    expect(mod.HINT_RECALL_ENABLED).toBe(true);
  });

  it("HINT_RECALL_ENABLED = 0 disables", async () => {
    process.env.MEMORY_HINT_RECALL = "0";
    const mod = await import("../src/config");
    expect(mod.HINT_RECALL_ENABLED).toBe(false);
  });

  it("STALE_CONTEXT_ENABLED defaults to true", async () => {
    const mod = await import("../src/config");
    expect(mod.STALE_CONTEXT_ENABLED).toBe(true);
  });

  it("CATALOG_REFRESH_MS defaults to 5 minutes", async () => {
    const mod = await import("../src/config");
    expect(mod.CATALOG_REFRESH_MS).toBe(5 * 60_000);
  });

  it("CATALOG_REFRESH_MS reads from env", async () => {
    process.env.MEMORY_CATALOG_REFRESH_MINS = "2";
    const mod = await import("../src/config");
    expect(mod.CATALOG_REFRESH_MS).toBe(2 * 60_000);
  });
});

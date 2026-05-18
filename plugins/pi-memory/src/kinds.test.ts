// Tests for kinds.ts — boot-time /recall/kinds fetch + description templating.
//
// Safety properties:
//  • On success: getTypeSection() returns a non-empty string containing
//    each kind's name and explanation
//  • On failure: getTypeSection() returns "" (graceful degradation)
//  • Kinds are sorted alphabetically in the TYPE section
//  • Internal newlines in explanation are replaced with spaces
//  • Empty kinds map: getTypeSection() returns "" (no TYPE section)
// ---------------------------------------------------------------------------

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Mock fetch ────────────────────────────────────────────────────

let mockFetch: ReturnType<typeof vi.fn>;

beforeEach(() => {
  vi.resetModules();
  mockFetch = vi.fn();
  vi.stubGlobal("fetch", mockFetch);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

// ── Helpers ───────────────────────────────────────────────────────

function makeOkResponse(data: object): Response {
  return {
    ok: true,
    json: async () => data,
    text: async () => JSON.stringify(data),
  } as unknown as Response;
}

function makeErrorResponse(status: number, body: string): Response {
  return {
    ok: false,
    status,
    text: async () => body,
  } as unknown as Response;
}

const SAMPLE_KINDS = {
  log: {
    pathPrefix: "/home/data01/Notes/📔 Journal/agent-log",
    recency: { enable: true, halfLifeDays: 30 },
    defaultMode: "search" as const,
    explanation: "Agent action logs from the pi coding agent sessions.",
  },
  research: {
    pathPrefix: "/home/data01/Notes/🗂️ Collection",
    recency: { enable: false, halfLifeDays: 365 },
    defaultMode: "hipporag" as const,
    explanation: "Research notes and knowledge collection.",
  },
};

// ── Tests ─────────────────────────────────────────────────────────

describe("fetchRecallKinds — success paths", () => {
  it("populates getTypeSection() with a non-empty string on success", async () => {
    mockFetch.mockResolvedValueOnce(
      makeOkResponse({
        kinds: SAMPLE_KINDS,
        kindsConfigHash: "abc123",
        backfill: { state: "idle" },
      }),
    );

    const mod = await import("./kinds");
    await mod.fetchRecallKinds();

    const section = mod.getTypeSection();
    expect(section.length).toBeGreaterThan(0);
  });

  it("TYPE section contains each kind's explanation as substring", async () => {
    mockFetch.mockResolvedValueOnce(
      makeOkResponse({
        kinds: SAMPLE_KINDS,
        kindsConfigHash: "abc123",
        backfill: { state: "idle" },
      }),
    );

    const mod = await import("./kinds");
    await mod.fetchRecallKinds();

    const section = mod.getTypeSection();
    expect(section).toContain(
      "Agent action logs from the pi coding agent sessions.",
    );
    expect(section).toContain("Research notes and knowledge collection.");
  });

  it("TYPE section contains each kind's name", async () => {
    mockFetch.mockResolvedValueOnce(
      makeOkResponse({
        kinds: SAMPLE_KINDS,
        kindsConfigHash: "abc123",
        backfill: { state: "idle" },
      }),
    );

    const mod = await import("./kinds");
    await mod.fetchRecallKinds();

    const section = mod.getTypeSection();
    expect(section).toContain("log");
    expect(section).toContain("research");
  });

  it("kinds are sorted alphabetically in the TYPE section", async () => {
    // Provide in reverse alphabetical order — output should be sorted.
    mockFetch.mockResolvedValueOnce(
      makeOkResponse({
        kinds: {
          zebra: {
            pathPrefix: "/z",
            recency: { enable: false, halfLifeDays: 365 },
            defaultMode: "search" as const,
            explanation: "Zebra docs.",
          },
          alpha: {
            pathPrefix: "/a",
            recency: { enable: false, halfLifeDays: 365 },
            defaultMode: "search" as const,
            explanation: "Alpha docs.",
          },
        },
        kindsConfigHash: "xyz",
        backfill: { state: "idle" },
      }),
    );

    const mod = await import("./kinds");
    await mod.fetchRecallKinds();

    const section = mod.getTypeSection();
    const alphaIdx = section.indexOf("alpha");
    const zebraIdx = section.indexOf("zebra");
    expect(alphaIdx).toBeGreaterThan(-1);
    expect(zebraIdx).toBeGreaterThan(-1);
    expect(alphaIdx).toBeLessThan(zebraIdx);
  });

  it("replaces internal newlines in explanations with spaces", async () => {
    mockFetch.mockResolvedValueOnce(
      makeOkResponse({
        kinds: {
          log: {
            pathPrefix: "/logs",
            recency: { enable: true, halfLifeDays: 30 },
            defaultMode: "search" as const,
            explanation: "Line one.\nLine two.\nLine three.",
          },
        },
        kindsConfigHash: "abc",
        backfill: { state: "idle" },
      }),
    );

    const mod = await import("./kinds");
    await mod.fetchRecallKinds();

    const section = mod.getTypeSection();
    // The multi-line explanation should be collapsed to one line.
    expect(section).toContain("Line one. Line two. Line three.");
    // No raw newline inside the explanation bullet.
    const bulletStart = section.indexOf("• log");
    const nextBullet = section.indexOf("•", bulletStart + 1);
    const bulletLine =
      nextBullet >= 0
        ? section.slice(bulletStart, nextBullet)
        : section.slice(bulletStart);
    // The bullet itself should not contain a bare newline mid-explanation.
    expect(bulletLine).not.toMatch(/\n.*\n/);
  });

  it("getKinds() returns the fetched kinds map", async () => {
    mockFetch.mockResolvedValueOnce(
      makeOkResponse({
        kinds: SAMPLE_KINDS,
        kindsConfigHash: "abc123",
        backfill: { state: "idle" },
      }),
    );

    const mod = await import("./kinds");
    await mod.fetchRecallKinds();

    const kinds = mod.getKinds();
    expect(kinds).not.toBeNull();
    expect(kinds).toHaveProperty("log");
    expect(kinds).toHaveProperty("research");
  });

  it("empty kinds map → getTypeSection() returns empty string", async () => {
    mockFetch.mockResolvedValueOnce(
      makeOkResponse({
        kinds: {},
        kindsConfigHash: "empty",
        backfill: { state: "idle" },
      }),
    );

    const mod = await import("./kinds");
    await mod.fetchRecallKinds();

    expect(mod.getTypeSection()).toBe("");
  });

  it("TYPE section contains the TYPE header", async () => {
    mockFetch.mockResolvedValueOnce(
      makeOkResponse({
        kinds: SAMPLE_KINDS,
        kindsConfigHash: "abc123",
        backfill: { state: "idle" },
      }),
    );

    const mod = await import("./kinds");
    await mod.fetchRecallKinds();

    const section = mod.getTypeSection();
    expect(section).toContain("TYPE (optional, kind filter)");
    expect(section).toContain("PARALLELISE");
    expect(section).toContain("Kinds:");
  });
});

describe("fetchRecallKinds — failure / graceful degradation", () => {
  it("getTypeSection() returns empty string on network failure", async () => {
    // Fail all attempts quickly.
    mockFetch.mockRejectedValue(new Error("ECONNREFUSED"));

    const mod = await import("./kinds");
    await mod.fetchRecallKinds();

    expect(mod.getTypeSection()).toBe("");
    expect(mod.getKinds()).toBeNull();
  });

  it("getTypeSection() returns empty string on HTTP error", async () => {
    mockFetch.mockResolvedValue(makeErrorResponse(503, "Service Unavailable"));

    const mod = await import("./kinds");
    await mod.fetchRecallKinds();

    expect(mod.getTypeSection()).toBe("");
  });

  it("does not throw on failure — graceful degradation", async () => {
    mockFetch.mockRejectedValue(new Error("timeout"));

    const mod = await import("./kinds");
    await expect(mod.fetchRecallKinds()).resolves.toBeUndefined();
  });
});

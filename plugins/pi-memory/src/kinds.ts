// kinds.ts — boot-time fetch of /recall/kinds with retry/backoff.
//
// Fetches the active document-kind taxonomy from the memory server
// at startup. On success, builds the TYPE section for the recall tool
// description. On failure (after retries), the recall tool is
// registered without the `type` parameter section — graceful degradation.
// ---------------------------------------------------------------------------

import { BASE_URL } from "./config";

// ── Types ─────────────────────────────────────────────────────────

export interface KindInfo {
  pathPrefix: string;
  recency: { enable: boolean; halfLifeDays: number };
  defaultMode: "search" | "hipporag";
  explanation: string;
}

export interface RecallKindsResponse {
  kinds: Record<string, KindInfo>;
  kindsConfigHash: string;
  backfill: unknown; // pass-through only
}

// ── Module state ──────────────────────────────────────────────────

/** Active kinds fetched at boot. Null until a successful fetch. */
let _kinds: Record<string, KindInfo> | null = null;

/** TYPE section appended to the recall tool description. Empty string
 *  when no kinds are configured or the fetch failed. */
let _typeSection: string = "";

// ── Retry/backoff parameters ──────────────────────────────────────

const MAX_ATTEMPTS = 5;
const INITIAL_DELAY_MS = 200;
const MAX_TOTAL_MS = 30_000;

// ── Helpers ───────────────────────────────────────────────────────

/** Build the TYPE section from a kinds map. */
function buildTypeSection(kinds: Record<string, KindInfo>): string {
  const names = Object.keys(kinds).sort();
  if (names.length === 0) return "";

  const bullets = names
    .map((name) => {
      // Replace internal newlines in explanation with spaces so the
      // bullet is one logical line, as per the card spec.
      const explanation = kinds[name].explanation.replace(/\n/g, " ");
      return `  • ${name} — ${explanation}`;
    })
    .join("\n");

  return (
    "\n\n" +
    "TYPE (optional, kind filter): when set, restricts recall to documents\n" +
    "of that kind. Each kind has its own defaults for retrieval depth and\n" +
    "recency. Omit to query all documents.\n\n" +
    "PARALLELISE: for temporal queries (\"what's recent in X\", \"when did\n" +
    "we Y\", \"development of Z\"), batch a type-filtered call alongside the\n" +
    "default untyped call.\n\n" +
    "Kinds:\n" +
    bullets
  );
}

/** Sleep for `ms` milliseconds. */
function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ── Public API ────────────────────────────────────────────────────

/** Fetch /recall/kinds at boot with exponential backoff.
 *
 *  Retries up to MAX_ATTEMPTS times with exponential backoff, total
 *  wall time ≤ MAX_TOTAL_MS. On success, populates the module-level
 *  kinds cache and builds the TYPE description section. On failure,
 *  logs a warning and leaves the cache empty (graceful degradation).
 */
export async function fetchRecallKinds(): Promise<void> {
  const url = `${BASE_URL}/recall/kinds`;
  let lastError: unknown;
  const start = Date.now();

  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    if (attempt > 0) {
      // Exponential backoff: 200ms, 400ms, 800ms, 1600ms, …
      const delay = Math.min(
        INITIAL_DELAY_MS * Math.pow(2, attempt - 1),
        MAX_TOTAL_MS - (Date.now() - start),
      );
      if (delay <= 0) break; // Total budget exhausted.
      await sleep(delay);
    }

    if (Date.now() - start >= MAX_TOTAL_MS) break;

    try {
      const res = await fetch(url, {
        method: "GET",
        headers: { "Content-Type": "application/json" },
      });
      if (!res.ok) {
        const text = await res.text();
        lastError = new Error(
          `GET /recall/kinds failed (${res.status}): ${text}`,
        );
        continue;
      }
      const data: RecallKindsResponse = await res.json();
      _kinds = data.kinds ?? {};
      _typeSection = buildTypeSection(_kinds);
      return; // Success.
    } catch (e) {
      lastError = e;
    }
  }

  // All attempts failed.
  console.warn(
    `[memory] /recall/kinds fetch failed after ${MAX_ATTEMPTS} attempts — ` +
      `recall tool will be registered without the type parameter. ` +
      `Last error: ${(lastError as any)?.message ?? lastError}`,
  );
}

/** Return the TYPE section to append to the recall tool description.
 *  Empty string if no kinds are configured or the fetch failed. */
export function getTypeSection(): string {
  return _typeSection;
}

/** Return the active kinds map, or null if not yet fetched / failed. */
export function getKinds(): Record<string, KindInfo> | null {
  return _kinds;
}

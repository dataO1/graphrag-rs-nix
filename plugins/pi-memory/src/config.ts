// Shared env-driven configuration. All knobs that affect runtime
// behaviour without rebuilding the extension live here.
// ---------------------------------------------------------------------------

import { homedir } from "os";

// Talks to the long-term memory REST backend that the home-manager
// module spins up on port 17180.
export const BASE_URL =
  process.env.MEMORY_BASE_URL || "http://127.0.0.1:17180";

// ── Hint-injection knobs ──────────────────────────────────────────
export const HINT_RECALL_ENABLED =
  (process.env.MEMORY_HINT_RECALL ?? "1") !== "0";
export const CATALOG_REFRESH_MS =
  (Number(process.env.MEMORY_CATALOG_REFRESH_MINS) || 5) * 60_000;
export const HINT_OVERLAP_THRESHOLD =
  Number(process.env.MEMORY_HINT_OVERLAP_THRESHOLD) || 1;
export const HINT_MAX_TITLES = 5;

// ── Stale-context (SSE) ───────────────────────────────────────────
export const STALE_CONTEXT_ENABLED =
  (process.env.MEMORY_SSE_ENABLED ?? "1") !== "0";
export const STATE_FILE =
  process.env.MEMORY_STATE_FILE ||
  `${homedir()}/.pi/agent/extensions/memory-state.json`;

// ── Polling / animation timings ───────────────────────────────────
export const HEALTH_POLL_MS = 30_000;
export const PING_TIMEOUT_MS = 1_500;
export const PULSE_FRAME_MS = 200;
export const BLINK_FRAME_MS = 150;

// ── Pulse / blink frames ──────────────────────────────────────────
export const PULSE_FRAMES = [
  "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█",
  "▇", "▆", "▅", "▄", "▃", "▂",
];
export const BLINK_FRAMES = ["■", "□"];

// ── Working indicator overrides ───────────────────────────────────
export const RECALL_INDICATOR = {
  frames: ["◈", "◇", "◆", "◇"],
  intervalMs: 200,
};
export const REMEMBER_INDICATOR = {
  frames: ["●", "○"],
  intervalMs: 150,
};

// Toolbar widget — pulses on recall, blinks on remember.
//
// `recall` and `remember` get their normal tool-call windows
// suppressed (the recall answer feeds the LLM's response; the
// remember confirmation is just operational noise). The badge
// is the only user-visible artefact for those two tools, so it
// has to convey state cleanly:
//
//    state           badge       cadence
//    ───────────────────────────────────────────────────
//    disconnected    (empty)     —
//    idle            (empty)     —
//    recalling       mem ▁▂▃▄▅▆▇█  200 ms/frame  (slow pulse)
//    remembering     mem ■ / □     150 ms/frame  (fast blink)
//
// When more than one in-flight call overlaps (rare, but the
// agent CAN fire concurrent tools), we count refs per state and
// step down the animation only when the count hits zero.
// ---------------------------------------------------------------------------

import { Text } from "@mariozechner/pi-tui";

import type { PiUi, Theme } from "./types";
import {
  PULSE_FRAMES,
  BLINK_FRAMES,
  PULSE_FRAME_MS,
  BLINK_FRAME_MS,
  RECALL_INDICATOR,
  REMEMBER_INDICATOR,
  HEALTH_POLL_MS,
  PING_TIMEOUT_MS,
  BASE_URL,
} from "./config";
import { pendingStalenessNotes } from "./sse";

// ── Shared mutable state ──────────────────────────────────────────
// Wrapped in a mutable object so ES module consumers can mutate
// via accessors (imported `let` bindings can't be reassigned).
const state = {
  ui: undefined as PiUi | undefined,
  serverReachable: false,
  recallActive: 0,
  rememberActive: 0,
};

// Accessors (read + write)
export const ui = (): PiUi | undefined => state.ui;
export const setUi = (v: PiUi) => { state.ui = v; };
export const isServerReachable = (): boolean => state.serverReachable;
export const getRecallActive = (): number => state.recallActive;
export const getRememberActive = (): number => state.rememberActive;
export const incRecall = () => { state.recallActive++; };
export const decRecall = () => { state.recallActive = Math.max(0, state.recallActive - 1); };
export const incRemember = () => { state.rememberActive++; };
export const decRemember = () => { state.rememberActive = Math.max(0, state.rememberActive - 1); };

let frameIdx = 0;
let animTimer: ReturnType<typeof setInterval> | undefined;
let pollTimer: ReturnType<typeof setInterval> | undefined;

// ── Badge primitives ──────────────────────────────────────────────

function setBadge(text: string) {
  if (!state.ui) return;
  state.ui.setStatus("mem", text);
}

function stopAnim() {
  if (animTimer) {
    clearInterval(animTimer);
    animTimer = undefined;
  }
}

function startAnim(frames: string[], intervalMs: number) {
  stopAnim();
  frameIdx = 0;
  setBadge(`mem ${frames[0]}`);
  animTimer = setInterval(() => {
    frameIdx = (frameIdx + 1) % frames.length;
    setBadge(`mem ${frames[frameIdx]}`);
  }, intervalMs);
}

export function refreshBadge() {
  const stalenessTrail =
    pendingStalenessNotes.length > 0 ? " !" : "";
  if (state.rememberActive > 0) {
    startAnim(BLINK_FRAMES, BLINK_FRAME_MS);
    state.ui?.setWorkingIndicator(REMEMBER_INDICATOR);
  } else if (state.recallActive > 0) {
    startAnim(PULSE_FRAMES, PULSE_FRAME_MS);
    state.ui?.setWorkingIndicator(RECALL_INDICATOR);
  } else {
    stopAnim();
    state.ui?.setWorkingIndicator(undefined as any);
    const dot = state.serverReachable ? "●" : "○";
    setBadge(`mem ${dot}${stalenessTrail}`);
  }
}

// ── Health polling ────────────────────────────────────────────────

export async function healthPing(): Promise<void> {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), PING_TIMEOUT_MS);
    const res = await fetch(`${BASE_URL}/health`, {
      signal: ctrl.signal,
    });
    clearTimeout(t);
    state.serverReachable = res.ok;
  } catch {
    state.serverReachable = false;
  }
  if (state.recallActive === 0 && state.rememberActive === 0) refreshBadge();
}

export function startPollTimer(): void {
  if (pollTimer) return;
  pollTimer = setInterval(() => {
    healthPing().catch(() => {});
  }, HEALTH_POLL_MS);
}

export function stopPollTimer(): void {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = undefined;
  }
}

export function stopAllAnim(): void {
  stopAnim();
}

// ── Text helpers for call renderers ───────────────────────────────

export function truncateForTag(s: string, max = 60): string {
  if (!s) return "";
  const oneline = s.replace(/\s+/g, " ").trim();
  return oneline.length > max
    ? oneline.slice(0, max - 1) + "…"
    : oneline;
}

export function filterSuffix(args?: any): string {
  if (!args) return "";
  const bits: string[] = [];
  const asOf = args.asOf ?? args.as_of;
  const maxV = args.maxVersionsPerDoc ?? args.max_versions_per_doc;
  if (asOf) bits.push(`as of ${truncateForTag(String(asOf), 20)}`);
  if (maxV && Number(maxV) > 1)
    bits.push(`last ${maxV} versions`);
  return bits.length ? ` [${bits.join(", ")}]` : "";
}

// ── Call tag renderers ────────────────────────────────────────────

export function recallCallTag(theme: Theme, args?: any): Text {
  const q = truncateForTag(args?.question ?? "");
  const body = q ? ` ${q}` : "";
  const suffix = filterSuffix(args);
  const suffixStyled = suffix ? theme.fg("muted", suffix) : "";
  return new Text(
    `${theme.fg("toolTitle", theme.bold("▌ recall"))}${body}${suffixStyled}`,
  );
}

export function recallCallTagError(theme: Theme, args?: any): Text {
  const q = truncateForTag(args?.question ?? "");
  const body = q ? ` ${q}` : "";
  const suffix = filterSuffix(args);
  const suffixStyled = suffix ? theme.fg("muted", suffix) : "";
  return new Text(
    `${theme.fg("error", theme.bold("▌ recall ✗"))}${body}${suffixStyled}`,
  );
}

export function recallOutcomeLine(theme: Theme, result: any): Text {
  const muted = (s: string) => theme.fg("muted", s);
  if (result?.isError) {
    const txt: string = result?.content?.[0]?.text ?? "error";
    return new Text(muted(`  ↳ ${txt.slice(0, 80)}`));
  }
  try {
    const txt: string = result?.content?.[0]?.text ?? "";
    const hits = (txt.match(/Top (\d+) hits:/) ?? [])[1] ?? "?";
    const conf = (txt.match(/Confidence: ([\d.]+)/) ?? [])[1];
    const ms = (txt.match(/(\d+)ms\s*$/) ?? [])[1];
    const top = (txt.match(/^\s*-\s*"([^"]{1,60})/m) ?? [])[1];
    const provenanceMatch = txt.match(
      /←\s*([^\s\[]+)(:(\d+)(?:-(\d+))?)?/m,
    );
    const parts = [`${hits} hits`];
    if (conf) parts.push(`conf ${conf}`);
    if (ms) parts.push(`${ms}ms`);
    if (top) parts.push(`top: ${top}`);
    if (provenanceMatch) {
      const src = provenanceMatch[1];
      const lineRange = provenanceMatch[2] ?? "";
      const shortSrc = src.startsWith("obsidian://vault/")
        ? decodeURIComponent(
            src.replace(/^obsidian:\/\/vault\/[^/]+\//, ""),
          )
        : src.startsWith("file://")
          ? src.slice(7)
          : src;
      parts.push(`from: ${shortSrc}${lineRange}`);
    }
    return new Text(muted(`  ↳ ${parts.join(" • ")}`));
  } catch {
    return new Text(muted("  ↳ recalled"));
  }
}

// ── Last assistant text cache (for /remember command) ─────────────

let lastAssistantText: string | undefined;

export function getLastAssistantText(): string | undefined {
  return lastAssistantText;
}

export function setLastAssistantText(text: string): void {
  lastAssistantText = text;
}

export function extractAssistantText(message: any): string {
  if (typeof message?.content === "string") return message.content;
  if (Array.isArray(message?.content)) {
    return message.content
      .filter(
        (b: any) =>
          b?.type === "text" && typeof b.text === "string",
      )
      .map((b: any) => b.text)
      .join("\n");
  }
  return "";
}

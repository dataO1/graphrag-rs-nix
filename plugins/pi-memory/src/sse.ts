// Stale-context: per-session lease + SSE client.
//
// On extension load: read or generate a stable session_id, persisted
// to ~/.pi/agent/extensions/memory-state.json. Recall calls send
// this session_id; the server adds (block_id, etag) per hit to the
// session's lease table. An SSE stream filtered by that lease set
// pushes events whenever a leased block is updated/removed/added,
// each carrying the unified-diff and old/new excerpts so the agent
// can reason about the change without re-querying.
// ---------------------------------------------------------------------------

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { dirname } from "path";

import { memoryRequest } from "./memory-client";
import { refreshBadge } from "./ui";
import type { MemoryState, StaleEvent } from "./types";
import { BASE_URL, STALE_CONTEXT_ENABLED, STATE_FILE } from "./config";

// ── Module state ──────────────────────────────────────────────────
let memoryState: MemoryState | undefined;
let sseAbortController: AbortController | undefined;

/** Queue of staleness notes to fold into the next turn's systemPrompt. */
export const pendingStalenessNotes: string[] = [];

// ── Persistence ───────────────────────────────────────────────────
export function loadMemoryState(): MemoryState {
  if (memoryState) return memoryState;
  try {
    if (existsSync(STATE_FILE)) {
      const raw = JSON.parse(readFileSync(STATE_FILE, "utf8"));
      if (
        typeof raw?.sessionId === "string" &&
        typeof raw?.lastEventId === "number"
      ) {
        memoryState = raw as MemoryState;
        return memoryState;
      }
    }
  } catch {
    // fall through to fresh state
  }
  const fresh: MemoryState = {
    sessionId:
      typeof crypto !== "undefined" && (crypto as any).randomUUID
        ? (crypto as any).randomUUID()
        : `pi-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`,
    lastEventId: 0,
  };
  saveMemoryState(fresh);
  memoryState = fresh;
  return fresh;
}

function saveMemoryState(s: MemoryState): void {
  try {
    mkdirSync(dirname(STATE_FILE), { recursive: true });
    writeFileSync(STATE_FILE, JSON.stringify(s, null, 2));
  } catch (e: any) {
    if (
      (memoryState && memoryState.sessionId !== s.sessionId) ||
      !memoryState
    ) {
      console.warn(
        `[memory] failed to persist state: ${e?.message ?? e}`,
      );
    }
  }
}

export function getMemoryState(): MemoryState | undefined {
  return memoryState;
}

// ── SSE lifecycle ─────────────────────────────────────────────────
export function restartSseStream(reason: string): void {
  if (!STALE_CONTEXT_ENABLED) return;
  try {
    sseAbortController?.abort();
  } catch {}
  sseAbortController = new AbortController();
  void runSseStream(sseAbortController.signal, reason);
}

export function stopSseStream(): void {
  try {
    sseAbortController?.abort();
  } catch {}
  sseAbortController = undefined;
}

// ── Drain ─────────────────────────────────────────────────────────
export function drainStalenessNotes(): string {
  if (pendingStalenessNotes.length === 0) return "";
  const merged = pendingStalenessNotes.join("\n\n");
  pendingStalenessNotes.length = 0;
  refreshBadge();
  return merged;
}

// ── SSE stream parser ─────────────────────────────────────────────
async function runSseStream(
  signal: AbortSignal,
  reason: string,
): Promise<void> {
  const ms = loadMemoryState();
  const url = `${BASE_URL}/events/stream?session_id=${encodeURIComponent(ms.sessionId)}`;
  const headers: Record<string, string> = {
    Accept: "text/event-stream",
    "Cache-Control": "no-cache",
  };
  if (ms.lastEventId > 0) {
    headers["Last-Event-ID"] = String(ms.lastEventId);
  }

  let res: Response;
  try {
    res = await fetch(url, { headers, signal });
  } catch (e: any) {
    if (signal.aborted) return;
    return;
  }
  if (!res.ok || !res.body) return;

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  let eventType = "";
  let eventId = "";
  let dataLines: string[] = [];

  const dispatch = () => {
    if (dataLines.length === 0) {
      eventType = "";
      eventId = "";
      return;
    }
    const dataStr = dataLines.join("\n");
    dataLines = [];
    const id = Number(eventId);
    eventId = "";
    const type = eventType;
    eventType = "";

    if (type === "cursor-too-old") {
      void onCursorTooOld(dataStr);
      return;
    }
    let body: any;
    try {
      body = JSON.parse(dataStr);
    } catch {
      return;
    }
    if (!Number.isNaN(id) && id > 0) {
      memoryState!.lastEventId = id;
      saveMemoryState(memoryState!);
    }
    onStaleEvent(body, type);
  };

  try {
    while (!signal.aborted) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });

      let idx: number;
      while ((idx = buf.indexOf("\n\n")) >= 0) {
        const frame = buf.slice(0, idx);
        buf = buf.slice(idx + 2);
        for (const line of frame.split("\n")) {
          if (line.startsWith(":")) continue;
          const colon = line.indexOf(":");
          if (colon < 0) continue;
          const key = line.slice(0, colon);
          let val = line.slice(colon + 1);
          if (val.startsWith(" ")) val = val.slice(1);
          switch (key) {
            case "id":
              eventId = val;
              break;
            case "event":
              eventType = val;
              break;
            case "data":
              dataLines.push(val);
              break;
          }
        }
        dispatch();
      }
    }
  } catch (e: any) {
    if (signal.aborted) return;
  }
}

// ── Event handlers ────────────────────────────────────────────────

async function onCursorTooOld(_data: string): Promise<void> {
  const ms = memoryState;
  if (!ms) return;
  let verdict: any;
  try {
    verdict = await memoryRequest(
      "GET",
      `/lease/check?session_id=${encodeURIComponent(ms.sessionId)}`,
    );
  } catch {
    return;
  }
  const stale: { blockId: string; etag: string }[] =
    verdict?.stale ?? [];
  const missing: string[] = verdict?.missing ?? [];
  if (stale.length === 0 && missing.length === 0) {
    ms.lastEventId = 0;
    saveMemoryState(ms);
    return;
  }
  pendingStalenessNotes.push(
    `IMPORTANT — memory invalidation. While this session was paused, ${stale.length} ` +
      `entry(ies) you previously cited were updated, and ${missing.length} were removed. ` +
      `The exact changes were not preserved across the gap — your prior claims about this ` +
      `material are NOT reliable. Before answering any follow-up that depends on those entries, ` +
      `call recall again to fetch the current version, then proceed.`,
  );
  refreshBadge();
  ms.lastEventId = 0;
  saveMemoryState(ms);
}

function onStaleEvent(ev: StaleEvent, type: string): void {
  const source: string = ev?.source ?? "";
  const shortSrc = source.startsWith("obsidian://vault/")
    ? decodeURIComponent(
        source.replace(/^obsidian:\/\/vault\/[^/]+\//, ""),
      )
    : source.startsWith("file://")
      ? source.slice(7)
      : source;
  const headingPath: string[] = Array.isArray(ev?.headingPath)
    ? ev.headingPath
    : [];
  const sectionRef =
    headingPath.length > 0
      ? `the "${headingPath.join(" > ")}" section of`
      : "a section of";
  const trim = (s: string | undefined, max = 220) => {
    if (!s) return "";
    const oneline = s.replace(/\s+/g, " ").trim();
    return oneline.length > max
      ? oneline.slice(0, max - 1) + "…"
      : oneline;
  };
  const oldText = trim(ev?.delta?.oldExcerpt);
  const newText = trim(ev?.delta?.newExcerpt);

  let body: string;
  switch (type) {
    case "added":
      body =
        `IMPORTANT — memory update. New content was added to "${shortSrc}" — ` +
        `${sectionRef.replace("a section", "this section")} now reads: "${newText}". ` +
        `This is fresh information you didn't have on prior turns; if any of your earlier ` +
        `statements should now be updated in light of it, correct them in your next reply.`;
      break;
    case "removed":
      body =
        `IMPORTANT — memory invalidation. Content you previously cited from "${shortSrc}" ` +
        `(${sectionRef} this entry) has been REMOVED. The deleted text was: "${oldText}". ` +
        `Any claim you made on prior turns that relied on this content is no longer ` +
        `supported. Do not repeat that claim. If asked, acknowledge that the source was ` +
        `removed and offer to re-recall.`;
      break;
    case "updated":
    default:
      body =
        `IMPORTANT — memory invalidation. ${
          sectionRef[0].toUpperCase() + sectionRef.slice(1)
        } ` +
        `"${shortSrc}" was JUST UPDATED. ` +
        `The PREVIOUS version, which is no longer authoritative, read: "${oldText}". ` +
        `The CURRENT version reads: "${newText}". ` +
        `Treat any claim you made on prior turns that depended on the previous text as ` +
        `SUPERSEDED. Use the current version going forward; cite it directly without ` +
        `calling recall again. If your prior reply contradicts the current text, correct ` +
        `yourself explicitly in your next response rather than repeating the old claim.`;
      break;
  }
  pendingStalenessNotes.push(body);
  refreshBadge();
}

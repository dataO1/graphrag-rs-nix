// src/tools/recall.ts
import { Type } from "typebox";
import { StringEnum } from "@mariozechner/pi-ai";

// src/config.ts
import { homedir } from "os";
var BASE_URL = process.env.MEMORY_BASE_URL || "http://127.0.0.1:17180";
var HINT_RECALL_ENABLED = (process.env.MEMORY_HINT_RECALL ?? "1") !== "0";
var CATALOG_REFRESH_MS = (Number(process.env.MEMORY_CATALOG_REFRESH_MINS) || 5) * 6e4;
var HINT_OVERLAP_THRESHOLD = Number(process.env.MEMORY_HINT_OVERLAP_THRESHOLD) || 1;
var HINT_MAX_TITLES = 5;
var STALE_CONTEXT_ENABLED = (process.env.MEMORY_SSE_ENABLED ?? "1") !== "0";
var STATE_FILE = process.env.MEMORY_STATE_FILE || `${homedir()}/.pi/agent/extensions/memory-state.json`;
var HEALTH_POLL_MS = 3e4;
var PING_TIMEOUT_MS = 1500;
var PULSE_FRAME_MS = 200;
var BLINK_FRAME_MS = 150;
var PULSE_FRAMES = [
  "\u2581",
  "\u2582",
  "\u2583",
  "\u2584",
  "\u2585",
  "\u2586",
  "\u2587",
  "\u2588",
  "\u2587",
  "\u2586",
  "\u2585",
  "\u2584",
  "\u2583",
  "\u2582"
];
var BLINK_FRAMES = ["\u25A0", "\u25A1"];
var RECALL_INDICATOR = {
  frames: ["\u25C8", "\u25C7", "\u25C6", "\u25C7"],
  intervalMs: 200
};
var REMEMBER_INDICATOR = {
  frames: ["\u25CF", "\u25CB"],
  intervalMs: 150
};

// src/memory-client.ts
async function memoryRequest(method, path, body) {
  const url = `${BASE_URL}${path}`;
  const res = await fetch(url, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : void 0
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(
      `memory ${method} ${path} failed (${res.status}): ${text}`
    );
  }
  return res.json();
}

// src/ui.ts
import { Text } from "@mariozechner/pi-tui";
var state = {
  ui: void 0,
  serverReachable: false,
  recallActive: 0,
  rememberActive: 0
};
var setUi = (v) => {
  state.ui = v;
};
var incRecall = () => {
  state.recallActive++;
};
var decRecall = () => {
  state.recallActive = Math.max(0, state.recallActive - 1);
};
var incRemember = () => {
  state.rememberActive++;
};
var decRemember = () => {
  state.rememberActive = Math.max(0, state.rememberActive - 1);
};
var frameIdx = 0;
var animTimer;
var pollTimer;
function stopAnim() {
  if (animTimer) {
    clearInterval(animTimer);
    animTimer = void 0;
  }
}
function startAnim(frames, intervalMs) {
  stopAnim();
  frameIdx = 0;
  animTimer = setInterval(() => {
    frameIdx = (frameIdx + 1) % frames.length;
  }, intervalMs);
}
function refreshBadge() {
  if (state.rememberActive > 0) {
    startAnim(BLINK_FRAMES, BLINK_FRAME_MS);
    state.ui?.setWorkingIndicator(REMEMBER_INDICATOR);
    state.ui?.setWorkingMessage("Remembering\u2026");
  } else if (state.recallActive > 0) {
    startAnim(PULSE_FRAMES, PULSE_FRAME_MS);
    state.ui?.setWorkingIndicator(RECALL_INDICATOR);
    state.ui?.setWorkingMessage("Recalling\u2026");
  } else {
    stopAnim();
    state.ui?.setWorkingIndicator(void 0);
    state.ui?.setWorkingMessage(void 0);
  }
}
async function healthPing() {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), PING_TIMEOUT_MS);
    const res = await fetch(`${BASE_URL}/health`, {
      signal: ctrl.signal
    });
    clearTimeout(t);
    state.serverReachable = res.ok;
  } catch {
    state.serverReachable = false;
  }
  if (state.recallActive === 0 && state.rememberActive === 0) refreshBadge();
}
function startPollTimer() {
  if (pollTimer) return;
  pollTimer = setInterval(() => {
    healthPing().catch(() => {
    });
  }, HEALTH_POLL_MS);
}
function stopPollTimer() {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = void 0;
  }
}
function stopAllAnim() {
  stopAnim();
}
function truncateForTag(s, max = 60) {
  if (!s) return "";
  const oneline = s.replace(/\s+/g, " ").trim();
  return oneline.length > max ? oneline.slice(0, max - 1) + "\u2026" : oneline;
}
function filterSuffix(args) {
  if (!args) return "";
  const bits = [];
  const asOf = args.asOf ?? args.as_of;
  const maxV = args.maxVersionsPerDoc ?? args.max_versions_per_doc;
  if (asOf) bits.push(`as of ${truncateForTag(String(asOf), 20)}`);
  if (maxV && Number(maxV) > 1)
    bits.push(`last ${maxV} versions`);
  return bits.length ? ` [${bits.join(", ")}]` : "";
}
function recallCallTag(theme, args) {
  const q = truncateForTag(args?.question ?? "");
  const body = q ? ` ${q}` : "";
  const suffix = filterSuffix(args);
  const suffixStyled = suffix ? theme.fg("muted", suffix) : "";
  return new Text(
    `${theme.fg("toolTitle", theme.bold("\u258C recall"))}${body}${suffixStyled}`
  );
}
function recallCallTagError(theme, args) {
  const q = truncateForTag(args?.question ?? "");
  const body = q ? ` ${q}` : "";
  const suffix = filterSuffix(args);
  const suffixStyled = suffix ? theme.fg("muted", suffix) : "";
  return new Text(
    `${theme.fg("error", theme.bold("\u258C recall \u2717"))}${body}${suffixStyled}`
  );
}
function recallOutcomeLine(theme, result) {
  const muted = (s) => theme.fg("muted", s);
  if (result?.isError) {
    const txt = result?.content?.[0]?.text ?? "error";
    return new Text(muted(`  \u21B3 ${txt.slice(0, 80)}`));
  }
  try {
    const txt = result?.content?.[0]?.text ?? "";
    const hits = (txt.match(/Top (\d+) hits:/) ?? [])[1] ?? "?";
    const conf = (txt.match(/Confidence: ([\d.]+)/) ?? [])[1];
    const ms = (txt.match(/(\d+)ms\s*$/) ?? [])[1];
    const top = (txt.match(/^\s*-\s*"([^"]{1,60})/m) ?? [])[1];
    const provenanceMatch = txt.match(
      /←\s*([^\s\[]+)(:(\d+)(?:-(\d+))?)?/m
    );
    const parts = [`${hits} hits`];
    if (conf) parts.push(`conf ${conf}`);
    if (ms) parts.push(`${ms}ms`);
    if (top) parts.push(`top: ${top}`);
    if (provenanceMatch) {
      const src = provenanceMatch[1];
      const lineRange = provenanceMatch[2] ?? "";
      const shortSrc = src.startsWith("obsidian://vault/") ? decodeURIComponent(
        src.replace(/^obsidian:\/\/vault\/[^/]+\//, "")
      ) : src.startsWith("file://") ? src.slice(7) : src;
      parts.push(`from: ${shortSrc}${lineRange}`);
    }
    return new Text(muted(`  \u21B3 ${parts.join(" \u2022 ")}`));
  } catch {
    return new Text(muted("  \u21B3 recalled"));
  }
}
var lastAssistantText;
function getLastAssistantText() {
  return lastAssistantText;
}
function setLastAssistantText(text) {
  lastAssistantText = text;
}
function extractAssistantText(message) {
  if (typeof message?.content === "string") return message.content;
  if (Array.isArray(message?.content)) {
    return message.content.filter(
      (b) => b?.type === "text" && typeof b.text === "string"
    ).map((b) => b.text).join("\n");
  }
  return "";
}

// src/sse.ts
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { dirname } from "path";
var memoryState;
var sseAbortController;
var pendingStalenessNotes = [];
function loadMemoryState() {
  if (memoryState) return memoryState;
  try {
    if (existsSync(STATE_FILE)) {
      const raw = JSON.parse(readFileSync(STATE_FILE, "utf8"));
      if (typeof raw?.sessionId === "string" && typeof raw?.lastEventId === "number") {
        memoryState = raw;
        return memoryState;
      }
    }
  } catch {
  }
  const fresh = {
    sessionId: typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : `pi-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`,
    lastEventId: 0
  };
  saveMemoryState(fresh);
  memoryState = fresh;
  return fresh;
}
function saveMemoryState(s) {
  try {
    mkdirSync(dirname(STATE_FILE), { recursive: true });
    writeFileSync(STATE_FILE, JSON.stringify(s, null, 2));
  } catch (e) {
    if (memoryState && memoryState.sessionId !== s.sessionId || !memoryState) {
      console.warn(
        `[memory] failed to persist state: ${e?.message ?? e}`
      );
    }
  }
}
function getMemoryState() {
  return memoryState;
}
function restartSseStream(reason) {
  if (!STALE_CONTEXT_ENABLED) return;
  try {
    sseAbortController?.abort();
  } catch {
  }
  sseAbortController = new AbortController();
  void runSseStream(sseAbortController.signal, reason);
}
function stopSseStream() {
  try {
    sseAbortController?.abort();
  } catch {
  }
  sseAbortController = void 0;
}
function drainStalenessNotes() {
  if (pendingStalenessNotes.length === 0) return "";
  const merged = pendingStalenessNotes.join("\n\n");
  pendingStalenessNotes.length = 0;
  refreshBadge();
  return merged;
}
async function runSseStream(signal, reason) {
  const ms = loadMemoryState();
  const url = `${BASE_URL}/events/stream?session_id=${encodeURIComponent(ms.sessionId)}`;
  const headers = {
    Accept: "text/event-stream",
    "Cache-Control": "no-cache"
  };
  if (ms.lastEventId > 0) {
    headers["Last-Event-ID"] = String(ms.lastEventId);
  }
  let res;
  try {
    res = await fetch(url, { headers, signal });
  } catch (e) {
    if (signal.aborted) return;
    return;
  }
  if (!res.ok || !res.body) return;
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  let eventType = "";
  let eventId = "";
  let dataLines = [];
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
    let body;
    try {
      body = JSON.parse(dataStr);
    } catch {
      return;
    }
    if (!Number.isNaN(id) && id > 0) {
      memoryState.lastEventId = id;
      saveMemoryState(memoryState);
    }
    onStaleEvent(body, type);
  };
  try {
    while (!signal.aborted) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      let idx;
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
  } catch (e) {
    if (signal.aborted) return;
  }
}
async function onCursorTooOld(_data) {
  const ms = memoryState;
  if (!ms) return;
  let verdict;
  try {
    verdict = await memoryRequest(
      "GET",
      `/lease/check?session_id=${encodeURIComponent(ms.sessionId)}`
    );
  } catch {
    return;
  }
  const stale = verdict?.stale ?? [];
  const missing = verdict?.missing ?? [];
  if (stale.length === 0 && missing.length === 0) {
    ms.lastEventId = 0;
    saveMemoryState(ms);
    return;
  }
  pendingStalenessNotes.push(
    `IMPORTANT \u2014 memory invalidation. While this session was paused, ${stale.length} entry(ies) you previously cited were updated, and ${missing.length} were removed. The exact changes were not preserved across the gap \u2014 your prior claims about this material are NOT reliable. Before answering any follow-up that depends on those entries, call recall again to fetch the current version, then proceed.`
  );
  refreshBadge();
  ms.lastEventId = 0;
  saveMemoryState(ms);
}
function onStaleEvent(ev, type) {
  const source = ev?.source ?? "";
  const shortSrc = source.startsWith("obsidian://vault/") ? decodeURIComponent(
    source.replace(/^obsidian:\/\/vault\/[^/]+\//, "")
  ) : source.startsWith("file://") ? source.slice(7) : source;
  const headingPath = Array.isArray(ev?.headingPath) ? ev.headingPath : [];
  const sectionRef = headingPath.length > 0 ? `the "${headingPath.join(" > ")}" section of` : "a section of";
  const trim = (s, max = 220) => {
    if (!s) return "";
    const oneline = s.replace(/\s+/g, " ").trim();
    return oneline.length > max ? oneline.slice(0, max - 1) + "\u2026" : oneline;
  };
  const oldText = trim(ev?.delta?.oldExcerpt);
  const newText = trim(ev?.delta?.newExcerpt);
  let body;
  switch (type) {
    case "added":
      body = `IMPORTANT \u2014 memory update. New content was added to "${shortSrc}" \u2014 ${sectionRef.replace("a section", "this section")} now reads: "${newText}". This is fresh information you didn't have on prior turns; if any of your earlier statements should now be updated in light of it, correct them in your next reply.`;
      break;
    case "removed":
      body = `IMPORTANT \u2014 memory invalidation. Content you previously cited from "${shortSrc}" (${sectionRef} this entry) has been REMOVED. The deleted text was: "${oldText}". Any claim you made on prior turns that relied on this content is no longer supported. Do not repeat that claim. If asked, acknowledge that the source was removed and offer to re-recall.`;
      break;
    case "updated":
    default:
      body = `IMPORTANT \u2014 memory invalidation. ${sectionRef[0].toUpperCase() + sectionRef.slice(1)} "${shortSrc}" was JUST UPDATED. The PREVIOUS version, which is no longer authoritative, read: "${oldText}". The CURRENT version reads: "${newText}". Treat any claim you made on prior turns that depended on the previous text as SUPERSEDED. Use the current version going forward; cite it directly without calling recall again. If your prior reply contradicts the current text, correct yourself explicitly in your next response rather than repeating the old claim.`;
      break;
  }
  pendingStalenessNotes.push(body);
  refreshBadge();
}

// src/tools/recall.ts
function registerRecall(pi) {
  pi.registerTool({
    name: "memory_recall",
    label: "recall",
    description: 'Use whenever the user\'s question depends on something in their long-term memory \u2014 anything they have written down, decided, planned, or noted. Use even if the user does not explicitly say "recall" / "check" / "look up". Even if you think you already know the answer, if it depends on user-specific facts you MUST recall first.\n\n**THE CHUNK IS THE ANSWER.** When this returns content, the `A:` block + the excerpts under `Top N hits:` are what you respond from. Do NOT follow up with `read`/`cat`/`find`/`grep` against the source. The classic failure: agent gets a good excerpt, gets nervous, guesses a path from the `source` URI, hits ENOENT, runs `find /` to recover \u2014 eating 30+ seconds when the excerpt was already sufficient.\n\nABSTENTION RULE: before answering any non-trivial question that depends on user-specific context, check whether you can point to the exact passage in THIS conversation that supports your answer. If you cannot \u2014 recall. This is a structural check, not a confidence check.\n\nIf the excerpt is genuinely insufficient (user asked for the full document, or the excerpt visibly truncates content the user needs), each hit has an `absolutePath` field \u2014 the resolved local-readable filesystem path. Pass it VERBATIM to your read tool. NEVER reconstruct paths from the `source` URI; NEVER prepend cwd; NEVER guess from training data. If a hit has no `absolutePath`, the source is external \u2014 recall again with a sharper query instead.\n\nMode picks the retrieval strategy: `default` (full multi-hop synthesis via HippoRAG, ~6s), `quick` (fast vector-keyword excerpts, ~50ms). Set `reason: true` for compound multi-hop questions (forces HippoRAG).\n\nTime/history filters (use whenever the user references time):\n  \u2022 `asOf` \u2014 RFC 3339; only consider entries valid at-or-after this time.\n  \u2022 `maxVersionsPerDoc` \u2014 defaults to 1 (current only). \u22652 for diff-style questions.\n\nPARALLELISE \u2014 independent recall questions go in one tool-call batch. Sequential is wasted wall-clock time.',
    promptSnippet: "memory_recall \u2014 first action when the user's question depends on long-term memory; excerpt IS the answer; absolutePath is the only safe filesystem input. Modes: default|quick. reason=true for multi-hop. SAFE TO PARALLELISE.",
    promptGuidelines: [
      `Recall is the FIRST action whenever the user's question depends on something in their long-term memory \u2014 even when they don't explicitly say "recall" / "check" / "look up".`,
      'Before answering any non-trivial user-specific question, check: "Can I point to the exact passage in THIS conversation that supports my answer?" If no \u2014 recall. This is a structural check, not a confidence check.',
      "The excerpt IS the answer for most queries \u2014 answer the user from it directly without a follow-up `read`.",
      "If you must read the source, use `absolutePath` from the hit verbatim. Never reconstruct from `source` (a citation URI, not a path); never prepend cwd; never guess.",
      "If a hit has no `absolutePath`, the source is external \u2014 you cannot filesystem-read it; recall again with a sharper query.",
      "Start with mode=default. Use quick only for fast existence checks or straightforward lookups.",
      "When recall results disagree about a fact, prefer the chunk with the most recent `lastModified`; treat older chunks as superseded.",
      'Time-bound queries ("today", "yesterday", "since X", "this week") MUST set `asOf` to the appropriate RFC 3339 timestamp.',
      'Diff-style questions ("what changed in entry X") MUST set `maxVersionsPerDoc` \u2265 2 so prior versions are visible.',
      "PARALLELISE: when the user asks about several distinct topics, fire one memory_recall per topic in the same tool batch. Don't serialise independent questions.",
      "For deep multi-hop lookups, 'what changed' diffs, or research-style synthesis across multiple sources, use `reason: true` to decompose the question into sub-queries. After recall returns, synthesise the hits with citations \u2014 cite the chunk's `source` field for each claim.",
      "If an excerpt leaves any sub-claim unsupported, recall again with a tighter query. Do not synthesise across the gap."
    ],
    parameters: Type.Object({
      question: Type.String({
        description: "Natural-language question."
      }),
      mode: Type.Optional(
        StringEnum(["default", "quick"], {
          description: "`default`: Full multi-hop synthesis via HippoRAG (~6s). `quick`: Fast vector-keyword excerpts (~50ms)."
        })
      ),
      reason: Type.Optional(
        Type.Boolean({
          description: "Decompose into sub-queries for compound multi-hop questions (slowest). Forces default mode. Use when a recall leaves sub-claims unsupported or you need research-style synthesis across multiple sources."
        })
      ),
      topK: Type.Optional(
        Type.Integer({
          default: 8,
          minimum: 1,
          maximum: 50,
          description: "Top-K seeds."
        })
      ),
      asOf: Type.Optional(
        Type.String({
          description: "RFC 3339 (e.g. '2026-05-06T00:00:00Z'). Only consider chunks valid at-or-after this time. Use for 'today', 'yesterday', 'since X'."
        })
      ),
      maxVersionsPerDoc: Type.Optional(
        Type.Integer({
          default: 1,
          minimum: 1,
          maximum: 10,
          description: "Per source doc, how many recent versions to consider. 1 = current only (default). Set \u22652 for diff-style questions ('what changed in X')."
        })
      )
    }),
    executionMode: "parallel",
    renderCall: (args, theme, ctx) => {
      const r = ctx?.result;
      return r?.isError ? recallCallTagError(theme, args) : recallCallTag(theme, args);
    },
    renderResult: (result, _opts, theme) => recallOutcomeLine(theme, result),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      incRecall();
      refreshBadge();
      try {
        const {
          question,
          mode,
          reason,
          topK,
          asOf,
          maxVersionsPerDoc
        } = params;
        const agentMode = mode ?? "default";
        const serverMode = reason || agentMode === "default" ? "hipporag" : agentMode === "quick" ? "search" : "hipporag";
        const body = {
          query: question,
          mode: serverMode,
          top_k: topK ?? 8
        };
        if (asOf) body.asOf = asOf;
        if (maxVersionsPerDoc && maxVersionsPerDoc > 1)
          body.maxVersionsPerDoc = maxVersionsPerDoc;
        const ms = getMemoryState();
        if (ms?.sessionId) body.sessionId = ms.sessionId;
        const result = await memoryRequest(
          "POST",
          "/api/query",
          body
        );
        let text = "";
        const seenPaths = /* @__PURE__ */ new Set();
        const absPaths = [];
        for (const r of result.results ?? []) {
          if (r.absolutePath && !seenPaths.has(r.absolutePath)) {
            seenPaths.add(r.absolutePath);
            absPaths.push(r.absolutePath);
          }
        }
        if (absPaths.length > 0) {
          text += "READABLE FILES (pass these absolute paths VERBATIM to your read tool ONLY if the chunk excerpts below are insufficient. Do NOT guess paths from the `source` URI; do NOT prepend cwd; do NOT transform the `source` URI into a filesystem path \u2014 the resolved path is right here):\n";
          for (const p of absPaths) text += `  \u2022 ${p}
`;
          text += "\nTHE CHUNK EXCERPTS BELOW ARE THE ANSWER for most queries. Read them and respond. Only escalate to a file `read` if the user explicitly asked for the full document or the excerpt clearly truncates content the user needs.\n\n";
        }
        text += `Q: ${question}
Mode: ${result.mode}
`;
        if (result.answer)
          text += `
A: ${result.answer}
`;
        if (result.confidence !== void 0 && result.confidence !== null) {
          text += `Confidence: ${result.confidence.toFixed(2)}
`;
        }
        if (result.keyEntities && result.keyEntities.length > 0) {
          text += `Entities: ${result.keyEntities.join(", ")}
`;
        }
        if (result.reasoningSteps && result.reasoningSteps.length > 0) {
          text += "\nReasoning:\n";
          for (const step of result.reasoningSteps) {
            text += `  ${step.step}. ${step.description} (conf ${step.confidence.toFixed(2)})
`;
            if (step.evidence) text += `     ${step.evidence}
`;
          }
        }
        if (result.sources && result.sources.length > 0) {
          text += "\nSources:\n";
          for (const src of result.sources) {
            text += `  - ${src.kind} (${src.id}): ${src.relevance.toFixed(2)} \u2014 ${src.excerpt.slice(0, 200)}
`;
          }
        }
        text += `
Top ${result.results.length} hits:
`;
        for (const r of result.results) {
          const src = r.source ? ` \u2190 ${r.source}` : "";
          const lines = r.lineStart && r.lineEnd ? r.lineStart === r.lineEnd ? `:${r.lineStart}` : `:${r.lineStart}-${r.lineEnd}` : "";
          const head = Array.isArray(r.headingPath) && r.headingPath.length > 0 ? ` [${r.headingPath.join(" > ")}]` : "";
          const ts = r.lastModified ? ` @ ${r.lastModified}` : "";
          const abs = r.absolutePath ? `
    readable @ ${r.absolutePath}` : "";
          text += `  - "${r.title}" (sim ${r.similarity.toFixed(3)})${ts}${src}${lines}${head}${abs}
    ${r.excerpt}
`;
        }
        text += `
${result.processingTimeMs}ms`;
        return {
          content: [{ type: "text", text }]
        };
      } finally {
        decRecall();
        refreshBadge();
      }
    }
  });
}

// src/tools/remember.ts
import { Type as Type2 } from "typebox";
import { Spacer } from "@mariozechner/pi-tui";
function registerRemember(pi) {
  pi.registerTool({
    name: "memory_remember",
    label: "remember",
    description: "Commit material to the user's long-term memory. Pick one: `path` / `pathsGlob` / `paths` (on-disk files), or `content`+`title` (generated/pasted text). Recallable shortly after \u2014 no follow-up call needed.",
    promptSnippet: "memory_remember \u2014 prefer `path`/`pathsGlob` for on-disk files; `content` only for generated text",
    promptGuidelines: [
      "On-disk file \u2192 use `path` (or `pathsGlob`). Don't Read+forward via `content`.",
      "`content`+`title` is for generated/pasted text only.",
      "Batch response: `results[]` with status \u2208 {ingested, duplicate, unsupported, rejected, error}."
    ],
    parameters: Type2.Object({
      path: Type2.Optional(
        Type2.String({
          description: "Absolute path to one file."
        })
      ),
      pathsGlob: Type2.Optional(
        Type2.String({
          description: "Glob, e.g. '/abs/dir/**/*.md' or relative + `globRoot`."
        })
      ),
      globRoot: Type2.Optional(
        Type2.String({
          description: "Anchor for relative `pathsGlob`."
        })
      ),
      paths: Type2.Optional(
        Type2.Array(Type2.String(), {
          description: "Explicit list of absolute paths."
        })
      ),
      title: Type2.Optional(
        Type2.String({
          description: "Required for `content`."
        })
      ),
      content: Type2.Optional(
        Type2.String({
          description: "Inline body. Use only for generated/pasted text."
        })
      ),
      id: Type2.Optional(
        Type2.String({
          description: "Optional caller-supplied id for later `forget`."
        })
      )
    }),
    renderCall: () => new Spacer(0),
    renderResult: () => new Spacer(0),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      incRemember();
      refreshBadge();
      const sessionFile = ctx.sessionManager.sessionFile;
      const sessionLabel = sessionFile ? ` to ${sessionFile.split("/").pop()?.replace(".jsonl", "") ?? sessionFile}` : "";
      const body = {};
      if (params.path !== void 0) body.path = params.path;
      if (params.pathsGlob !== void 0)
        body.pathsGlob = params.pathsGlob;
      if (params.globRoot !== void 0)
        body.globRoot = params.globRoot;
      if (params.paths !== void 0) body.paths = params.paths;
      if (params.content !== void 0)
        body.content = params.content;
      if (params.title !== void 0)
        body.title = params.title;
      if (params.id !== void 0) body.id = params.id;
      const hasContent = body.content !== void 0;
      if (hasContent && !body.source) {
        body.source = `pi://generated/${crypto.randomUUID?.() ?? `pi-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`}`;
      }
      if (sessionFile) body.session = sessionFile;
      void (async () => {
        try {
          await memoryRequest(
            "POST",
            "/api/documents",
            body
          );
        } catch (e) {
          ctx.ui.notify(
            `memory_remember failed: ${e?.message ?? e}`,
            "warning"
          );
        } finally {
          decRemember();
          refreshBadge();
        }
      })();
      return {
        content: [{ type: "text", text: `queued${sessionLabel}` }]
      };
    }
  });
}

// src/tools/catalog.ts
import { Type as Type3 } from "typebox";
function registerCatalog(pi) {
  pi.registerTool({
    name: "memory_catalog",
    label: "catalog",
    description: "Page through entries currently in long-term memory. Use to discover what's already there before deciding to `remember` something that may already be present.",
    promptSnippet: "memory_catalog \u2014 list stored entries",
    parameters: Type3.Object({}),
    async execute(_toolCallId) {
      const result = await memoryRequest("GET", "/api/documents");
      let text = `${result.total} document(s):
`;
      if (result.documents.length === 0) {
        text += "  (none)\n";
      } else {
        for (const d of result.documents) {
          const extra = d.excerpt ? ` \u2014 ${d.excerpt.slice(0, 120)}\u2026` : d.contentLength ? ` (${d.contentLength} chars)` : "";
          text += `  - "${d.title}" [${d.id}]${extra}
`;
        }
      }
      return { content: [{ type: "text", text }] };
    }
  });
}

// src/tools/forget.ts
import { Type as Type4 } from "typebox";
function registerForget(pi) {
  pi.registerTool({
    name: "memory_forget",
    label: "forget",
    description: "Remove an entry from the user's long-term memory. Use sparingly \u2014 prefer asking the user before deleting personal material.",
    promptSnippet: "memory_forget \u2014 remove an entry by id",
    parameters: Type4.Object({
      id: Type4.String({
        description: "User-supplied id (path, custom string) or server UUID."
      })
    }),
    async execute(_toolCallId, params) {
      const result = await memoryRequest(
        "DELETE",
        `/api/documents/${encodeURIComponent(params.id)}`
      );
      return {
        content: [
          {
            type: "text",
            text: `Forgot: ${result.message ?? params.id}`
          }
        ]
      };
    }
  });
}

// src/tools/status.ts
import { Type as Type5 } from "typebox";
function registerStatus(pi) {
  pi.registerTool({
    name: "memory_status",
    label: "status",
    description: "Memory health stats (entry counts, entity counts, relationship counts, vector counts) + lastBuiltAt. DO NOT call as a warm-up before recall \u2014 the toolbar `mem \u25CF/\u25CB` badge already shows reachability. Only call when the user explicitly asks about memory size / build state, or to disambiguate an empty-memory vs no-match recall.",
    promptSnippet: "memory_status \u2014 only on explicit user request or 0-hit disambiguation",
    parameters: Type5.Object({}),
    async execute(_toolCallId) {
      const result = await memoryRequest(
        "GET",
        "/api/graph/stats"
      );
      let text = `Status:
`;
      text += `  Documents: ${result.documentCount}
`;
      text += `  Entities: ${result.entityCount}
`;
      text += `  Relationships: ${result.relationshipCount}
`;
      text += `  Vectors: ${result.vectorCount}
`;
      text += `  Built: ${result.graphBuilt ? "yes" : "no"}
`;
      if (result.lastBuiltAt)
        text += `  Last built: ${result.lastBuiltAt}
`;
      text += `  Backend: ${result.backend}`;
      return { content: [{ type: "text", text }] };
    }
  });
}

// src/tools/log_action.ts
import { Type as Type6 } from "typebox";
import { Spacer as Spacer2 } from "@mariozechner/pi-tui";
function registerLogAction(pi) {
  pi.registerTool({
    name: "memory_log_action",
    label: "log action",
    description: "Log a session action row. Six columns. Use when the turn produced an architectural change, bug fix, doc edit, research finding, deliverable, or unexpected outcome. Server handles time-stamping, schema-matching append, and frontmatter union.",
    promptSnippet: "memory_log_action \u2014 6-column action row (Actions, Mutations, Why, Outcome, Related[])",
    promptGuidelines: [
      "Do NOT invoke proactively \u2014 wait for the end-of-turn nudge.",
      "If the turn also produced a decision, call memory_log_decision too.",
      "The `related` array should cite knowledge notes when applicable."
    ],
    parameters: Type6.Object({
      actions: Type6.String({
        description: "What was done (one sentence)."
      }),
      mutations: Type6.String({
        description: "What changed (files, config, state)."
      }),
      why: Type6.String({
        description: "Why this was done (context, trigger)."
      }),
      outcome: Type6.String({
        description: "Result / deliverable / next step."
      }),
      related: Type6.Optional(
        Type6.Array(Type6.String(), {
          description: "Related note titles or URLs."
        })
      )
    }),
    renderCall: () => new Spacer2(0),
    renderResult: () => new Spacer2(0),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      incRemember();
      refreshBadge();
      try {
        const now = (/* @__PURE__ */ new Date()).toISOString();
        const day = now.slice(0, 10);
        const sessionFile = ctx.sessionManager.sessionFile;
        const sessionLabel = sessionFile ? ` to ${sessionFile.split("/").pop()?.replace(".jsonl", "") ?? sessionFile}` : "";
        const title = `[LOG] ${day} \u2014 ${params.actions.slice(0, 72)}`;
        const related = params.related?.length ? params.related.map((r) => `[[${r}]]`).join(", ") : "\u2014";
        const content = [
          "| Time | Actions | Mutations | Why | Outcome | Related |",
          "|------|---------|-----------|-----|---------|---------|",
          `| ${now} | ${params.actions} | ${params.mutations} | ${params.why} | ${params.outcome} | ${related} |`
        ].join("\n");
        await memoryRequest("POST", "/api/documents", {
          title,
          content,
          source: `pi:///log/${now.slice(0, 10)}`,
          session: sessionFile ?? null
        });
        return {
          content: [{ type: "text", text: `logged${sessionLabel}` }]
        };
      } catch (e) {
        ctx.ui.notify(
          `log_action failed: ${e?.message ?? e}`,
          "warning"
        );
        return {
          isError: true,
          content: [
            {
              type: "text",
              text: `log_action failed: ${e?.message ?? e}`
            }
          ]
        };
      } finally {
        decRemember();
        refreshBadge();
      }
    }
  });
}

// src/tools/log_decision.ts
import { Type as Type7 } from "typebox";
import { Spacer as Spacer3 } from "@mariozechner/pi-tui";
function registerLogDecision(pi) {
  pi.registerTool({
    name: "memory_log_decision",
    label: "log decision",
    description: "Log a session decision row. Seven columns. Use when the turn's substance is a choice between alternatives WITH rationale. Server handles time-stamping, schema-matching append, and frontmatter union.",
    promptSnippet: "memory_log_decision \u2014 7-column decision row (Context, Options, Decision, Rollout, Rollback, Related[])",
    promptGuidelines: [
      "Do NOT invoke proactively \u2014 wait for the end-of-turn nudge.",
      "Decisions live in the log, NOT as separate knowledge notes.",
      "If the turn also produced actions worth logging, call memory_log_action too."
    ],
    parameters: Type7.Object({
      context: Type7.String({
        description: "Situation that demanded a decision."
      }),
      options: Type7.String({
        description: "Alternatives considered (comma-separated)."
      }),
      decision: Type7.String({
        description: "What was chosen and why."
      }),
      rollout: Type7.String({
        description: "How the decision will be / was implemented."
      }),
      rollback: Type7.String({
        description: "How to reverse if needed."
      }),
      related: Type7.Optional(
        Type7.Array(Type7.String(), {
          description: "Related note titles or URLs."
        })
      )
    }),
    renderCall: () => new Spacer3(0),
    renderResult: () => new Spacer3(0),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      incRemember();
      refreshBadge();
      try {
        const now = (/* @__PURE__ */ new Date()).toISOString();
        const day = now.slice(0, 10);
        const sessionFile = ctx.sessionManager.sessionFile;
        const sessionLabel = sessionFile ? ` to ${sessionFile.split("/").pop()?.replace(".jsonl", "") ?? sessionFile}` : "";
        const title = `[DECISION] ${day} \u2014 ${params.decision.slice(0, 72)}`;
        const related = params.related?.length ? params.related.map((r) => `[[${r}]]`).join(", ") : "\u2014";
        const content = [
          "| Time | Context | Options | Decision | Rollout | Rollback | Related |",
          "|------|---------|---------|----------|---------|----------|---------|",
          `| ${now} | ${params.context} | ${params.options} | ${params.decision} | ${params.rollout} | ${params.rollback} | ${related} |`
        ].join("\n");
        await memoryRequest("POST", "/api/documents", {
          title,
          content,
          source: `pi:///decision/${now.slice(0, 10)}`,
          session: sessionFile ?? null
        });
        return {
          content: [{ type: "text", text: `logged${sessionLabel}` }]
        };
      } catch (e) {
        ctx.ui.notify(
          `log_decision failed: ${e?.message ?? e}`,
          "warning"
        );
        return {
          isError: true,
          content: [
            {
              type: "text",
              text: `log_decision failed: ${e?.message ?? e}`
            }
          ]
        };
      } finally {
        decRemember();
        refreshBadge();
      }
    }
  });
}

// src/distill.ts
var pendingMilestones = [];
var DISTILL_NUDGE = "[memory] Distillation structural check. Higher bar. Ask: 'Did this turn produce a finding / decision rationale / architectural insight / unexpected behavior fact that (a) a future session would genuinely benefit from being able to recall, (b) is NOT already covered in an existing entry in the user's recorded material, (c) is NOT derivable from current code or git log, and (d) is NOT a re-statement of intermediate scratch?' If YES \u2014 invoke `memory_remember` with an insight-oriented title. False-positive distillation noise is worse than missed real insights \u2014 when in doubt, skip.\n\n[memory] Logging structural check. Evaluate this turn (yours + any subagents you dispatched). If the turn produced one of: an architectural change, a bug fix, a non-trivial documentation write or edit (new file, restructured section, distilled findings \u2014 anything beyond a single-sentence tweak), a research finding, a decision taken, an unexpected outcome that changes the user's mental model, OR a completed user-facing deliverable (new file, code change, config edit) \u2014 INCLUDING work done by a subagent you dispatched \u2014 fire the matching tool BEFORE responding:\n  \u2022 `memory_log_action` for action / change / deliverable / finding rows\n  \u2022 `memory_log_decision` for decision rows (choice between alternatives with rationale, including rollout + rollback)\nIf the turn produced both, fire both tools \u2014 one row each. Decisions live in the log, NOT as knowledge notes (temporal context is load-bearing). Single-sentence tweaks, read-only operations (recall/grep/read), and trivial chores (ls, git status) do NOT trigger.\n\nIf nothing triggered: respond with exactly '\u2713 nothing to distill' (a single line, no preamble).\nIf you called memory_remember: respond with '\u{1F4DD} consolidated: <title>' (use the title you passed to memory_remember).\nIf you called memory_log_action or memory_log_decision: count them and respond with '\u{1F4DD} logged: N actions + M decisions' (omit zero counts, e.g. '\u{1F4DD} logged: 1 action').\nIf you did both: '\u{1F4DD} consolidated: <title> + logged: N actions'.\nKeep it to ONE line, no preamble, no follow-up text.";
var forcedDistillTurn = false;
var savedDistillThinking;
function isDistillTurn() {
  return forcedDistillTurn;
}
function recordTodoCompleted(input) {
  const subject = typeof input.subject === "string" ? input.subject : typeof input.activeForm === "string" ? input.activeForm : `#${String(input.id ?? "?")}`;
  pendingMilestones.push({ type: "todo_completed", label: subject });
}
function recordSubagentFinished(input) {
  const agent = typeof input.agent === "string" ? input.agent : "subagent";
  const task = typeof input.task === "string" ? input.task.slice(0, 60) : "finished";
  pendingMilestones.push({
    type: "subagent_finished",
    label: `${agent}: ${task}`
  });
}
function buildMilestonePrefix() {
  if (pendingMilestones.length === 0) return "";
  const lines = pendingMilestones.map((m) => {
    const icon = m.type === "todo_completed" ? "\u2611" : "\u2B22";
    return `${icon} ${m.label}`;
  });
  pendingMilestones.length = 0;
  return `[memory] Notable this turn:
${lines.join("\n")}

`;
}
function registerDistillHook(pi) {
  pi.on("tool_result", async (event) => {
    if (event.isError) return;
    const input = event.input;
    if (event.toolName === "todo" && input.action === "update" && input.status === "completed") {
      recordTodoCompleted(input);
      return;
    }
    if (event.toolName === "subagent") {
      recordSubagentFinished(input);
      return;
    }
  });
  pi.on("agent_end", async (_event, ctx) => {
    if (forcedDistillTurn) {
      forcedDistillTurn = false;
      if (savedDistillThinking !== void 0) {
        pi.setThinkingLevel(savedDistillThinking);
        savedDistillThinking = void 0;
      }
      return;
    }
    forcedDistillTurn = true;
    savedDistillThinking = pi.getThinkingLevel();
    pi.setThinkingLevel("low");
    const prefix = buildMilestonePrefix();
    const nudge = prefix + DISTILL_NUDGE;
    pi.sendMessage(
      {
        customType: "memory-distill-nudge",
        content: nudge,
        display: false
      },
      { triggerTurn: true }
    );
  });
}

// src/hooks/message_end_distill.ts
import { Text as Text2 } from "@mariozechner/pi-tui";
function registerDistillSummaryRenderer(pi) {
  pi.registerMessageRenderer(
    "memory-distill-summary",
    (_entry, theme) => {
      const content = _entry?.content;
      let text = "";
      if (Array.isArray(content)) {
        text = content.filter((p) => p?.type === "text" && typeof p.text === "string").map((p) => p.text.trim()).join(" ");
      } else if (typeof content === "string") {
        text = content;
      }
      return new Text2(theme.fg("muted", text));
    }
  );
}
function registerDistillSummaryHook(pi) {
  pi.on("message_end", async (event) => {
    if (!isDistillTurn()) return void 0;
    const msg = event.message;
    if (msg?.role !== "assistant") return;
    const content = Array.isArray(msg.content) ? msg.content : typeof msg.content === "string" ? [{ type: "text", text: msg.content }] : [];
    const hasToolCalls = content.some(
      (part) => part?.type === "toolCall"
    );
    if (hasToolCalls) return void 0;
    const text = content.filter(
      (part) => part?.type === "text" && typeof part.text === "string"
    ).map((part) => part.text.trim()).join(" ").trim();
    if (!text) return void 0;
    return {
      message: {
        ...msg,
        // customType tells pi to use our registered renderer
        customType: "memory-distill-summary",
        content: [{ type: "text", text }]
      }
    };
  });
}

// src/catalog.ts
var STOP_WORDS = /* @__PURE__ */ new Set([
  "the",
  "a",
  "an",
  "and",
  "or",
  "but",
  "if",
  "then",
  "than",
  "of",
  "to",
  "in",
  "on",
  "at",
  "by",
  "for",
  "with",
  "from",
  "into",
  "about",
  "i",
  "me",
  "my",
  "we",
  "our",
  "you",
  "your",
  "it",
  "its",
  "this",
  "that",
  "these",
  "those",
  "is",
  "are",
  "was",
  "were",
  "be",
  "been",
  "being",
  "have",
  "has",
  "had",
  "do",
  "does",
  "did",
  "doing",
  "will",
  "would",
  "should",
  "could",
  "can",
  "may",
  "might",
  "must",
  "shall",
  "what",
  "which",
  "who",
  "whom",
  "whose",
  "where",
  "when",
  "why",
  "how",
  "all",
  "any",
  "some",
  "not",
  "no",
  "nor",
  "so",
  "as",
  "out",
  "up",
  "down",
  "off",
  "over",
  "under",
  "again",
  "just",
  "only",
  "very",
  "more",
  "most",
  "other",
  "such",
  "own",
  "same",
  "too"
]);
var catalog = [];
var catalogTimer;
function tokenize(text) {
  return new Set(
    text.toLowerCase().replace(/[^\p{L}\p{N}\s]/gu, " ").split(/\s+/).filter((w) => w.length >= 3 && !STOP_WORDS.has(w))
  );
}
async function refreshCatalog() {
  try {
    const r = await memoryRequest("GET", "/api/documents");
    if (Array.isArray(r?.documents)) {
      catalog = r.documents.map((d) => ({
        id: d.id,
        title: d.title ?? ""
      }));
    }
  } catch {
  }
}
function matchCatalog(promptText) {
  if (catalog.length === 0) return [];
  const promptTokens = tokenize(promptText);
  if (promptTokens.size === 0) return [];
  const scored = [];
  for (const entry of catalog) {
    if (!entry.title) continue;
    const titleTokens = tokenize(entry.title);
    let overlap = 0;
    for (const t of titleTokens) if (promptTokens.has(t)) overlap++;
    if (overlap >= HINT_OVERLAP_THRESHOLD) {
      scored.push({ entry, score: overlap });
    }
  }
  scored.sort((a, b) => b.score - a.score);
  return scored.slice(0, HINT_MAX_TITLES).map((s) => s.entry);
}
function startCatalogRefreshTimer() {
  if (catalogTimer) return;
  catalogTimer = setInterval(() => {
    refreshCatalog().catch(() => {
    });
  }, CATALOG_REFRESH_MS);
}
function stopCatalogRefreshTimer() {
  if (catalogTimer) {
    clearInterval(catalogTimer);
    catalogTimer = void 0;
  }
}

// src/hooks/before_agent_start.ts
function registerBeforeAgentStartHook(pi) {
  pi.on("before_agent_start", async (event, _ctx) => {
    const parts = [];
    parts.push(
      `[memory] Never answer questions about the user's stored memory from training data or guesswork. If the user's question depends on something they have written down, decided, planned, or noted, your FIRST action MUST be \`memory_recall\`. Trigger even when the user doesn't say "recall" / "check" / "look up".`
    );
    parts.push(
      '[memory] Before answering any non-trivial user-specific question, check: "Can I point to the exact passage in THIS conversation that supports my answer?" If no \u2014 recall. This is a structural check, not a confidence check.'
    );
    parts.push(
      "[memory] When `memory_recall` returns content, the chunk excerpt IS the answer for the user's question \u2014 don't follow up with `read`/`cat`/`find`/`grep` on the source. The `source` field is a citation URI for provenance, not a filesystem path; do not pass it to a shell tool. If the chunk is genuinely insufficient (user asked for the full document, or the excerpt truncates content the user needs), use the `absolutePath` field on the result \u2014 the only safe filesystem input. If `absolutePath` is absent, the source is external; recall again with a sharper query."
    );
    parts.push(
      "[memory] When recall results disagree about a fact, prefer the chunk with the most recent `lastModified`; treat older chunks as superseded."
    );
    parts.push(
      "[memory] For deep multi-hop lookups, 'what changed' diffs, research-style synthesis across multiple sources, or BEFORE starting a complex task that needs prior context (designing, implementing, refactoring, or debugging something the user has prior notes on), use `memory_recall` with `reason: true` to decompose the question into sub-queries. Do NOT stitch ad-hoc individual recalls when a compound question needs cross-referencing. After recall returns, synthesise the hits into a coherent answer WITH CITATIONS \u2014 cite the chunk's `source` field for each claim. If any sub-claim is unsupported, recall again with a tighter query rather than bridging the gap yourself. For diff-style questions 'what changed in X', set `maxVersionsPerDoc` \u2265 2."
    );
    if (HINT_RECALL_ENABLED) {
      const promptText = event.prompt ?? "";
      if (promptText) {
        const matches = matchCatalog(promptText);
        if (matches.length > 0) {
          const titles = matches.map((m) => `"${m.title}"`).join(", ");
          parts.push(
            `[memory] Catalog has potentially relevant docs: ${titles}. If relevant to the user's request, call memory_recall before proceeding.`
          );
        }
      }
    }
    const staleness = drainStalenessNotes();
    if (staleness) parts.push(staleness);
    if (parts.length === 0) return;
    return { systemPrompt: parts.join("\n\n") };
  });
}

// src/hooks/message_end_filter.ts
function normalizeContent(raw) {
  if (Array.isArray(raw)) return raw;
  if (typeof raw === "string") return [{ type: "text", text: raw }];
  return [];
}
function registerMessageEndFilterHook(pi) {
  pi.on("message_end", async (event) => {
    const msg = event.message;
    if (msg?.role !== "assistant") return;
    const normalized = normalizeContent(msg.content);
    const filtered = normalized.filter(
      (part) => part?.type !== "toolCall" || (part.name ?? "").length > 0
    );
    const needsNormalize = !Array.isArray(msg.content);
    const needsFilter = filtered.length !== normalized.length;
    const isEmpty = filtered.length === 0;
    if (needsNormalize || needsFilter || isEmpty) {
      const safe = isEmpty ? [{ type: "text", text: "\u23F3" }] : filtered;
      return { message: { ...msg, content: safe } };
    }
    return void 0;
  });
}

// src/hooks/message_end_cache.ts
function registerMessageEndCacheHook(pi) {
  pi.on("message_end", async (event, _ctx) => {
    const msg = event.message;
    if (msg?.role !== "assistant") return;
    const text = extractAssistantText(msg);
    if (text) {
      setLastAssistantText(text);
    }
  });
}

// src/hooks/lifecycle.ts
function registerLifecycleHooks(pi) {
  pi.on("session_start", async (_e, ctx) => {
    setUi(ctx.ui);
    await healthPing();
    startPollTimer();
    await refreshCatalog();
    if (HINT_RECALL_ENABLED) {
      startCatalogRefreshTimer();
    }
    if (STALE_CONTEXT_ENABLED) {
      loadMemoryState();
      restartSseStream("session_start");
    }
  });
  pi.on("agent_start", async (_e, ctx) => {
    setUi(ctx.ui);
    refreshBadge();
  });
  pi.on("session_shutdown", async () => {
    stopAllAnim();
    stopSseStream();
    stopPollTimer();
    stopCatalogRefreshTimer();
  });
}

// src/hooks/commands.ts
function registerCommands(pi) {
  pi.registerCommand("recall", {
    description: "Recall from your long-term memory. Usage: `/recall <question>`. Uses default mode (relational + semantic).",
    handler: async (args, ctx) => {
      const q = (args ?? "").trim();
      if (!q) {
        ctx.ui.notify("Usage: /recall <question>", "warning");
        return;
      }
      incRecall();
      refreshBadge();
      try {
        const r = await memoryRequest("POST", "/api/query", {
          query: q,
          mode: "hipporag",
          top_k: 8,
          ...getMemoryState()?.sessionId ? { sessionId: getMemoryState().sessionId } : {}
        });
        const ans = r?.answer ?? "(no answer)";
        const conf = r?.confidence != null ? ` (conf ${r.confidence.toFixed(2)})` : "";
        ctx.ui.notify(
          `Recall${conf}: ${ans}`,
          "info"
        );
      } catch (e) {
        ctx.ui.notify(
          `Recall failed: ${e?.message ?? e}`,
          "error"
        );
      } finally {
        decRecall();
        refreshBadge();
      }
    }
  });
  pi.registerCommand("remember", {
    description: "Commit something to long-term memory. Usage: `/remember <title>` captures the LAST assistant message; `/remember <title> | <content>` stores explicit content. Pipe is the separator.",
    handler: async (args, ctx) => {
      const raw = (args ?? "").trim();
      if (!raw) {
        ctx.ui.notify(
          "Usage: /remember <title> [| <content>]",
          "warning"
        );
        return;
      }
      const pipeIdx = raw.indexOf("|");
      const title = (pipeIdx >= 0 ? raw.slice(0, pipeIdx) : raw).trim();
      const explicit = pipeIdx >= 0 ? raw.slice(pipeIdx + 1).trim() : "";
      const content = explicit || getLastAssistantText();
      if (!content) {
        ctx.ui.notify(
          "No content to remember (provide '| <content>' or send a turn first).",
          "warning"
        );
        return;
      }
      incRemember();
      refreshBadge();
      try {
        await memoryRequest("POST", "/api/documents", {
          title,
          content,
          id: title,
          source: `pi:///command/${title}`
        });
        ctx.ui.notify(`Remembered: ${title}`, "info");
      } catch (e) {
        ctx.ui.notify(
          `Remember failed: ${e?.message ?? e}`,
          "error"
        );
      } finally {
        decRemember();
        refreshBadge();
      }
    }
  });
}

// src/index.ts
var isSubagent = process.env.PI_SUBAGENT_CHILD === "1";
function index_default(pi) {
  registerRecall(pi);
  registerCatalog(pi);
  registerStatus(pi);
  registerMessageEndFilterHook(pi);
  if (isSubagent) {
    return;
  }
  registerRemember(pi);
  registerForget(pi);
  registerLogAction(pi);
  registerLogDecision(pi);
  registerCommands(pi);
  registerDistillSummaryRenderer(pi);
  registerLifecycleHooks(pi);
  registerBeforeAgentStartHook(pi);
  registerMessageEndCacheHook(pi);
  registerDistillSummaryHook(pi);
  registerDistillHook(pi);
}
export {
  index_default as default
};
//# sourceMappingURL=index.js.map

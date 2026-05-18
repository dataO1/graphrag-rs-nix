// pi-memory — long-term memory extension for the pi coding agent.
//
// Talks to the graphrag-server memory REST backend (port 17180).
// Provides: recall, remember, catalog, forget, status,
// log_action, log_decision tools plus /recall & /remember commands.
// Includes: toolbar badge, stale-context SSE, catalog hints,
// empty-toolCall filtering, end-of-turn distillation.
// ---------------------------------------------------------------------------

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

// Tools
import { registerRecall } from "./tools/recall";
import { registerRemember } from "./tools/remember";
import { registerCatalog } from "./tools/catalog";
import { registerForget } from "./tools/forget";
import { registerStatus } from "./tools/status";
import { registerLogAction } from "./tools/log_action";
import { registerLogDecision } from "./tools/log_decision";

// Kinds: boot-time fetch of /recall/kinds
import { fetchRecallKinds } from "./kinds";

// Hooks
import { registerDistillHook } from "./distill";
import { registerDistillSummaryRenderer, registerDistillSummaryHook } from "./hooks/message_end_distill";
import { registerBeforeAgentStartHook } from "./hooks/before_agent_start";
import { registerMessageEndFilterHook } from "./hooks/message_end_filter";
import { registerMessageEndCacheHook } from "./hooks/message_end_cache";
import { registerLifecycleHooks } from "./hooks/lifecycle";
import { registerCommands } from "./hooks/commands";

// pi-subagents sets PI_SUBAGENT_CHILD=1 when spawning subagent processes.
// Subagents get read-only memory access (recall + catalog + status) and
// NEVER run distillation/logging — the main agent handles all writes.
const isSubagent = process.env.PI_SUBAGENT_CHILD === "1";

export default async function (pi: ExtensionAPI): Promise<void> {
  // ── Boot-time fetch: /recall/kinds ────────────────────────────
  // Must complete before registerRecall() so the tool description
  // includes the TYPE section (if kinds are configured). On failure
  // after retries, kinds fetch logs a warning and we continue with
  // graceful degradation (no type param, no TYPE section).
  await fetchRecallKinds();

  // ── Read tools (available in both main and subagent sessions) ──
  registerRecall(pi);
  registerCatalog(pi);
  registerStatus(pi);

  // ── Crash guard (both main and subagent) ─────────────────────
  // message_end_filter normalises non-array content before Pi's
  // AssistantMessageComponent.updateContent calls .some() on it.
  registerMessageEndFilterHook(pi);

  if (isSubagent) {
    // Subagent: read-only memory, no write tools, no distillation.
    return;
  }

  // ── Main agent only below ────────────────────────────────────

  // Write tools
  registerRemember(pi);
  registerForget(pi);
  registerLogAction(pi);
  registerLogDecision(pi);

  // Commands
  registerCommands(pi);

  // Renderers (register before hooks that consume them)
  registerDistillSummaryRenderer(pi);

  // Hooks (order: lifecycle first, then per-turn)
  registerLifecycleHooks(pi);
  registerBeforeAgentStartHook(pi);
  registerMessageEndCacheHook(pi);
  registerDistillSummaryHook(pi);

  // Distillation (must register after hooks — it uses agent_end)
  registerDistillHook(pi);
}

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

// Hooks
import { registerDistillHook } from "./distill";
import { registerBeforeAgentStartHook } from "./hooks/before_agent_start";
import { registerMessageEndFilterHook } from "./hooks/message_end_filter";
import { registerMessageEndCacheHook } from "./hooks/message_end_cache";
import { registerLifecycleHooks } from "./hooks/lifecycle";
import { registerCommands } from "./hooks/commands";

export default function (pi: ExtensionAPI): void {
  // ── Tools ───────────────────────────────────────────────────
  registerRecall(pi);
  registerRemember(pi);
  registerCatalog(pi);
  registerForget(pi);
  registerStatus(pi);
  registerLogAction(pi);
  registerLogDecision(pi);

  // ── Commands ────────────────────────────────────────────────
  registerCommands(pi);

  // ── Hooks (order: lifecycle first, then per-turn) ───────────
  registerLifecycleHooks(pi);
  registerBeforeAgentStartHook(pi);
  registerMessageEndFilterHook(pi);
  registerMessageEndCacheHook(pi);

  // ── Distillation (must register after hooks — it uses agent_end) ──
  registerDistillHook(pi);
}

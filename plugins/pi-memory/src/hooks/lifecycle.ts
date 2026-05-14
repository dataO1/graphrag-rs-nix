// Lifecycle hooks — session_start, agent_start, session_shutdown.
// Wires up the toolbar widget, health polling, catalog refresh,
// and SSE stale-context stream.
// ---------------------------------------------------------------------------

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

import { HINT_RECALL_ENABLED, STALE_CONTEXT_ENABLED } from "../config";
import { refreshCatalog, startCatalogRefreshTimer, stopCatalogRefreshTimer } from "../catalog";
import { setUi, healthPing, startPollTimer, stopPollTimer, stopAllAnim, refreshBadge } from "../ui";
import { loadMemoryState, restartSseStream, stopSseStream } from "../sse";

export function registerLifecycleHooks(pi: ExtensionAPI): void {
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

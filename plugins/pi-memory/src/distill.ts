// End-of-turn distillation + logging nudge.
//
// Pattern: voice.ts recursion guard (see pi extension authoring docs).
// agent_end fires once per user prompt. We queue a forced follow-up
// turn where the LLM MUST evaluate the previous turn for durable work.
//
// The nudge is sent via pi.sendMessage() with display:false so it
// reaches the LLM context but doesn't render in the TUI chat viewport.
// The LLM's compact reply (".", "logged", "consolidated+logged") flows
// through intact — we never collapse message content (that would orphan
// tool_use/tool_result blocks — pi-mono issue #4189).
// ---------------------------------------------------------------------------

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

export const DISTILL_NUDGE =
  "[memory] Distillation structural check. Higher bar. Ask: 'Did " +
  "this turn produce a finding / decision rationale / architectural " +
  "insight / unexpected behavior fact that (a) a future session " +
  "would genuinely benefit from being able to recall, (b) is NOT " +
  "already covered in an existing entry in the user's recorded " +
  "material, (c) is NOT derivable from current code or git log, " +
  "and (d) is NOT a re-statement of intermediate scratch?' If YES " +
  "— invoke `memory_remember` with an insight-oriented title. " +
  "False-positive distillation noise is worse than missed real " +
  "insights — when in doubt, skip.\n\n" +
  "[memory] Logging structural check. Evaluate this turn (yours + " +
  "any subagents you dispatched). If the turn produced one of: an " +
  "architectural change, a bug fix, a non-trivial documentation " +
  "write or edit (new file, restructured section, distilled " +
  "findings — anything beyond a single-sentence tweak), a research " +
  "finding, a decision taken, an unexpected outcome that changes " +
  "the user's mental model, OR a completed user-facing deliverable " +
  "(new file, code change, config edit) — INCLUDING work done by " +
  "a subagent you dispatched — fire the matching tool BEFORE " +
  "responding:\n" +
  "  • `memory_log_action` for action / change / deliverable / " +
  "finding rows\n" +
  "  • `memory_log_decision` for decision rows (choice between " +
  "alternatives with rationale, including rollout + rollback)\n" +
  "If the turn produced both, fire both tools — one row each. " +
  "Decisions live in the log, NOT as knowledge notes (temporal " +
  "context is load-bearing). Single-sentence tweaks, read-only " +
  "operations (recall/grep/read), and trivial chores (ls, git " +
  "status) do NOT trigger.\n\n" +
  "If nothing triggered: respond with exactly '✓ nothing to distill' (a single " +
  "line, no preamble).\n" +
  "If you called memory_remember: respond with '📝 consolidated: <title>' (use the " +
  "title you passed to memory_remember).\n" +
  "If you called memory_log_action or memory_log_decision: count them and respond " +
  "with '📝 logged: N actions + M decisions' (omit zero counts, e.g. '📝 logged: 1 action').\n" +
  "If you did both: '📝 consolidated: <title> + logged: N actions'.\n" +
  "Keep it to ONE line, no preamble, no follow-up text.";

// ── Recursion guard state ─────────────────────────────────────────
let forcedDistillTurn = false;
let savedDistillThinking: string | undefined;

export function isDistillTurn(): boolean {
  return forcedDistillTurn;
}

export function registerDistillHook(pi: ExtensionAPI): void {
  pi.on("agent_end", async (_event, ctx) => {
    if (forcedDistillTurn) {
      forcedDistillTurn = false;
      if (savedDistillThinking !== undefined) {
        pi.setThinkingLevel(savedDistillThinking);
        savedDistillThinking = undefined;
      }
      return;
    }

    forcedDistillTurn = true;
    savedDistillThinking = pi.getThinkingLevel();
    pi.setThinkingLevel("low");

    // display:false → sent to LLM context, NOT rendered in chat
    pi.sendMessage(
      {
        customType: "memory-distill-nudge",
        content: DISTILL_NUDGE,
        display: false,
      },
      { triggerTurn: true },
    );
  });
}

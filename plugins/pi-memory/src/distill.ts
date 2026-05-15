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
//
// Milestone journal: tool_result hooks detect todo completions and
// subagent finishes, storing lightweight references (id + subject, not
// full content — the LLM already has the results in its KV cache).
// These are injected into the agent_end nudge as a short reminder line
// so the LLM sees "you had these notable events" without re-reading the
// full tool output. Subagent sessions (PI_SUBAGENT_CHILD=1) are fully
// skipped — subagents don't do their own logging.
// ---------------------------------------------------------------------------

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

// ── Milestone journal (lightweight, not full content) ────────────
interface MilestoneEntry {
  type: "todo_completed" | "subagent_finished";
  label: string; // compact one-line description (~10-30 tokens)
}

const pendingMilestones: MilestoneEntry[] = [];

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

// ── Milestone journal (tool_result → agent_end injection) ────────

function recordTodoCompleted(input: Record<string, unknown>): void {
  const subject =
    typeof input.subject === "string"
      ? input.subject
      : typeof input.activeForm === "string"
        ? input.activeForm
        : `#${String(input.id ?? "?")}`;
  pendingMilestones.push({ type: "todo_completed", label: subject });
}

function recordSubagentFinished(input: Record<string, unknown>): void {
  const agent =
    typeof input.agent === "string" ? input.agent : "subagent";
  const task =
    typeof input.task === "string"
      ? input.task.slice(0, 60)
      : "finished";
  pendingMilestones.push({
    type: "subagent_finished",
    label: `${agent}: ${task}`,
  });
}

function buildMilestonePrefix(): string {
  if (pendingMilestones.length === 0) return "";
  const lines = pendingMilestones.map((m) => {
    const icon =
      m.type === "todo_completed" ? "☑" : "⬢";
    return `${icon} ${m.label}`;
  });
  // Clear after reading — each nudge consumes the journal.
  pendingMilestones.length = 0;
  return `[memory] Notable this turn:\n${lines.join("\n")}\n\n`;
}

export function registerDistillHook(pi: ExtensionAPI): void {
  // ── tool_result: journal milestones (lightweight, no full content) ──
  pi.on("tool_result", async (event) => {
    if (event.isError) return;
    const input = event.input as Record<string, unknown>;

    // Todo completed — todo tool from rpiv-todo
    if (
      event.toolName === "todo" &&
      input.action === "update" &&
      input.status === "completed"
    ) {
      recordTodoCompleted(input);
      return;
    }

    // Subagent finished — subagent tool from pi-subagents
    if (event.toolName === "subagent") {
      recordSubagentFinished(input);
      return;
    }
  });

  // ── before_provider_request: system-level distill enforcement ──
  // During the distill follow-up turn, inject a system-prompt-level
  // instruction that forces the one-liner format. Inline nudge text
  // is advisory — models focused on complex work often ignore it.
  // System-prompt-level instructions are much harder to override.
  pi.on("before_provider_request", async (event) => {
    if (!forcedDistillTurn) return;
    const payload = event.payload as Record<string, unknown>;
    const systemInstr =
      "[system] You are in a distillation turn. Your ONLY task is to " +
      "evaluate the previous turn for durable work (actions, decisions, " +
      "findings) and respond with EXACTLY one of:\n" +
      "  • '✓ nothing to distill' (if nothing triggered)\n" +
      "  • '📝 logged: N actions' (if memory_log_action called)\n" +
      "  • '📝 logged: N actions + M decisions' (if both called)\n" +
      "  • '📝 consolidated: <title>' (if memory_remember called)\n" +
      "  • '📝 consolidated: <title> + logged: N actions' (if both)\n" +
      "Do NOT add any other text. Do NOT continue the conversation. " +
      "Do NOT call any tools other than the memory logging/distillation " +
      "tools explicitly listed above. One line only.";

    // Inject into system prompt. Pi's request shape has `system`
    // as a string or array of content blocks — append to it.
    const existing = payload.system;
    if (typeof existing === "string") {
      payload.system = existing + "\n\n" + systemInstr;
    } else if (Array.isArray(existing)) {
      payload.system = [
        ...existing,
        { type: "text", text: systemInstr },
      ];
    } else if (existing === undefined || existing === null) {
      payload.system = systemInstr;
    }
    // Must RETURN the mutated payload — the runner discards in-place
    // mutations. Only handler return values replace the request.
    return payload;
  });

  // ── agent_end: fire the nudge (main agent only — subagents skip via index.ts gate) ──
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

    // Prepend milestone journal (if any) to the standard nudge.
    const prefix = buildMilestonePrefix();
    const nudge = prefix + DISTILL_NUDGE;

    // display:false → sent to LLM context, NOT rendered in chat
    pi.sendMessage(
      {
        customType: "memory-distill-nudge",
        content: nudge,
        display: false,
      },
      { triggerTurn: true },
    );
  });
}

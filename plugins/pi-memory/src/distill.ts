// End-of-turn distillation + logging nudge.
//
// Pattern: voice.ts recursion guard (see pi extension authoring docs).
// agent_end fires once per user prompt. We queue a forced follow-up
// turn where the LLM MUST evaluate the previous turn for durable work.
//
// The trigger is a MINIMAL sendMessage ("[memory] distill" — 5 tokens)
// so the session history stays slim. All criteria live in the ephemeral
// before_provider_request system-prompt injection — never persisted.
// Only the one-liner reply (~5-20 tokens) enters the session JSONL.
//
// Milestone journal: tool_result hooks detect todo completions and
// subagent finishes, storing lightweight references. These are injected
// into the before_provider_request system prompt (not the session).
// Subagent sessions (PI_SUBAGENT_CHILD=1) are fully skipped.
// ---------------------------------------------------------------------------

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

// ── Milestone journal (lightweight, not full content) ────────────
interface MilestoneEntry {
  type: "todo_completed" | "subagent_finished";
  label: string; // compact one-line description (~10-30 tokens)
}

const pendingMilestones: MilestoneEntry[] = [];

export const DISTILL_NUDGE =
  "[memory] distill — evaluate the previous turn for durable work (actions, decisions, findings).";

// ── Distill system-prompt injection (ephemeral — never persisted) ─
// Injected via before_provider_request into the distill turn's system
// prompt. The LLM sees this ONCE per distill turn, at system-prompt
// level. It never enters the session JSONL. Only the one-liner reply
// (~5-20 tokens) persists.
const DISTILL_SYSTEM_INJECTION =
  "[system] You are in a distillation turn. Your ONLY task is to " +
  "evaluate the previous turn for durable work.\n\n" +
  "Distillation (higher bar — only genuine insights):\n" +
  "  Did this turn produce a finding / decision rationale / " +
  "architectural insight / unexpected behavior fact that (a) a " +
  "future session would genuinely benefit from recalling, (b) is " +
  "NOT already recorded, (c) is NOT derivable from code or git " +
  "log, and (d) is NOT a re-statement of scratch?\n" +
  "  If YES → call memory_remember with an insight-oriented title.\n" +
  "  When in doubt, skip. False positives are worse than misses.\n\n" +
  "Logging (session action/decision rows):\n" +
  "  If the turn produced: an architectural change, bug fix, " +
  "non-trivial doc edit, research finding, decision between " +
  "alternatives with rationale, OR a completed user-facing " +
  "deliverable (including work done by dispatched subagents)\n" +
  "  → call memory_log_action (for actions/changes/findings)\n" +
  "  → call memory_log_decision (for choices with rationale)\n" +
  "  Trivial chores (ls, git status) and single-sentence tweaks " +
  "do NOT trigger.\n\n" +
  "Response format — EXACTLY one line, no preamble, no follow-up:\n" +
  "  • '<mem>nothing to distill</mem>' (if nothing triggered)\n" +
  "  • '<mem>logged: N actions</mem>' (if memory_log_action called)\n" +
  "  • '<mem>logged: N actions + M decisions</mem>' (if both called)\n" +
  "  • '<mem>consolidated: <title></mem>' (if memory_remember called)\n" +
  "  • '<mem>consolidated: <title> + logged: N actions</mem>' (if both)\n" +
  "Use the <mem> tag so the main agent can distinguish memory-system " +
  "messages from user input, file contents, and normal conversation. " +
  "Do NOT add any other text. Do NOT continue the conversation. " +
  "Do NOT call any tools other than the memory logging/distillation " +
  "tools. ONE LINE ONLY.";

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

  // ── before_provider_request: ephemeral distill enforcement ──
  // Injects the full criteria into the system prompt of the distill
  // turn. This injection dies with the HTTP request — it never enters
  // the session JSONL. Only the one-liner reply (~5-20 tokens) persists.
  pi.on("before_provider_request", async (event) => {
    if (!forcedDistillTurn) return;
    const payload = event.payload as Record<string, unknown>;

    // Prepend milestone journal (if any) to the system injection.
    const prefix = buildMilestonePrefix();
    const systemInstr = prefix + DISTILL_SYSTEM_INJECTION;

    // Pi's request shape has `system` as a string or array of
    // content blocks — append to it.
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
    // Must RETURN the mutated payload — the runner chains return
    // values, not in-place mutations.
    return payload;
  });

  // ── agent_end: trigger the distill turn (minimal content) ──
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

    // Minimal trigger — 5 tokens. The full criteria are in the
    // ephemeral before_provider_request system-prompt injection.
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

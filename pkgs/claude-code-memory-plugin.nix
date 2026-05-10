{ lib
, runCommand
, writeShellScript
, curl
, jq
, memory-mcp
}:

# Static plugin asset bundle: skills + CLAUDE.md + staleness-check
# helper. Consumed by the `programs.claude-code-memory` home-manager
# module (modules/claude-code.nix), which wires individual paths into
# the upstream `programs.claude-code.*` options instead of going
# through Claude Code's plugin format. We don't ship a `.claude-plugin/`
# manifest, `.mcp.json`, or `hooks/hooks.json` anymore — those were
# needed for the `--plugin-dir` loading path; the upstream module
# handles MCP registration via `--mcp-config` and hooks via
# `~/.claude/settings.json` directly.
#
# Output:
#   $out/skills/<name>/SKILL.md     — pass to programs.claude-code.skills
#   $out/CLAUDE.md                   — pass to programs.claude-code.memory.source
#   passthru.mkStalenessHook { ... } — host-baked UserPromptSubmit script
#
# Host-independent: no MCP URL, no session id, no hooks JSON. The
# home-manager module generates per-host artifacts on top of this.

let
  src = ../plugins/claude-code-memory;

  # Per-host UserPromptSubmit hook builder. Returns a writeShellScript
  # path that can be referenced from `programs.claude-code.settings.hooks.*`.
  # Bakes BASE_URL + SESSION_ID at build time because hooks don't
  # inherit MCP-server env, and the lease bucket must align with the
  # values in `programs.claude-code.mcpServers.memory.env`.
  # Window after the agent edits a vault file during which we
  # treat any staleness alert as self-caused and suppress it.
  # Covers the Obsidian gateway's debounce (~10s) plus comfort.
  selfEditWindowSecs = 60;

  mkStalenessHook = { serverHost, serverPort, sessionId }:
    let
      baseUrl = "http://${serverHost}:${toString serverPort}";
    in
    writeShellScript "claude-memory-staleness" ''
      set -uo pipefail

      BASE_URL='${baseUrl}'
      MEMORY_SESSION_ID='${sessionId}'

      CURL='${curl}/bin/curl'
      JQ='${jq}/bin/jq'

      # Read Claude's hook payload off stdin and extract its
      # per-Claude-session id. Per-session state files are
      # essential for parallel/multi-agent workflows — a single
      # global file races between concurrent sessions and
      # corrupts each other's snapshots and turn flags.
      #
      # `session_id` field has been part of every hook payload
      # since Claude Code's hooks API stabilized; fall back to
      # "unknown" only if absent (e.g. tests piping fake input).
      PAYLOAD="$(cat 2>/dev/null || echo '{}')"
      CC_SESSION_ID="$(printf %s "$PAYLOAD" | "$JQ" -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")"

      STATE_FILE="''${HOME}/.claude/memory-staleness-''${CC_SESSION_ID}.json"
      LOG_BLOCKED_FLAG="''${HOME}/.claude/log-blocked-this-turn-''${CC_SESSION_ID}"
      RECENT_SELF_EDIT="''${HOME}/.claude/recent-self-vault-edit-''${CC_SESSION_ID}"

      # New user prompt = new turn. Clear the per-turn flags so
      # the next Stop / SubagentStop fire for THIS session can
      # issue exactly one nudge each for this turn.
      rm -f "$LOG_BLOCKED_FLAG"
      rm -f "''${HOME}/.claude/subagent-blocked-this-turn-''${CC_SESSION_ID}"

      # Suppress staleness alerts when THIS session has edited a
      # vault file within the last ${toString selfEditWindowSecs}s — the alert is
      # almost certainly self-caused (agent edits the file →
      # Obsidian gateway re-ingests with new etag → server flags
      # the prior cited-block etag as stale). The agent already
      # knows what it just wrote; re-prompting it to recall is
      # noise. Concurrent-session changes still surface (the
      # window only covers self-edits from this very session_id).
      if [ -f "$RECENT_SELF_EDIT" ]; then
        edit_mtime=$(stat -c %Y "$RECENT_SELF_EDIT" 2>/dev/null || echo 0)
        now=$(date +%s)
        age=$((now - edit_mtime))
        if [ "$age" -lt ${toString selfEditWindowSecs} ]; then
          exit 0
        fi
      fi

      # Lease bucket on the server is keyed by MEMORY_SESSION_ID
      # (host-scoped — see modules/claude-code.nix); we don't pass
      # the per-Claude-session id here because the MCP's lease
      # tracking is host-scoped by design.
      response="$("$CURL" -fsS -m 2 "$BASE_URL/lease/check?session_id=$MEMORY_SESSION_ID" 2>/dev/null || true)"
      [ -z "$response" ] && exit 0

      current_stale="$(printf %s "$response" | "$JQ" -c '
        [(.stale // [])[] | {id: .blockId, etag: .etag}] | sort_by(.id, .etag)
      ' 2>/dev/null || echo "[]")"
      current_missing="$(printf %s "$response" | "$JQ" -c '
        [(.missing // [])[]] | sort
      ' 2>/dev/null || echo "[]")"

      mkdir -p "$(dirname "$STATE_FILE")"

      if [ -f "$STATE_FILE" ]; then
        prev_stale="$("$JQ" -c '.stale // []' "$STATE_FILE" 2>/dev/null || echo "[]")"
        prev_missing="$("$JQ" -c '.missing // []' "$STATE_FILE" 2>/dev/null || echo "[]")"
      else
        prev_stale="[]"
        prev_missing="[]"
      fi

      new_stale="$("$JQ" -c --argjson p "$prev_stale" '. - $p' <<<"$current_stale")"
      new_missing="$("$JQ" -c --argjson p "$prev_missing" '. - $p' <<<"$current_missing")"

      "$JQ" -nc --argjson s "$current_stale" --argjson m "$current_missing" \
        '{stale:$s, missing:$m}' >"$STATE_FILE"

      n_stale="$("$JQ" 'length' <<<"$new_stale")"
      n_missing="$("$JQ" 'length' <<<"$new_missing")"

      if [ "$n_stale" = "0" ] && [ "$n_missing" = "0" ]; then
        exit 0
      fi

      {
        printf '[memory] STALENESS: '
        if [ "$n_stale" -gt 0 ]; then printf '%s updated' "$n_stale"; fi
        if [ "$n_stale" -gt 0 ] && [ "$n_missing" -gt 0 ]; then printf ', '; fi
        if [ "$n_missing" -gt 0 ]; then printf '%s removed' "$n_missing"; fi
        printf ' memory entries you previously cited have changed since your last turn. '
        printf 'Material you used earlier may no longer reflect the user'"'"'s current memory. '
        printf 'If your prior reasoning depended on those entries, call `mcp__memory__recall` '
        printf 'again with the relevant question(s) before continuing.\n'
        if [ "$n_stale" -gt 0 ]; then
          printf 'Updated entry ids: '
          "$JQ" -r '[.[].id] | join(", ")' <<<"$new_stale"
        fi
        if [ "$n_missing" -gt 0 ]; then
          printf 'Removed entry ids: '
          "$JQ" -r 'join(", ")' <<<"$new_missing"
        fi
      } | "$JQ" -Rsc '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: .}}'

      exit 0
    '';

  # End-of-turn nudge. Fires on `Stop` (Claude finishes its
  # response and is about to go idle). Uses the documented
  # `{decision: "block", reason: "..."}` mechanism to force the
  # agent to take ONE more turn handling the reason — typically
  # invoking log-session-action and/or consolidate-memory if
  # the just-finished turn produced something log- or
  # distil-worthy.
  #
  # Loop guard: per-Claude-session blocked-once flag. The
  # UserPromptSubmit hook clears the flag at start of each new
  # user turn, so we get exactly one nudge per turn per session.
  # Parallel sessions don't race — the flag path is keyed on the
  # Claude session_id parsed from hook stdin.
  mkStopHook = writeShellScript "claude-memory-stop-nudge" ''
    set -uo pipefail

    JQ='${jq}/bin/jq'

    # Parse session_id off hook stdin so the loop-guard flag is
    # per-session (parallel sessions / multi-agent workflows
    # would race on a single global flag).
    PAYLOAD="$(cat 2>/dev/null || echo '{}')"
    CC_SESSION_ID="$(printf %s "$PAYLOAD" | "$JQ" -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")"

    LOG_BLOCKED_FLAG="''${HOME}/.claude/log-blocked-this-turn-''${CC_SESSION_ID}"

    # Already nudged once this turn? Allow stop normally.
    if [ -e "$LOG_BLOCKED_FLAG" ]; then
      exit 0
    fi

    mkdir -p "$(dirname "$LOG_BLOCKED_FLAG")"
    touch "$LOG_BLOCKED_FLAG"

    # The block reason. Two independent evaluations bundled into
    # one nudge: logging (broad bar) and distillation (high bar).
    # Most turns produce only logging; some produce both; trivial
    # turns produce neither.
    "$JQ" -Rsc '{decision:"block",reason:.}' \
      <<<"Structural checks before stopping."

    exit 0
  '';

  # Subagent-completion nudge. Fires on `SubagentStop` in the
  # PARENT's session (not the subagent's — subagents don't
  # inherit parent settings.json hooks; see Agent Extension
  # Primitives Part 4 "Subagent hook scope"). Same
  # block-and-continue mechanism as Stop, with the block reason
  # phrased for the parent reasoning about the subagent's
  # output.
  #
  # Separate flag file (`subagent-blocked-this-turn-<sid>`) from
  # the Stop-hook flag so a single parent turn can produce up to
  # TWO nudges — once for subagent-completion (parent reasons
  # about subagent's work) and once for parent's own turn-end
  # (parent reasons about its own work). Each is independently
  # one-shot per turn; both cleared by UserPromptSubmit at start
  # of next user turn.
  mkSubagentStopHook = writeShellScript "claude-memory-subagent-stop-nudge" ''
    set -uo pipefail

    JQ='${jq}/bin/jq'

    PAYLOAD="$(cat 2>/dev/null || echo '{}')"
    CC_SESSION_ID="$(printf %s "$PAYLOAD" | "$JQ" -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")"

    SUBAGENT_BLOCKED_FLAG="''${HOME}/.claude/subagent-blocked-this-turn-''${CC_SESSION_ID}"

    if [ -e "$SUBAGENT_BLOCKED_FLAG" ]; then
      exit 0
    fi

    mkdir -p "$(dirname "$SUBAGENT_BLOCKED_FLAG")"
    touch "$SUBAGENT_BLOCKED_FLAG"

    "$JQ" -Rsc '{decision:"block",reason:.}' \
      <<<"Subagent finished — structural checks for its work."

    exit 0
  '';

  # PostToolUse hook for Write/Edit/MultiEdit. Touches a
  # per-Claude-session sentinel file when the touched path is
  # under the vault root. The staleness hook checks the
  # sentinel's mtime and suppresses staleness alerts within
  # `selfEditWindowSecs` after a self-edit (the agent caused
  # the staleness, no point re-alerting it).
  #
  # Wired with matcher "Write|Edit|MultiEdit" in
  # programs.claude-code.settings.hooks.PostToolUse.
  mkPostuseEditTracker = { vaultRoot }:
    writeShellScript "claude-memory-postuse-edit-tracker" ''
      set -uo pipefail

      JQ='${jq}/bin/jq'

      PAYLOAD="$(cat 2>/dev/null || echo '{}')"
      CC_SESSION_ID="$(printf %s "$PAYLOAD" | "$JQ" -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")"
      TOUCHED="$(printf %s "$PAYLOAD" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null || echo "")"

      # Only record vault-root writes; other writes (e.g. dotfiles
      # repo, /tmp) shouldn't suppress staleness for vault-leased
      # blocks.
      case "$TOUCHED" in
        ${vaultRoot}/*)
          mkdir -p "''${HOME}/.claude"
          : > "''${HOME}/.claude/recent-self-vault-edit-''${CC_SESSION_ID}"
          ;;
      esac

      exit 0
    '';
in
runCommand "claude-code-memory-assets"
{
  meta = {
    description = "Static asset bundle for Claude Code's long-term memory feature: skills + CLAUDE.md. Consumed by the programs.claude-code-memory home-manager module.";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
  passthru = {
    inherit mkStalenessHook mkStopHook mkSubagentStopHook mkPostuseEditTracker;
    inherit memory-mcp;
  };
} ''
  mkdir -p "$out"
  cp ${src}/CLAUDE.md "$out/CLAUDE.md"
  cp ${src}/README.md "$out/README.md"
  cp -r ${src}/skills "$out/skills"
''

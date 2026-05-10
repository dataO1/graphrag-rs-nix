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

      # New user prompt = new turn. Clear the Stop-hook's
      # blocked-once flag so the next Stop fire for THIS
      # session can issue exactly one nudge for this turn.
      rm -f "$LOG_BLOCKED_FLAG"

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
    "$JQ" -Rsc '{decision:"block",reason:.}' <<'REASON'
    Before stopping, review the turn you just completed.

    (1) LOGGING — append a session log row?
    Trigger: turn produced an architectural change, bug fix, non-trivial
    documentation update (more than a sentence), research finding,
    decision taken, or unexpected outcome that changes the user's
    mental model.
    If YES — invoke /claude-code-memory:log-session-action with one or
    more rows summarizing what landed. Multiple distinct units of work
    in one turn = multiple rows.
    If NO (read-only / trivial / chore) — skip.

    (2) DISTILLATION — write or update a knowledge note?
    Higher bar. Trigger: turn produced a finding, decision rationale,
    architectural insight, or unexpected behavior fact that:
      - a FUTURE session would genuinely benefit from being able to recall
      - is NOT already covered in an existing vault note (recall first to
        check; if a similar note exists, edit it instead of creating)
      - is NOT derivable from current code or git log
      - is NOT a re-statement of intermediate scratch / rejected hypothesis
    If YES — invoke /claude-code-memory:consolidate-memory.
    If NO — skip.

    These are independent. Most turns produce logging only. Some turns
    produce both. Trivial turns produce neither.

    Don't fabricate either to satisfy this prompt — false-positive
    distillation noise is worse than missed real insights.

    This nudge fires once per turn; you will not be asked again this turn
    regardless of which path(s) you take. After invoking the skill(s) — or
    deciding both paths don't apply — produce a brief acknowledgment and
    stop.
    REASON

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
    inherit mkStalenessHook mkStopHook;
    inherit memory-mcp;
  };
} ''
  mkdir -p "$out"
  cp ${src}/CLAUDE.md "$out/CLAUDE.md"
  cp ${src}/README.md "$out/README.md"
  cp -r ${src}/skills "$out/skills"
''

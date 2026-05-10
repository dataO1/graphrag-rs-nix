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
      SESSION_ID='${sessionId}'
      STATE_FILE="''${HOME}/.claude/memory-staleness.json"

      CURL='${curl}/bin/curl'
      JQ='${jq}/bin/jq'

      # Drain Claude's stdin payload — unused for /lease/check;
      # leaving stdin un-read can confuse the hook host.
      cat >/dev/null 2>&1 || true

      response="$("$CURL" -fsS -m 2 "$BASE_URL/lease/check?session_id=$SESSION_ID" 2>/dev/null || true)"
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
in
runCommand "claude-code-memory-assets"
{
  meta = {
    description = "Static asset bundle for Claude Code's long-term memory feature: skills + CLAUDE.md. Consumed by the programs.claude-code-memory home-manager module.";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
  passthru = {
    inherit mkStalenessHook;
    inherit memory-mcp;
  };
} ''
  mkdir -p "$out"
  cp ${src}/CLAUDE.md "$out/CLAUDE.md"
  cp ${src}/README.md "$out/README.md"
  cp -r ${src}/skills "$out/skills"
''

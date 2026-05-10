{ lib
, runCommand
, writeText
, writeShellScript
, curl
, jq
, coreutils
, memory-mcp
  # Per-host parameters — the resulting plugin output bakes these
  # into hooks/hooks.json, .mcp.json, and bin/staleness-check at
  # build time. Different hosts get different store paths.
  #
  # Names are prefixed `server*` to avoid callPackage auto-resolving
  # `host` against the `bind` package's `host` binary (which provides
  # a top-level attribute named `host` in nixpkgs and silently shadows
  # the default arg). Same precaution for `port`.
, serverHost ? "127.0.0.1"
, serverPort ? 17180
, sessionId ? "claude-default"
}:

let
  baseUrl = "http://${serverHost}:${toString serverPort}";

  # Static plugin source tree (manifest, skills, CLAUDE.md, README).
  # Templates live alongside but aren't copied directly — they're
  # rendered by this derivation.
  src = ../plugins/claude-code-memory;

  # Stdio MCP registration. Plugin scope: Claude Code reads this
  # when --plugin-dir resolves to the plugin output and the plugin
  # is enabled. Command points at the symlinked memory-mcp binary
  # in the plugin's own bin/ for relocatability.
  mcpJson = writeText "mcp.json" (builtins.toJSON {
    mcpServers.memory = {
      type = "stdio";
      command = "${memory-mcp}/bin/memory-mcp";
      args = [ ];
      env = {
        MEMORY_BASE_URL = baseUrl;
        MEMORY_SESSION_ID = sessionId;
      };
    };
  });

  # UserPromptSubmit hook: poll /lease/check, diff against the
  # previous snapshot in ~/.claude/memory-staleness.json, emit
  # only newly-stale / newly-removed transitions as
  # additionalContext. Server-down → silent no-op; this must
  # never block a prompt.
  #
  # Baked: BASE_URL + SESSION_ID at build time. Hooks don't
  # inherit MCP-server env, so the values must match .mcp.json
  # for the lease bucket to align.
  stalenessHook = writeShellScript "claude-memory-staleness" ''
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

  # Plugin-scope hooks. Each event entry is a {matcher, hooks: []}
  # group; the inner {type, command} is the hook spec. Bare
  # {type, command} at the outer level is rejected by Claude
  # Code's schema.
  hooksJson = writeText "hooks.json" (builtins.toJSON {
    UserPromptSubmit = [
      {
        matcher = "";
        hooks = [
          { type = "command"; command = toString stalenessHook; }
        ];
      }
    ];
  });
in
runCommand "claude-code-memory-plugin"
{
  meta = {
    description = "Internal Claude Code plugin: long-term memory MCP, skills, hooks, prompt guidance";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
  passthru = {
    inherit baseUrl sessionId;
    inherit memory-mcp;
  };
} ''
  mkdir -p "$out"

  # Static plugin source: manifest, CLAUDE.md, README, skills/.
  cp -r ${src}/.claude-plugin "$out/.claude-plugin"
  cp ${src}/CLAUDE.md "$out/CLAUDE.md"
  cp ${src}/README.md "$out/README.md"
  cp -r ${src}/skills "$out/skills"

  # Generated: hooks (host-specific URL + session id baked in).
  mkdir -p "$out/hooks"
  cp ${hooksJson} "$out/hooks/hooks.json"

  # Generated: .mcp.json (host-specific URL + session id).
  cp ${mcpJson} "$out/.mcp.json"

  # bin/: symlink to the actual memory-mcp binary so the plugin
  # is relocatable via $out and a single store path captures the
  # whole bundle. The hooks/.mcp.json reference store paths
  # directly, so this is more cosmetic — but useful for inspection.
  mkdir -p "$out/bin"
  ln -s ${memory-mcp}/bin/memory-mcp "$out/bin/memory-mcp"
  ln -s ${stalenessHook} "$out/bin/staleness-check"

  # Sanity: the plugin manifest must parse as JSON.
  ${jq}/bin/jq -e . "$out/.claude-plugin/plugin.json" >/dev/null
  ${jq}/bin/jq -e . "$out/hooks/hooks.json" >/dev/null
  ${jq}/bin/jq -e . "$out/.mcp.json" >/dev/null
''

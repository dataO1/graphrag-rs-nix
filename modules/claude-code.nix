{ self }:
{ config, lib, pkgs, ... }:

# Home-manager module that wires the long-term memory feature into
# the user's existing Claude Code install via the upstream
# `programs.claude-code` module (nix-community/home-manager). We
# don't wrap the binary, don't drop a custom plugin, don't write
# /etc/claude-code/managed-*.json. We just contribute to the
# upstream module's options:
#
#   programs.claude-code.mcpServers.memory  → recall/remember/forget/status MCP
#   programs.claude-code.skills.<name>      → the four memory skills
#   programs.claude-code.context             → ~/.claude/CLAUDE.md
#   programs.claude-code.settings.hooks     → UserPromptSubmit staleness check
#
# Bumping graphrag-rs-nix's flake input rolls the MCP server, hooks,
# skills, and prompt guidance forward in lockstep. Claude Code itself
# is installed by the upstream module — this module just feeds it.
#
# Requires the user to also enable `programs.claude-code.enable` (the
# upstream module). Enforced via assertion.

let
  cfg = config.programs.claude-code-memory;
in
{
  options.programs.claude-code-memory = {
    enable = lib.mkEnableOption "Long-term memory feature for Claude Code (recall / remember / forget / status MCP, session-log skill, multi-hop recall skill, staleness-check hook)";

    serverHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Host where graphrag-server is reachable.";
    };

    serverPort = lib.mkOption {
      type = lib.types.port;
      default = 17180;
      description = "Port for graphrag-server's REST API.";
    };

    sessionLogRoot = lib.mkOption {
      type = lib.types.str;
      description = ''
        Absolute path to the directory under which session log
        files are written
        (`<sessionLogRoot>/<YYYY-MM-DD>/<host>-<agent>-<HHMM>.md`).
        Required — no default; operator must point this at a
        location their knowledge corpus / Obsidian vault sees
        so the long-term memory layer auto-indexes the logs.
        Substituted into the plugin's CLAUDE.md at build time and
        used by the PostToolUse edit-tracker to decide whether a
        write should suppress staleness alerts.
      '';
      example = lib.literalExpression ''"''${config.home.homeDirectory}/Notes/📔 Journal/agent-log"'';
    };

    knowledgeRoot = lib.mkOption {
      type = lib.types.str;
      description = ''
        Absolute path to the directory under which durable
        knowledge notes (distilled findings, decisions,
        architecture notes) are written. Required — no default;
        operator must point this at a location their knowledge
        corpus / Obsidian vault sees so the long-term memory
        layer auto-indexes the notes. Substituted into the
        plugin's CLAUDE.md at build time and used by the
        PostToolUse edit-tracker.
      '';
      example = lib.literalExpression ''"''${config.home.homeDirectory}/Notes/🗂️ Collection"'';
    };
  };

  config = lib.mkIf cfg.enable (
    let
      system = pkgs.stdenv.hostPlatform.system;
      flakePkgs = self.packages.${system};

      memory-mcp = flakePkgs.memory-mcp;

      # Build the plugin asset bundle with operator-configured paths
      # substituted in. Re-built per-host (not reusing
      # flakePkgs.claude-code-memory-plugin) because CLAUDE.md
      # placeholders and the postuse-tracker shell script bake the
      # paths at build time.
      assets = pkgs.callPackage (self + "/pkgs/claude-code-memory-plugin.nix") {
        inherit memory-mcp;
        inherit (cfg) sessionLogRoot knowledgeRoot;
      };

      stalenessHook = assets.passthru.mkStalenessHook {
        inherit (cfg) serverHost serverPort;
      };

      # End-of-turn nudge. Per-session loop-guard via flag file
      # keyed on the Claude session_id parsed from hook stdin —
      # parallel sessions don't race.
      stopHook = assets.passthru.mkStopHook;

      # PostToolUse edit tracker. Touches a per-session sentinel
      # when the agent writes/edits a file under either configured
      # root, so the staleness hook can suppress alerts that are
      # almost-certainly self-caused.
      postuseEditTracker = assets.passthru.mkPostuseEditTracker;
    in
    {
      assertions = [
        {
          assertion = config.programs.claude-code.enable;
          message = ''
            programs.claude-code-memory.enable requires
            programs.claude-code.enable = true (the upstream
            home-manager module that installs Claude Code itself).
          '';
        }
      ];

      # Skills installed via home.file directly (NOT via
      # programs.claude-code.skills / .skillsDir). Reasons:
      #   - .skills.<name> uses `lib.isPath` to decide between
      #     "path-to-dir" and "text content"; interpolated
      #     store-path strings fail the check and get written as
      #     `.md` files containing the literal path string.
      #   - .skillsDir owns the whole ~/.claude/skills directory,
      #     conflicting with users who already wire their own
      #     skills into ~/.claude/skills/ from another source.
      # Per-skill home.file entries are flat, conflict-free, and
      # don't depend on path-vs-string detection. New skills go
      # in the list below alongside the source/skills/<name>/SKILL.md
      # — that's the single source of truth for what ships.
      home.file = lib.listToAttrs (map
        (name: lib.nameValuePair ".claude/skills/${name}" {
          source = "${assets}/skills/${name}";
          recursive = true;
          # `force = true` clobbers any pre-existing entry at the
          # target — most commonly a stale whole-dir symlink left by
          # a previous generation that wired ~/.claude/skills as one
          # directory-level home.file. Without `force` home-manager
          # refuses to overwrite non-symlink-it-owns targets.
          force = true;
        })
        [
          "consolidate-memory"
          "recall-and-think"
          "log-session-action"
        ]);

      programs.claude-code = {
        # 26.05: HM combined `memory.{text,source}` into a single `context`
        # option (lines | path). We pass a store path.
        context = "${assets}/CLAUDE.md";

        mcpServers.memory = {
          type = "stdio";
          command = "${memory-mcp}/bin/memory-mcp";
          args = [ ];
          env = {
            MEMORY_BASE_URL = "http://${cfg.serverHost}:${toString cfg.serverPort}";
            # `log_action` / `log_decision` write into this dir using
            # cwd-derived project + startup-time hostname/HHMMSS to
            # build the per-session filename. Same path the
            # postuse-tracker hook watches for cross-session staleness
            # suppression.
            MEMORY_SESSION_LOG_ROOT = cfg.sessionLogRoot;
            # MEMORY_SESSION_ID intentionally unset — was host-derived
            # and didn't actually identify sessions. The MCP code
            # treats empty as None and omits the field from recall
            # bodies; server's lease tracking falls back to a global
            # bucket. Per-Claude-session diffing happens in the
            # staleness hook against per-session state files.
          };
        };

        # Lifecycle hook bindings live in settings.json. The hook
        # script itself is a writeShellScript path in /nix/store;
        # settings.json references it by absolute path so we don't
        # need to also drop it into ~/.claude/hooks/.
        #
        # Schema gotcha: each event entry must be a {matcher, hooks: []}
        # group, NOT a bare {type, command}. Bare-form gets rejected
        # by Claude Code with "Expected array, but received undefined".
        settings.hooks = {
          UserPromptSubmit = [
            {
              matcher = "";
              hooks = [
                { type = "command"; command = toString stalenessHook; }
              ];
            }
          ];

          # Stop hook: at end-of-turn, force one extra agent turn
          # to evaluate logging + distillation triggers. Loop guard
          # is per-session (the hook script keys flag files on the
          # Claude session_id parsed from stdin).
          Stop = [
            {
              matcher = "";
              hooks = [
                { type = "command"; command = toString stopHook; }
              ];
            }
          ];

          # SubagentStop hook removed (2026-05-12).
          # Under the skills-based fleet design (planner + orchestrator
          # as main-session skills), main-session Stop is sufficient for
          # logging/distillation. SubagentStop was intended to let the
          # parent log on behalf of subagent work, but in practice the
          # double-nudge (SubagentStop fires in parent, then Stop fires
          # in parent for same turn) was redundant with the parent's own
          # Stop nudge. Removing it simplifies the hook surface without
          # losing any logging coverage.

          # PostToolUse edit tracker: records vault-root writes
          # so the staleness hook can suppress self-caused
          # alerts. Filtered to file-mutating tools only — Read
          # / Bash / Glob etc. don't need tracking.
          PostToolUse = [
            {
              matcher = "Write|Edit|MultiEdit";
              hooks = [
                { type = "command"; command = toString postuseEditTracker; }
              ];
            }
          ];
        };
      };
    }
  );
}

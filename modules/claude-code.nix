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
#   programs.claude-code.memory.source      → ~/.claude/CLAUDE.md
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
    enable = lib.mkEnableOption "Long-term memory feature for Claude Code (recall / remember / forget / status MCP, session-log skill, multi-hop recall skill, decision-capture skill, staleness-check hook)";

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

    sessionId = lib.mkOption {
      type = lib.types.str;
      default = "claude-${config.home.username or "default"}";
      defaultText = lib.literalExpression ''"claude-''${config.home.username or "default"}"'';
      description = ''
        Stable per-host session id. Tags every memory call so the
        server's lease table buckets recall material under this
        key, and the matching `/lease/check` endpoint reports which
        leased blocks have since changed. Host-scoped on purpose:
        Claude Code does not expose per-Claude-session ids over
        the stdio MCP protocol, so all Claude sessions on this
        host share one lease bucket.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    let
      system = pkgs.stdenv.hostPlatform.system;
      flakePkgs = self.packages.${system};

      assets = flakePkgs.claude-code-memory-plugin;
      memory-mcp = flakePkgs.memory-mcp;

      stalenessHook = assets.passthru.mkStalenessHook {
        inherit (cfg) serverHost serverPort sessionId;
      };

      # End-of-turn nudge. Per-session loop-guard via flag file
      # keyed on the Claude session_id parsed from hook stdin —
      # parallel sessions don't race.
      stopHook = assets.passthru.mkStopHook;
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
          "document-decision"
          "log-session-action"
        ]);

      programs.claude-code = {
        memory.source = "${assets}/CLAUDE.md";

        mcpServers.memory = {
          type = "stdio";
          command = "${memory-mcp}/bin/memory-mcp";
          args = [ ];
          env = {
            MEMORY_BASE_URL = "http://${cfg.serverHost}:${toString cfg.serverPort}";
            MEMORY_SESSION_ID = cfg.sessionId;
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
        };
      };
    }
  );
}

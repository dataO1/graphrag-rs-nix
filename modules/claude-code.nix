{ self }:
{ config, lib, pkgs, ... }:

# Home-manager module that installs the internal claude-code-memory
# plugin: builds a per-host plugin output (with host-baked .mcp.json
# and hooks/hooks.json), wraps the user's `claude-code` binary so
# every invocation passes `--plugin-dir <store-path>`, and symlinks
# the plugin's CLAUDE.md to ~/.claude/CLAUDE.md (Claude Code's
# plugin format does not support shipping CLAUDE.md to the agent
# layer; the symlink is the workaround).
#
# Coupled to graphrag-rs-nix's memory-mcp package and the static
# plugin source tree at plugins/claude-code-memory/. Bumping the
# graphrag-rs-nix flake input rolls MCP, hooks, skills, and prompt
# guidance forward in lockstep.

let
  cfg = config.programs.claude-code-memory;
in
{
  options.programs.claude-code-memory = {
    enable = lib.mkEnableOption "Internal Claude Code memory plugin";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.claude-code;
      defaultText = lib.literalExpression "pkgs.claude-code";
      description = ''
        The base claude-code package to wrap. Defaults to
        `pkgs.claude-code`. Override to pin a specific version
        (e.g. `pkgs.unstable.claude-code` from a `nixpkgs-unstable`
        input).
      '';
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Host where graphrag-server is reachable.";
    };

    port = lib.mkOption {
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
        key. Host-scoped on purpose — Claude Code does not expose
        per-session ids over the stdio MCP protocol, so all
        sessions on this host share one bucket.
      '';
    };

    installClaudeMd = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Symlink the plugin's CLAUDE.md to ~/.claude/CLAUDE.md.
        Disable if you manage CLAUDE.md elsewhere (e.g. via your
        own home.file). Default true because Claude Code's plugin
        format does not surface plugin-scoped CLAUDE.md to the
        agent layer; the symlink is the workaround.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    let
      system = pkgs.stdenv.hostPlatform.system;
      flakePkgs = self.packages.${system};

      # Per-host plugin output: bakes host/port/sessionId into
      # .mcp.json + hooks/hooks.json + bin/staleness-check.
      plugin = pkgs.callPackage (self + "/pkgs/claude-code-memory-plugin.nix") {
        memory-mcp = flakePkgs.memory-mcp;
        serverHost = cfg.host;
        serverPort = cfg.port;
        sessionId = cfg.sessionId;
      };

      # Wrap claude-code so every invocation auto-loads the plugin.
      # symlinkJoin + makeWrapper would re-derive the whole bin/
      # tree; we only care about `claude`, so a thin script + the
      # rest of cfg.package's bin/ via symlink-out is enough.
      wrapped = pkgs.symlinkJoin {
        name = "claude-code-with-memory";
        paths = [ cfg.package ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          # Wrap every executable in $out/bin with --plugin-dir.
          # Claude Code's binary is typically named `claude`; if the
          # upstream renames it later, this still wraps whatever's
          # there.
          for bin in "$out/bin"/*; do
            if [ -f "$bin" ] || [ -L "$bin" ]; then
              # symlinkJoin produces symlinks; replace with wrapped
              # versions. wrapProgram handles the symlink-target
              # resolution for us.
              wrapProgram "$bin" \
                --add-flags "--plugin-dir ${plugin}"
            fi
          done
        '';
      };
    in
    {
      home.packages = [ wrapped ];

      # CLAUDE.md routing. force=true clobbers Claude Code's own
      # 0-byte placeholder it drops on first launch (without it,
      # home-manager refuses to overwrite a non-symlink target).
      home.file.".claude/CLAUDE.md" = lib.mkIf cfg.installClaudeMd {
        source = "${plugin}/CLAUDE.md";
        force = true;
      };
    }
  );
}

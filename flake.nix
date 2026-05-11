{
  description = "graphrag-rs packaged for NixOS + home-manager, plus `memory-mcp` — a stdio MCP server exposing the user's long-term memory";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    crane.url = "github:ipetkov/crane";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # graphrag-rs source — our fork on the openai-compat branch. The fork
    # carries vendored fixes that used to live in pkgs/graphrag-rs.nix's
    # prePatch (qdrant-client features, /api/config scope-shadow, OLLAMA_PORT,
    # /api/documents resource-merge) plus the new OpenAI-compatible embedding
    # backend. Bump to local path during iteration.
    graphrag-rs-src = {
      # Local iteration on the openai-compat branch. git+file:// instead of
      # path:/ so the 34 GB cargo target/ tree isn't copied into the Nix store
      # on every flake bump — git+file uses only tracked files (target/ is
      # gitignored). Working tree must be committed before each bump.
      # Once pushed to dataO1/graphrag-rs and verified, flip back to:
      #   url = "github:dataO1/graphrag-rs/openai-compat";
      url = "git+file:///home/data01/Projects/graphrag-rs?ref=openai-compat";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, crane, rust-overlay, graphrag-rs-src, ... }:
    let
      systems = [ "x86_64-linux" ];
    in
    {
      homeManagerModules.default = import ./modules/home-manager.nix { inherit self; };
      homeManagerModules.graphrag-rs = self.homeManagerModules.default;

      # Internal Claude Code plugin: long-term memory tools, skills,
      # hooks, prompt guidance. Wraps the user's `claude` binary with
      # --plugin-dir so the plugin loads on every session (Claude Code
      # has no native declarative local-plugin loading mechanism).
      homeManagerModules.claude-code-memory =
        import ./modules/claude-code.nix { inherit self; };

      # System-level NPU embedding service: OVMS container + static-shape
      # model build oneshot. Pair with the home-manager module to point
      # graphrag-server at it (or hit /v3/embeddings directly from any
      # OpenAI-compatible client).
      nixosModules.default = import ./modules/nixos.nix { inherit self; };
      nixosModules.graphrag-rs-npu = self.nixosModules.default;
    }
    // flake-utils.lib.eachSystem systems (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        rustToolchain = pkgs.rust-bin.stable.latest.default;

        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        graphrag-rs = pkgs.callPackage ./pkgs/graphrag-rs.nix {
          inherit craneLib;
          src = graphrag-rs-src;
        };

        memory-mcp = pkgs.callPackage ./pkgs/memory-mcp.nix {
          inherit craneLib;
        };

        knowledge-watcher = pkgs.callPackage ./pkgs/knowledge-watcher.nix {
          inherit craneLib;
        };

        # Smoke-test build of the Claude Code memory plugin — useful
        # for `nix build .#claude-code-memory-plugin` checks. Real
        # consumers go through the home-manager module which threads
        # operator-set paths in. The sessionLogRoot/knowledgeRoot
        # values here are placeholders so the build succeeds; do NOT
        # use this output directly on a host.
        claude-code-memory-plugin = pkgs.callPackage ./pkgs/claude-code-memory-plugin.nix {
          inherit memory-mcp;
          sessionLogRoot = "/SET-VIA-HOME-MANAGER/session-log";
          knowledgeRoot = "/SET-VIA-HOME-MANAGER/knowledge";
        };
      in
      {
        packages = {
          inherit graphrag-rs memory-mcp knowledge-watcher claude-code-memory-plugin;
          graphrag-server = graphrag-rs.server;
          default = graphrag-rs.server;
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ graphrag-rs.server memory-mcp knowledge-watcher ];
          packages = with pkgs; [ nixpkgs-fmt nil rust-analyzer ];
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}

{
  description = "graphrag-rs packaged for NixOS + home-manager, plus `knowledge-mcp` — a stdio MCP server exposing your local knowledge graph";

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
      # Local path during iteration on the path-ingest patch (commit
      # cb1c928 on openai-compat). Once pushed to dataO1/graphrag-rs
      # and verified, flip back to:
      #   url = "github:dataO1/graphrag-rs/openai-compat";
      url = "path:/home/data01/Projects/graphrag-rs";
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

        knowledge-mcp = pkgs.callPackage ./pkgs/knowledge-mcp.nix {
          inherit craneLib;
        };

        knowledge-watcher = pkgs.callPackage ./pkgs/knowledge-watcher.nix {
          inherit craneLib;
        };
      in
      {
        packages = {
          inherit graphrag-rs knowledge-mcp knowledge-watcher;
          graphrag-server = graphrag-rs.server;
          default = graphrag-rs.server;
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ graphrag-rs.server knowledge-mcp knowledge-watcher ];
          packages = with pkgs; [ nixpkgs-fmt nil rust-analyzer ];
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}

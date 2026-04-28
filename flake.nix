{
  description = "graphrag-rs packaged for NixOS + home-manager, with a thin stdio-MCP wrapper";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    crane.url = "github:ipetkov/crane";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Upstream graphrag-rs source. Pinned to main; bump as needed.
    graphrag-rs-src = {
      url = "github:automataIA/graphrag-rs/c46e2872fe7adc40e736981f1bf01dc71d829401";
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

        graphrag-mcp = pkgs.callPackage ./pkgs/graphrag-mcp.nix {
          inherit craneLib;
        };
      in
      {
        packages = {
          inherit graphrag-rs graphrag-mcp;
          graphrag-server = graphrag-rs.server;
          graphrag-cli = graphrag-rs.cli;
          default = graphrag-rs.server;
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ graphrag-rs.server graphrag-mcp ];
          packages = with pkgs; [ nixpkgs-fmt nil rust-analyzer ];
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}

# TODO

Tracked work items for `graphrag-rs-nix`. Tick boxes as you go.

## Build & packaging

- [ ] First successful `nix build .#graphrag-server`. Will likely surface
      missing native deps (the upstream pulls qdrant-client/tonic, lancedb,
      arrow, burn-wgpu transitively). Iterate on `pkgs/graphrag-rs.nix`
      `nativeBuildInputs` / `buildInputs` until clean.
- [ ] First successful `nix build .#graphrag-mcp`.
- [ ] Add `nix flake check` (with build) to a CI workflow once builds pass.
- [ ] Decide whether to expose `graphrag-cli` separately or drop it (it's
      currently built but not wired into the home-manager module).

## Upstream API verification

- [ ] Verify `--config <path>` is the correct flag for `graphrag-server`.
      Currently assumed in `modules/home-manager.nix` ExecStart; check
      `graphrag-server --help` after first build.
- [ ] Confirm REST scope. Wrapper currently targets `/api/{query,documents,
      graph/stats,graph/build}` based on a read of upstream `graphrag-server/
      src/main.rs` at the pinned commit. Re-verify after first run with
      `curl localhost:8910/api/query -d '...'`.
- [ ] Confirm TOML schema. `modules/home-manager.nix` renders sections
      `[server]`, `[embeddings]`, `[llm]`, `[storage]`, `[ingest]` — this is
      a best-guess from workspace deps and the README. Cross-check against
      `config/templates/*.toml` and `graphrag-core/src/config*.rs` post-build
      and adjust option names where they diverge.

## NPU embeddings

- [ ] Decide between two paths to get OVMS-on-NPU embeddings:
  - **Path A**: verify graphrag-rs's `[openai]` backend honors `api_base`
    (grep `graphrag-core` for the OpenAI embedding client). If yes, switch
    `services.graphrag-rs.embeddings.backend = "openai"` and point at OVMS
    `/v3/embeddings` directly.
  - **Path B**: write a ~50 LoC Ollama→OVMS shim translating Ollama's
    `/api/embeddings` request format to OVMS `/v3/embeddings`. Add it as a
    second package in this flake (`pkgs/ollama-ovms-shim.nix`) and a second
    systemd user service in the home-manager module.
- [ ] If Path A: open an upstream PR for `[openai] api_base` if not already
      supported.

## MCP wrapper

- [ ] Real integration test: spawn `graphrag-mcp` from Claude Code's
      `mcp.json`, verify `tools/list` and a roundtrip `query` succeed.
- [ ] Replace ad-hoc JSON-string content with structured `content[]` arrays
      that match what the upstream REST `/api/query` actually returns.
- [ ] Add timeout / retry / friendly error messages on connection refused.
- [ ] Add MCP `resources/` support (expose ingested docs as MCP resources)
      once the basic tool path is verified.

## NixOS module variant

- [ ] Add `modules/nixos.nix` for system-wide deployment (mneme-style)
      if/when we want it to run as a system service rather than per-user.
      Probably not needed: home-manager is the chosen shape.

## Integration into dotfiles

- [ ] Wire as a flake input in `~/.config/.dotfiles/flake.nix`:
      ```nix
      graphrag-rs = {
        url = "git+file:///home/data01/Projects/graphrag-rs-nix";
        inputs.nixpkgs.follows = "nixpkgs";
      };
      ```
- [ ] Import the home-manager module in `user/data01/home.nix` and enable
      `services.graphrag-rs` with `sources = [ "/home/data01/Notes" ]`.
- [ ] Symlink `$XDG_CONFIG_HOME/graphrag-rs/mcp.json` into Claude Code,
      opencode, and crush MCP config locations (or merge by hand — those
      configs live in `user/data01/configs/{claude,opencode,crush}/`).
- [ ] Once stable, switch the input URL to `github:dataO1/graphrag-rs-nix`.

## Documentation

- [ ] Once Path A or B is settled, replace the embedding-backend caveat in
      `README.md` with a concrete recipe.
- [ ] Document `extraConfig` examples (community-detection params,
      reranker, chunking strategy) once the TOML schema is verified.

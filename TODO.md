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

- [x] ~~Verify `--config <path>` flag~~ — **doesn't exist**. graphrag-server
      is env-var driven at startup. Module updated to set
      `EMBEDDING_BACKEND` / `EMBEDDING_DIM` / `OLLAMA_URL` /
      `OLLAMA_EMBEDDING_MODEL` / `QDRANT_URL` / `COLLECTION_NAME` instead.
- [x] ~~Confirm TOML schema~~ — the elaborate `[mode]/[general]/[hybrid.*]`
      schema is the **runtime pipeline config**, POSTed to `/api/config`
      after startup. Module now exposes `pipelineConfig` (nullable
      `tomlFormat.type`) and an opt-in `ExecStartPost` that curls it once
      `/health` is responsive.
- [ ] Confirm REST endpoints under `/api/*` are still correct after the
      first successful build by hitting them with curl. Spot-check return
      shapes against what `graphrag-mcp` assumes.

## Upstream patches needed

- [ ] **Server bind is hardcoded to `0.0.0.0:8080`** in
      `graphrag-server/src/main.rs:1067`. No env var override. Options:
      patch upstream to read `HOST` / `PORT`, vendor a small overlay, or
      run nginx in front and let everyone bind localhost. Until then,
      `services.graphrag-rs.{host,port}` only affect how clients address
      the server, not what it binds to.
- [ ] Server binds publicly (`0.0.0.0`) — for a per-user systemd unit on a
      laptop this is wrong. Bind-address override is the right fix; in the
      meantime the home-manager module should consider firewall guidance
      or socket activation.

## NPU embeddings

- [x] ~~Path A vs B decision~~ — **Path A is dead.** `api_base` literal
      appears 0 times across the entire repo (verified via authenticated
      GitHub code search). graphrag-server's startup `EmbeddingConfig`
      (`graphrag-server/src/embeddings.rs`) only has `ollama_url` /
      `ollama_model` for HTTP-backed embeddings. No way to point the
      OpenAI backend at OVMS without patching.
- [ ] **Write the Ollama→OVMS shim** (Path B). ~50–100 LoC: a HTTP server
      that accepts Ollama's `/api/embeddings` request shape
      (`{model, prompt}` or `{model, input}`) and proxies to OVMS's
      `/v3/embeddings` (OpenAI-compat: `{model, input}` → embeddings array).
      Add as `pkgs/ollama-ovms-shim.nix` + a `crates/ollama-ovms-shim/`
      crate, plus a second systemd user service in the module. Then point
      `services.graphrag-rs.embedding.ollama.url` at the shim's port.

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

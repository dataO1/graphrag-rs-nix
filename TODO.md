# TODO

Tracked work items for `graphrag-rs-nix`. Tick boxes as you go.

## Build & packaging

- [ ] First successful `nix build .#graphrag-server`. Currently failing on
      `qdrant-client v1.15.0`'s build.rs which writes generated test
      snippets back into its own (read-only) vendored crate dir. Worked
      around by `--no-default-features` (drops qdrant-client; server runs
      in in-memory storage fallback). Iterate on `pkgs/graphrag-rs.nix`
      until the workaround sticks; surface other missing native deps as
      they appear.
- [ ] **Re-enable Qdrant**: patch qdrant-client's build.rs so the
      snippet-generation path is a no-op when the source dir isn't
      writable, OR pin qdrant-client back to 1.11.x via a `[patch]` block
      and check whether 1.11 has the same issue. Then drop the
      `--no-default-features` workaround. Without this, embedding vectors
      live in-memory and reset on every server restart.
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
      `graphrag-server/src/main.rs:1067`. No env var override. Patch to
      read `HOST` / `PORT` env vars, default `127.0.0.1:8080`. Vendor via
      `prePatch` like the embedding-endpoint patch. Until then,
      `services.graphrag-rs.{host,port}` only affect how clients address
      the server, and the server is reachable on any interface (firewall
      it externally on multi-user hosts).
- [ ] **Add an `"openai"` backend to graphrag-server's startup
      `EmbeddingService`** (`graphrag-server/src/embeddings.rs` only knows
      `"hash"` and `"ollama"`). New env vars: `OPENAI_URL`,
      `OPENAI_EMBEDDING_MODEL`, `OPENAI_API_KEY`. New branch in
      `EmbeddingService::new` constructing a small reqwest-based OpenAI
      client (~60 LoC). Without this, NPU embeddings only kick in once
      the pipeline config is POSTed; before that the server uses hash
      fallback.

## NPU embeddings

- [x] ~~Path A vs B decision~~ — **Path A revived via vendored patch.**
      `api_base` literal didn't exist upstream, but
      `graphrag-core/src/embeddings/api_providers.rs:46` hardcodes the
      OpenAI URL in a constructor while the underlying `HttpEmbeddingProvider`
      struct already has an `endpoint: String` field. Patch adds
      `endpoint: Option<String>` to `EmbeddingConfig` /
      `EmbeddingProviderConfig` and a `with_endpoint` builder, applied via
      `prePatch` in `pkgs/graphrag-rs.nix`. With the patch, the `[openai]`
      backend can be redirected at any OpenAI-spec server (OVMS, vLLM,
      llama.cpp server) without a shim.
- [x] ~~Write the Ollama→OVMS shim (Path B)~~ — superseded by the patch.
      Keep this option in mind only as a fallback if the patch fails to
      apply against a future upstream rev.
- [ ] **Test the patch end-to-end against a real OVMS instance.** OVMS up
      on `:8000/v3/embeddings`, set `services.graphrag-rs.openaiBackend.enable
      = true`, observe entity extraction + queries hit OVMS in the logs
      (NPU device load).
- [ ] **Convert the substituteInPlace block to a real unified-diff `.patch`
      file** once the patch is verified working. This makes it
      upstream-PR-ready (`git format-patch` from the built derivation tree).
      File at `patches/0001-embedding-config-endpoint-override.patch`,
      consume via `patches = [ ./patches/...patch ];` in
      `pkgs/graphrag-rs.nix` instead of `prePatch`.
- [ ] **Send upstream PR** once the patch works. Two-line abstract:
      "Add `endpoint: Option<String>` to `EmbeddingConfig` /
      `EmbeddingProviderConfig` to allow OpenAI-spec providers to be
      pointed at self-hosted OpenAI-compatible servers (vLLM, OVMS,
      llama.cpp). Existing behavior unchanged when field is `None`."

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

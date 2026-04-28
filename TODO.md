# TODO

Tracked work items for `graphrag-rs-nix`. Tick boxes as you go.

## Build & packaging

- [ ] First successful `nix build .#graphrag-server`. Iterate on
      `pkgs/graphrag-rs.nix` for any further missing native deps.
- [x] ~~Re-enable Qdrant~~ — root cause found: qdrant-client v1.15.0 ships
      `generate-snippets` (its internal CI test-codegen tooling) as a
      DEFAULT feature, and the build.rs gated by that feature writes back
      into its own read-only vendored crate dir. Fixed by patching the
      workspace `Cargo.toml` in `prePatch` to declare qdrant-client with
      `default-features = false, features = ["download_snapshots", "serde"]`.
      All workspace members inherit this via `{ workspace = true }`,
      so generate-snippets is off everywhere; `download_snapshots`
      (snapshot upload/download) and `serde` (Qdrant type ser/de) stay on.
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

- [x] ~~Path A vs B decision~~ → flipped twice. Final answer: **Path B
      (Ollama→OVMS shim) is the only working route.**
- [x] ~~Path A via vendored endpoint patch~~ — **dead code, stripped.**
      Empirical finding 2026-04-28: `HttpEmbeddingProvider` (the struct
      our patch modified) is **not imported anywhere in the runtime
      pipeline**. Only graphrag-core/src/embeddings/api_providers.rs
      itself + examples/ reference it; no `graphrag-server` or
      `graphrag-core` runtime code constructs it. So even with our
      `endpoint: Option<String>` field plumbed through, no code path
      actually uses it for HTTP requests at runtime.
      See README "Upstream dead-code discovery" section for full details.
- [x] ~~api_endpoint field in upstream EmbeddingConfig~~ — **also dead
      code in the runtime path.** `graphrag-core/src/config/mod.rs:974`
      declares it and serialization round-trips it, but nothing reads
      its value to construct an HTTP client. `POST /config { backend:
      "openai", api_endpoint: "..." }` returns 200 but silently falls
      back to hash embeddings.
- [ ] **Write the Ollama→OVMS shim** — only working route to NPU
      embeddings. Spec:
      - Listen on configurable port (default 11435 to avoid Ollama clash).
      - `POST /api/embeddings`: accept `{model, prompt}`, translate to
        OVMS OpenAI-compat `POST /v3/embeddings` body `{model, input}`,
        unwrap response `data[0].embedding` → `{embedding: [...]}`.
      - `GET /api/tags`: return synthetic `{models: [{name: "<model>"}]}`
        so graphrag-server's `Ollama::list_local_models` startup check
        passes. The model name should match `OLLAMA_EMBEDDING_MODEL`.
      - ~80 LoC Rust (axum or actix), reqwest for OVMS upstream.
      - Add as `crates/ollama-ovms-shim/` + `pkgs/ollama-ovms-shim.nix`.
      - Home-manager module: second systemd-user service for the shim,
        `OLLAMA_URL` on graphrag-rs unit pointing at `http://127.0.0.1:11435`.
- [ ] Verify with the shim disabled, just plain Ollama running on neo-16
      with `nomic-embed-text`, that graphrag-server's existing ollama
      backend actually fires HTTP requests at it during ingest. This
      validates that the ollama codepath works at all before we bother
      with the shim.
- [ ] **Once shim is in place, test end-to-end on real OVMS.** Verify:
      ingest a doc, watch shim logs for `/api/embeddings` hits, watch
      OVMS logs for `/v3/embeddings` and NPU device load.

## Upstream patches needed

- [ ] **Server bind is hardcoded to `0.0.0.0:8080`** in
      `graphrag-server/src/main.rs:1067`. No env var override. Patch to
      read `HOST` / `PORT` env vars, default `127.0.0.1:8080`. Vendor via
      `prePatch`. Until then, `services.graphrag-rs.{host,port}` only
      affect how clients address the server, and the server is reachable
      on any interface (firewall externally on multi-user hosts).
- [ ] **Wire HttpEmbeddingProvider into the runtime pipeline** — upstream
      ships an 8-backend embedding system (`graphrag-core/src/embeddings/
      {api_providers,huggingface,ollama}.rs`) but only the `Ollama` and
      `hash-fallback` paths are connected to graphrag-server's
      EmbeddingService. The OpenAI / Voyage / Cohere / Jina / Mistral /
      Together / HuggingFace branches are unreferenced. Big upstream
      contribution, ~200 LoC across graphrag-core + graphrag-server,
      out of scope for this flake. Without it, `EmbeddingConfig.api_endpoint`
      will remain dead code.

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

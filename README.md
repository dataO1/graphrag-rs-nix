# graphrag-rs-nix

Nix flake packaging [automataIA/graphrag-rs](https://github.com/automataIA/graphrag-rs)
for NixOS + home-manager, plus a thin stdio-MCP wrapper (`graphrag-mcp`) that
proxies tool calls to the REST server so any MCP client can drive it.

## Layout

```
.
├── flake.nix
├── pkgs/
│   ├── graphrag-rs.nix        crane build of graphrag-server + graphrag-cli
│   └── graphrag-mcp.nix       crane build of the in-tree MCP wrapper
├── crates/
│   └── graphrag-mcp/          ~250 LoC stdio JSON-RPC → REST proxy
└── modules/
    └── home-manager.nix       services.graphrag-rs systemd-user unit
```

## Usage

In your dotfiles flake:

```nix
inputs.graphrag-rs = {
  url = "git+file:///home/data01/Projects/graphrag-rs-nix";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Then in your home-manager module:

```nix
imports = [ inputs.graphrag-rs.homeManagerModules.default ];

services.graphrag-rs = {
  enable = true;

  # Embedding backend. Upstream wires "hash" (deterministic, no model)
  # and "ollama" (HTTP). For NPU embeddings, use "ollama" with the URL
  # pointed at an Ollama→OVMS shim (TODO).
  embedding = {
    backend = "ollama";
    dimension = 768;
    ollama = {
      url = "http://127.0.0.1:11434";       # real Ollama for now
      model = "nomic-embed-text";
    };
  };

  qdrant = {
    url = "http://127.0.0.1:6334";
    collection = "graphrag";
  };

  # Optional pipeline config — JSON-shaped, matches what /config/default
  # returns. POSTed automatically after /health is up.
  # pipelineConfig = null;
};
```

The MCP wrapper is installed on `PATH` and a sample MCP-client config is
rendered to `$XDG_CONFIG_HOME/graphrag-rs/mcp.json` for symlinking into Claude
Code / opencode / crush.

## Known build limitations

- **No Qdrant** in the current build. `qdrant-client v1.15.0`'s build.rs
  panics in the Nix sandbox (writes test snippets into its read-only
  vendored source). Worked around by building graphrag-server with
  `--no-default-features`, which drops the qdrant-client dependency and
  runs the server in its in-memory storage fallback. Vectors and graph
  state reset on every restart. Re-enabling Qdrant tracked in `TODO.md`.

## Upstream dead-code discovery (2026-04-28)

After end-to-end probing on a freshly built server, several upstream
features turn out to be **aspirational** rather than working:

### `api_endpoint` in the runtime config is dead

`graphrag-core/src/config/mod.rs:974` declares
`pub api_endpoint: Option<String>` on `EmbeddingConfig`. The field is:
- parsed from JSON at line 1720,
- re-serialized for output at lines 2239–2240,
- **never read for any other purpose** (`grep -nE 'api_endpoint' src/`
  shows only those four sites).

`POST /config { embeddings: { backend: "openai", api_endpoint: "..." } }`
returns 200 with `"GraphRAG initialized successfully with custom
configuration"`. But the value is silently dropped before any HTTP
embedding call is made.

### `HttpEmbeddingProvider` is not wired into the runtime pipeline

`graphrag-core/src/embeddings/api_providers.rs` defines
`HttpEmbeddingProvider` with hardcoded URLs for OpenAI / Voyage / Cohere
/ Jina / Mistral / Together. **No file under `graphrag-core/src/` (or
elsewhere in the runtime crates) imports it.** The only references
outside `api_providers.rs` itself are in the `examples/` tree, which
isn't compiled into our build (or any normal cargo build).

Concretely: when the pipeline needs an embedding, the code path runs
through `graphrag-server/src/embeddings.rs::EmbeddingService` which
matches on `config.backend` against `"hash"` and `"ollama"` only. The
`"openai"` branch doesn't exist. Setting `backend = "openai"` falls
through to the hash-based fallback embeddings.

**The 8-backend marketing in upstream README is aspirational; only hash
and ollama are wired end-to-end.**

### Implication for NPU embeddings

Earlier in this repo we vendored a patch ("expose `endpoint:
Option<String>` on `EmbeddingConfig` + `with_endpoint` builder") aimed
at making `HttpEmbeddingProvider` redirectable. Verified empirically
that the patch is **dead code in the runtime path** because nothing
constructs `HttpEmbeddingProvider`. The patch is being stripped (see
`TODO.md` for what replaces it).

The only working route to NPU embeddings is via the `ollama` backend —
graphrag-server already has it wired through `ollama-rs`. We need an
**Ollama→OVMS shim** that translates Ollama's `/api/embeddings` request
shape (`{model, prompt}` → `{embedding}`) to OVMS's OpenAI-compatible
`/v3/embeddings` (`{model, input}` → `{data:[{embedding}]}`), plus a
mock `/api/tags` for graphrag-server's `list_local_models` startup
check. Tracked in `TODO.md`.

### `/api/config` was unreachable due to actix-web scope shadowing

Upstream registered `web::scope("/api/config")` AFTER the apistos
`scope("/api")`. actix-web matches services in registration order, so
`/api/config` requests were caught by `/api` first (which has no
`/config` sub-route) and 404'd. Three things are tangled here:

1. The two scopes can't be nested: `/api` is apistos-typed (requires
   `PathItemDefinition` on every handler, supplied by `#[api_operation]`),
   while `/api/config` was plain actix.
2. Plain actix services can't be registered before apistos's `.build()`.
3. Reordering to put `/api/config` first hits both of those constraints.

Fix: rename the prefix from `/api/config` to `/config`. No overlap with
`/api`, no shadowing, block stays plain actix post-`.build()`. All
config endpoints (`/config[, /default, /template, /validate]`) now
respond. The home-manager module's `ExecStartPost` POSTs to `/config`
with the JSON-converted pipeline config.

## Reality vs. earlier assumptions

After reading upstream source (verified at the pinned commit):

- **`graphrag-server` is env-var driven at startup**, not file-driven. There is
  no `--config` CLI flag. Vars: `EMBEDDING_BACKEND`, `EMBEDDING_DIM`,
  `OLLAMA_URL`, `OLLAMA_EMBEDDING_MODEL`, `QDRANT_URL`, `COLLECTION_NAME`,
  `JWT_SECRET`. The home-manager module sets these.
- **Bind is hardcoded to `0.0.0.0:8080`** (`graphrag-server/src/main.rs:1067`).
  `services.graphrag-rs.{host,port}` only control how clients address the
  server, not what it binds to. Patch upstream if you need flexibility.
- **The elaborate `[mode] / [general] / [hybrid.*]` TOML schema is the
  runtime pipeline config**, uploaded via `POST /api/config` after the
  server is up. Set `services.graphrag-rs.pipelineConfig` and an
  `ExecStartPost` will POST it for you (curl with retry).
- **`api_base` was not a thing in upstream** — `graphrag-core/src/embeddings/api_providers.rs:46` hardcodes `"https://api.openai.com/v1/embeddings"` in the OpenAI constructor with no config-level override. **This flake ships a vendored patch** (`pkgs/graphrag-rs.nix` `prePatch` block) that adds `endpoint: Option<String>` to `EmbeddingConfig` and a `with_endpoint` builder, plumbed end-to-end. With the patch, pointing the `[openai]` backend at OVMS's `/v3/embeddings` works directly — no shim required. The patch is additive and suitable for upstream PR.

## NPU embedding flow with the patch

Two paths exist; the patch only fixes one of them:

| Path                    | Recognized backends                | OVMS works? |
| ----------------------- | ---------------------------------- | ----------- |
| Server startup (env vars: `EMBEDDING_BACKEND`) | `"hash"`, `"ollama"`           | ❌ openai not recognized at startup |
| Pipeline config (`POST /api/config`)            | full set incl. `"openai"` + patched `endpoint` | ✅ patched `endpoint` honored |

So the recipe is:
1. Start `graphrag-server` with `EMBEDDING_BACKEND=hash` (the bootstrap).
2. POST a pipeline TOML containing `[embeddings] provider = "openai"`, `endpoint = "http://ovms:port/v3/embeddings"`. The home-manager module's `openaiBackend.enable = true` synthesizes this and the `ExecStartPost` hook curls it once `/health` is up.
3. From that point on, all pipeline ops (entity extraction, graph build, queries) hit OVMS — i.e. the NPU.

Adding `"openai"` to the *startup* path too is a TODO (see `TODO.md` "Upstream patches needed").

## Pinning

Upstream is pinned in `flake.nix` via the `graphrag-rs-src` input. Bump the
rev there to update.

## TODO

See [TODO.md](./TODO.md).

## Development

This repo ships a `.envrc` for `nix-direnv`. Run `direnv allow` once and the
flake's `devShell` (rust toolchain, formatter, language server) loads on
`cd`.

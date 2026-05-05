# graphrag-rs-nix

Nix flake packaging [automataIA/graphrag-rs](https://github.com/automataIA/graphrag-rs)
for NixOS + home-manager, plus **`knowledge-mcp`** — a stdio MCP server that
exposes the running graphrag-rs instance as a small set of verb-named tools
(`recall`, `remember`, `forget`, `catalog`, `status`) so any MCP client can
drive it as a local knowledge graph.

## Layout

```
.
├── flake.nix
├── pkgs/
│   ├── graphrag-rs.nix        crane build of graphrag-server + graphrag-cli
│   └── knowledge-mcp.nix      crane build of the in-tree MCP server
├── crates/
│   └── knowledge-mcp/         stdio JSON-RPC → REST proxy
└── modules/
    ├── home-manager.nix       services.graphrag-rs (user) — graphrag-server
    └── nixos.nix              services.graphrag-rs-npu (system) — OVMS + NPU
```

## Architecture

Two-module split:

- **`services.graphrag-rs-npu`** (NixOS system) — provides NPU-backed
  embeddings via OpenVINO Model Server. Builds a static-shape embedding
  model on first boot (rootful podman + optimum-cli + openvino-tokenizers
  + Mediapipe graph), then serves on `127.0.0.1:8000/v3/embeddings`
  (OpenAI-compatible). Distilled from the in-house `mneme` flake. Self-
  contained; doesn't depend on mneme.

- **`services.graphrag-rs`** (home-manager user) — runs `graphrag-server`
  as a systemd-user unit. Talks to a Qdrant instance for vector storage
  and to an Ollama-protocol embedding endpoint. The Ollama→OVMS shim
  bridging the two is TODO; until it lands, point `embedding.ollama.{url,
  port,model}` at a real Ollama instance for CPU/GPU embeddings as a
  bootstrapping smoke test.

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

# NixOS configuration (system)
services.graphrag-rs-npu = {
  enable = true;
  embeddingModel = "mixedbread-ai/mxbai-embed-large-v1";   # 1024-dim, 512 ctx
  embeddingMaxSeqLen = 512;
  embeddingPooling = "CLS";
  embeddingDevice = "NPU";
};

# home-manager configuration (user)
services.graphrag-rs = {
  enable = true;

  # Embedding backend. Upstream wires "hash" (deterministic, no model)
  # and "ollama" (HTTP). For NPU embeddings, use "ollama" with the URL
  # pointed at an Ollama→OVMS shim (TODO).
  embedding = {
    backend = "ollama";
    dimension = 768;                        # MUST match what the model returns
    ollama = {
      url = "http://127.0.0.1";
      port = 11434;                         # real Ollama; switch to shim port later
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

The MCP server (`knowledge-mcp`) is installed on `PATH` and a sample
MCP-client config is rendered to `$XDG_CONFIG_HOME/knowledge-mcp/mcp.json`
for symlinking into Claude Code / opencode / crush. The five tools it
exposes:

| Tool | What it does |
|---|---|
| `recall(question, mode?, reason?)` | ask the graph; modes: `default`, `thorough`, `local`, `simple` |
| `remember(path \| paths_glob \| paths \| content+title)` | save doc(s); prefer path-forms |
| `forget(id)` | drop a document |
| `catalog()` | list ingested docs |
| `status()` | counts + lastBuiltAt |

Entity extraction is auto-coalesced server-side: graphrag-server
spawns a background tokio task that wakes on every successful
ingest, debounces `autoAppendDebounceSecs` of silence (default 60),
and folds the new chunks into the entity graph in-process. A
folder-ingest of 200 files lands as one append; a single doc
becomes graph-queryable in ~1 min. There's no `append_graph` or
`build_graph` to call by hand — `remember` something and `recall`
sees it shortly after.

## History-aware retrieval

Re-ingesting a doc with the same `user_id` (path-form ingest
defaults `user_id = absolute path`) doesn't delete anything. The
server marks the prior version's chunks `is_current = false` and
writes new chunks at `version + 1`. Default `recall` filters to
`is_current = true` so top-K is never polluted by superseded
versions; opt in to history with two optional `recall` params:

| param | type | default | semantics |
|---|---|---|---|
| `as_of` | RFC 3339 | unset | only consider chunks updated at or after this time |
| `max_versions_per_doc` | int | `1` | per source doc, how many recent versions to consider |

"What changed in my SEMLA notes since yesterday?" → agent passes
`as_of: "2026-05-04T00:00:00Z"`. "How did the roadmap evolve?" →
`max_versions_per_doc: 5`. No new tools.

## Filesystem watcher

Optional sidecar (`services.graphrag-rs.watcher.enable = true`)
that keeps the local knowledge graph synced with a set of root
directories — initial walk on startup + live debounced ingest on
every editor save. Built on `notify-debouncer-full` (handles
Vim/VSCode/Obsidian atomic-rename correctly) and BurntSushi's
`ignore` crate (same gitignore engine ripgrep uses; respects
`.gitignore`/`~/.gitignore_global`/hidden-file rules).

Stable doc id = absolute path → server's upsert-by-user_id flow
handles edits cleanly. Defaults reuse
`services.graphrag-rs.ingest.{allowedRoots,allowedExtensions}` so
the watcher and the path-ingest sandbox always agree about scope.

```nix
services.graphrag-rs.watcher = {
  enable = true;
  # watchPaths = cfg.ingest.allowedRoots;   # default
  # debounceMs = 300;                        # default
  # initialIndex = true;                     # default
  # maxInFlight = 4;                         # default
};
```

## Path-based ingestion

`POST /api/documents` accepts four body shapes; pick whichever the
agent has cheapest:

| Body | When |
|---|---|
| `{ "path": "/abs/file.md" }` | one file already on disk |
| `{ "paths": ["/a", "/b"] }` | known list of files |
| `{ "pathsGlob": "**/*.md", "globRoot": "/abs/dir" }` | folder walk |
| `{ "title": "...", "content": "..." }` | inline / generated text |

Path-form requests save the agent from inlining the file into its
own context — the server reads off disk, sandboxes, dedups, embeds.
Multi-path requests come back with a `results` array of per-path
`{path, status, document_id?, error?}` entries (`status` ∈ `ingested`,
`duplicate`, `unsupported`, `rejected`, `error`).

Sandbox is **canonicalize + starts_with** against
`services.graphrag-rs.ingest.allowedRoots`. Empty (the default) keeps
path-ingest disabled — the server will 403 path-form requests until
you opt in. Symlinks are rejected by default; size cap is 16 MiB.

Non-text formats (pdf, docx, png, mp3, mp4, …) route through the
optional preprocessor service — see [TODO.md](./TODO.md) §
"Multimodal preprocessor (Nemotron-3-Nano-Omni)" for the planned
implementation. Until that lands, non-text files are reported as
`unsupported` and skipped.

```nix
services.graphrag-rs = {
  ingest = {
    allowedRoots = [ "/home/data01/notes" "/home/data01/Documents" ];
    # maxFileBytes = 16 * 1024 * 1024;   # default
    # allowedExtensions = [ "md" "txt" "rs" /* … */ ];   # rich default
    # preprocessorUrl = "http://127.0.0.1:9100/preprocess";   # null by default
    # followSymlinks = false;
  };
};
```

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

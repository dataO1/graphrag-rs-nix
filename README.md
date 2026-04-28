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

  # Startup backend (env-var driven). Upstream graphrag-server only knows
  # "hash" and "ollama" at startup; OpenAI/OVMS kicks in via openaiBackend
  # below (POSTed pipeline config).
  embedding = {
    backend = "hash";   # or "ollama" if you have Ollama running
    dimension = 1024;
  };

  # NPU embeddings via OpenVINO Model Server.
  # Relies on the vendored patch in pkgs/graphrag-rs.nix that adds
  # `endpoint` to graphrag-core's EmbeddingConfig.
  openaiBackend = {
    enable = true;
    apiBase = "http://127.0.0.1:8000/v3/embeddings";
    model = "Qwen3-Embedding-0.6B";
    dimensions = 1024;
  };

  qdrant = {
    url = "http://127.0.0.1:6334";
    collection = "graphrag";
  };
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

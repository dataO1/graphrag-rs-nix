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

  embedding = {
    backend = "ollama";              # see embedding-backend caveat below
    dimension = 768;
    ollama = {
      url = "http://127.0.0.1:11434"; # TODO: point at the Ollama→OVMS shim
      model = "nomic-embed-text";
    };
  };

  qdrant = {
    url = "http://127.0.0.1:6334";
    collection = "graphrag";
  };

  # Optional: full pipeline config POSTed to /api/config on startup.
  # Schema: [mode] / [general] / [hybrid.*] etc. Set null to skip.
  pipelineConfig = null;
};
```

The MCP wrapper is installed on `PATH` and a sample MCP-client config is
rendered to `$XDG_CONFIG_HOME/graphrag-rs/mcp.json` for symlinking into Claude
Code / opencode / crush.

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
- **`api_base` is not a thing in upstream** — there is no way to point the
  `[openai]` backend at OVMS directly. NPU embeddings require a tiny
  Ollama→OVMS shim translating Ollama's `/api/embeddings` request format
  to OVMS's OpenAI-compat `/v3/embeddings` (still TODO).

## Pinning

Upstream is pinned in `flake.nix` via the `graphrag-rs-src` input. Bump the
rev there to update.

## TODO

See [TODO.md](./TODO.md).

## Development

This repo ships a `.envrc` for `nix-direnv`. Run `direnv allow` once and the
flake's `devShell` (rust toolchain, formatter, language server) loads on
`cd`.

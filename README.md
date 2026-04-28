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
  sources = [ "/home/data01/Notes" ];

  embeddings = {
    backend = "ollama";              # see embedding-backend caveat below
    model = "Qwen3-Embedding-0.6B";
    ollama = {
      host = "http://127.0.0.1";
      port = 8000;                   # OVMS, fronted by an Ollama→OVMS shim
    };
  };

  llm = {
    backend = "ollama";
    model = "llama3.1:8b";
  };
};
```

The MCP wrapper is installed on `PATH` and a sample MCP-client config is
rendered to `$XDG_CONFIG_HOME/graphrag-rs/mcp.json` for symlinking into Claude
Code / opencode / crush.

## Embedding backend caveat

graphrag-rs's `[ollama]` block has explicit `host`/`port`; the `[openai]`
backend's `api_base` support is currently **unverified** in source. The
default config uses the Ollama backend pointed at a (TODO) Ollama→OVMS shim
that translates Ollama's `/api/embeddings` request format to OVMS's
OpenAI-compatible `/v3/embeddings`. Switch to the `openai` backend once
upstream `api_base` support is confirmed.

## Pinning

Upstream is pinned in `flake.nix` via the `graphrag-rs-src` input. Bump the
rev there to update.

## TODO

See [TODO.md](./TODO.md).

## Development

This repo ships a `.envrc` for `nix-direnv`. Run `direnv allow` once and the
flake's `devShell` (rust toolchain, formatter, language server) loads on
`cd`.

{ lib
, stdenv
, craneLib
, src
, pkg-config
, openssl
, protobuf
, cmake
, perl
}:

# graphrag-rs (server + cli) built from our `dataO1/graphrag-rs` fork on
# the `openai-compat` branch. The fork carries everything that used to be
# vendored as `prePatch` substitutions in this file:
#
#   - qdrant-client `default-features = false` (avoids the build.rs
#     `generate-snippets` panic in the Nix sandbox)
#   - graphrag-server's /api/config moved to /config to escape actix-web
#     scope shadowing
#   - OLLAMA_PORT env var support
#   - /api/documents resource("") doubled-registration fix (was 405 POST)
#   - new OpenAI-compatible embedding backend (vLLM / OVMS / llama.cpp /
#     real OpenAI) via OPENAI_URL / OPENAI_EMBEDDING_MODEL / OPENAI_API_KEY
#
# All as proper commits, not substituteInPlace tricks. To bump the fork:
# update graphrag-rs-src in the flake and rebuild.

let
  commonArgs = {
    inherit src;
    pname = "graphrag-rs";
    version = "0.1.0";
    strictDeps = true;

    nativeBuildInputs = [ pkg-config protobuf cmake perl ];
    buildInputs = [ openssl ];

    PROTOC = "${protobuf}/bin/protoc";
    OPENSSL_NO_VENDOR = "1";

    # `--features ollama` enables ollama-rs in graphrag-server. Without it
    # graphrag-server logs "Ollama support not compiled in" when
    # EMBEDDING_BACKEND=ollama and falls back to hash. The new openai
    # backend is unconditional (reqwest is always compiled in).
    cargoExtraArgs = "--locked -p graphrag-server -p graphrag-cli --features graphrag-server/ollama";

    doCheck = false;
  };

  cargoArtifacts = craneLib.buildDepsOnly commonArgs;

  workspace = craneLib.buildPackage (commonArgs // {
    inherit cargoArtifacts;
  });

  server = workspace.overrideAttrs (_: { pname = "graphrag-server"; meta.mainProgram = "graphrag-server"; });
  cli = workspace.overrideAttrs (_: { pname = "graphrag-cli"; meta.mainProgram = "graphrag-cli"; });
in
workspace // {
  inherit server cli;

  meta = {
    description = "Rust GraphRAG implementation (server + CLI), built from dataO1/graphrag-rs:openai-compat fork (vendored fixes + OpenAI-compat embedding backend)";
    homepage = "https://github.com/dataO1/graphrag-rs/tree/openai-compat";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    maintainers = [ ];
  };
}

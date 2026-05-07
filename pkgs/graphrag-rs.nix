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

    # Iteration-tuned overrides for the workspace Cargo.toml's
    # [profile.release] block. cgu=16 lets the LLVM backend parallelise
    # codegen across CPUs (the previous cgu=1 + default ld combination
    # left one CPU pinned at the end of every build); lto=off skips the
    # cross-crate optimization pass that's the next-biggest single-thread
    # tail. Trade is ~10–15% runtime CPU perf on hot paths — negligible
    # for an I/O-bound HTTP server (qdrant + LLM + embeddings dominate
    # any extraction workload). Switch back to lto="thin" / cgu=1 here
    # before a release benchmark if pure-CPU perf is being measured.
    #
    # Mold linker was tried (-C link-arg=-fuse-ld=mold) and dropped: the
    # nixpkgs cc-wrapper's RPATH injection didn't survive the mold link
    # path, producing a binary with empty DT_RPATH that failed at startup
    # with "libssl.so.3: cannot open shared object file". Default ld
    # remains until that's investigated separately.
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
    CARGO_PROFILE_RELEASE_LTO = "off";

    # Enable both LLM/embedding backends in the same build so users can
    # switch at runtime via config.{ollama,openai}.enabled and
    # EMBEDDING_BACKEND=ollama|openai|hash. Mirrors the upstream
    # `ollama` feature pattern; `openai` was added on the openai-compat
    # branch and gates the OpenAIClient + ChatClient::OpenAI dispatch
    # arm + EmbeddingService's openai branch.
    cargoExtraArgs = "--locked -p graphrag-server --features graphrag-server/ollama,graphrag-server/openai";

    doCheck = false;
  };

  cargoArtifacts = craneLib.buildDepsOnly commonArgs;

  workspace = craneLib.buildPackage (commonArgs // {
    inherit cargoArtifacts;
  });

  server = workspace.overrideAttrs (_: { pname = "graphrag-server"; meta.mainProgram = "graphrag-server"; });
in
workspace // {
  inherit server;

  meta = {
    description = "Rust GraphRAG REST server, built from dataO1/graphrag-rs:openai-compat fork (LightRAG dual-level retrieval + OpenAI-compat backends)";
    homepage = "https://github.com/dataO1/graphrag-rs/tree/openai-compat";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    maintainers = [ ];
  };
}

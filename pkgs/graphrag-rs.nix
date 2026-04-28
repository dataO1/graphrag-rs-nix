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

let
  # Manifest-only patches. These run during BOTH buildDepsOnly (which only
  # ships Cargo.toml/Cargo.lock + dummy main.rs files) AND the full build,
  # because they need to land before vendoring. So they may not touch
  # anything under graphrag-*/src/**.
  manifestPatchScript = ''
    # qdrant-client v1.15.0 ships `generate-snippets` as a DEFAULT feature
    # (Cargo.toml:34). That feature's build.rs writes generated tests into
    # its own crate source dir — read-only in the Nix sandbox, so the
    # build panics with PermissionDenied. The feature is qdrant maintainers'
    # internal CI tooling; consumers don't need it. Disable workspace-wide;
    # all members inherit via `qdrant-client = { workspace = true, ... }`.
    substituteInPlace Cargo.toml \
      --replace-fail \
        'qdrant-client = "1.11"' \
        'qdrant-client = { version = "1.11", default-features = false, features = ["download_snapshots", "serde"] }'
  '';

  # Source-tree patches. These run ONLY in the full build (buildPackage)
  # because they touch Rust source files that don't exist in crane's
  # deps-only minimal source.
  #
  # Note: an earlier revision of this flake also vendored an "expose
  # endpoint: Option<String> on EmbeddingConfig" patch to redirect the
  # OpenAI-spec providers at OVMS. That patch was stripped after we
  # discovered HttpEmbeddingProvider is not actually wired into the
  # runtime pipeline upstream — only graphrag-server/src/embeddings.rs's
  # hash + ollama branches handle real embeddings. See README's
  # "Upstream dead-code discovery" section. The path to NPU embeddings
  # is via the ollama backend pointed at an Ollama→OVMS shim (TODO.md).
  sourcePatchScript = ''
    # Add OLLAMA_PORT env var support to graphrag-server's startup config.
    # Upstream hardcodes `Ollama::new(config.ollama_url.clone(), 11434)` —
    # makes it impossible to point graphrag-server at an Ollama-protocol
    # server on any other port (real Ollama on 11434 + our future
    # Ollama→OVMS shim on a different port can't both coexist otherwise).
    substituteInPlace graphrag-server/src/main.rs \
      --replace-fail \
            "ollama_model: std::env::var(\"OLLAMA_EMBEDDING_MODEL\")
                .unwrap_or_else(|_| \"nomic-embed-text\".to_string())," \
            "ollama_model: std::env::var(\"OLLAMA_EMBEDDING_MODEL\")
                .unwrap_or_else(|_| \"nomic-embed-text\".to_string()),
            ollama_port: std::env::var(\"OLLAMA_PORT\")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(11434),"

    substituteInPlace graphrag-server/src/embeddings.rs \
      --replace-fail \
        "    pub ollama_url: String,
" \
        "    pub ollama_url: String,
    pub ollama_port: u16,
"

    substituteInPlace graphrag-server/src/embeddings.rs \
      --replace-fail \
        "let ollama = Ollama::new(config.ollama_url.clone(), 11434);" \
        "let ollama = Ollama::new(config.ollama_url.clone(), config.ollama_port);"

    substituteInPlace graphrag-server/src/embeddings.rs \
      --replace-fail \
        "            backend: \"hash\".to_string()," \
        "            backend: \"hash\".to_string(),
            ollama_port: 11434,"

    substituteInPlace graphrag-server/src/embeddings.rs \
      --replace-fail \
        "            backend: \"ollama\".to_string()," \
        "            backend: \"ollama\".to_string(),
            ollama_port: 11434,"

    # Fix doubled `resource("")` registration in /api/documents scope.
    # Upstream does:
    #     .service(resource("").route(get().to(list_documents)))
    #     .service(resource("").route(post().to(add_document)))
    # actix-web treats each .service(resource(""))... as a separate resource
    # at the same path. The first one wins; the second is silently dropped,
    # so POST /api/documents returns 405 with `allow: GET`. Merge into one
    # resource with chained .route() calls.
    substituteInPlace graphrag-server/src/main.rs \
      --replace-fail \
        "                        scope(\"/documents\")
                            .service(resource(\"\").route(get().to(list_documents)))
                            .service(resource(\"\").route(post().to(add_document)))
                            .service(resource(\"/{id}\").route(delete().to(delete_document)))" \
        "                        scope(\"/documents\")
                            .service(resource(\"\")
                                .route(get().to(list_documents))
                                .route(post().to(add_document)))
                            .service(resource(\"/{id}\").route(delete().to(delete_document)))"

    # Fix actix-web scope shadowing: upstream registers `web::scope("/api/config")`
    # AFTER the apistos `scope("/api")` and AFTER `.build()`, so /api/config
    # requests are caught by the broader /api scope first (which has no /config
    # sub-route) and 404. apistos's App refuses plain `web::scope` services
    # pre-build(), and apistos's typed `scope`/`route` requires handlers to
    # implement `PathItemDefinition` (i.e. carry `#[api_operation]`).
    #
    # Simplest fix: don't put it under /api at all. Change the prefix to
    # just /config. No overlap with /api, no shadowing. Block stays
    # post-`.build()` as plain actix. Clients target /config/* instead of
    # /api/config/*.
    substituteInPlace graphrag-server/src/main.rs \
      --replace-fail \
        "            .service(
                web::scope(\"/api/config\")
                    .route(\"\", web::get().to(config_endpoints::get_config))
                    .route(\"\", web::post().to(config_endpoints::set_config))
                    .route(\"/template\", web::get().to(config_endpoints::get_config_template))
                    .route(\"/default\", web::get().to(config_endpoints::get_default_config))
                    .route(\"/validate\", web::post().to(config_endpoints::validate_config))
            )" \
        "            .service(
                web::scope(\"/config\")
                    .route(\"\", web::get().to(config_endpoints::get_config))
                    .route(\"\", web::post().to(config_endpoints::set_config))
                    .route(\"/template\", web::get().to(config_endpoints::get_config_template))
                    .route(\"/default\", web::get().to(config_endpoints::get_default_config))
                    .route(\"/validate\", web::post().to(config_endpoints::validate_config))
            )"
  '';

  commonArgs = {
    inherit src;
    pname = "graphrag-rs";
    version = "0.1.0";
    strictDeps = true;

    nativeBuildInputs = [ pkg-config protobuf cmake perl ];
    buildInputs = [ openssl ];

    PROTOC = "${protobuf}/bin/protoc";
    OPENSSL_NO_VENDOR = "1";

    # `--features ollama` enables ollama-rs in graphrag-server; without it
    # the ollama backend's logic is conditionally compiled out and the
    # server logs "Ollama support not compiled in. Using fallback embeddings."
    cargoExtraArgs = "--locked -p graphrag-server -p graphrag-cli --features graphrag-server/ollama";

    doCheck = false;

    # Manifest patch only — runs in both buildDepsOnly and buildPackage.
    prePatch = manifestPatchScript;
  };

  cargoArtifacts = craneLib.buildDepsOnly commonArgs;

  workspace = craneLib.buildPackage (commonArgs // {
    inherit cargoArtifacts;
    prePatch = manifestPatchScript + "\n" + sourcePatchScript;
  });

  server = workspace.overrideAttrs (_: { pname = "graphrag-server"; meta.mainProgram = "graphrag-server"; });
  cli = workspace.overrideAttrs (_: { pname = "graphrag-cli"; meta.mainProgram = "graphrag-cli"; });
in
workspace // {
  inherit server cli;

  meta = {
    description = "High-performance Rust GraphRAG implementation (server + CLI), with vendored upstream fixes (qdrant-client features, /api/config scope shadowing)";
    homepage = "https://github.com/automataIA/graphrag-rs";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    maintainers = [ ];
  };
}

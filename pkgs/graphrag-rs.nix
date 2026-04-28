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
  sourcePatchScript = ''
    # Vendored patch: expose `endpoint: Option<String>` on EmbeddingConfig
    # so the OpenAI-compatible providers (OpenAI, Voyage, Cohere, Jina,
    # Mistral, Together) can be redirected at OpenAI-spec servers like
    # OpenVINO Model Server's /v3/embeddings. Upstream hardcodes the
    # endpoint in HttpEmbeddingProvider::openai() / ::voyage_ai() / ...
    # constructors and has no config-level override. Patch is additive
    # (defaults preserve existing behavior) and suitable for upstream PR.
    # Verified against automataIA/graphrag-rs@c46e2872.

    # 1. Add `endpoint: Option<String>` field to EmbeddingConfig.
    substituteInPlace graphrag-core/src/embeddings/mod.rs \
      --replace-fail \
        "    /// Batch size for processing multiple texts
    pub batch_size: usize,
}" \
        "    /// Batch size for processing multiple texts
    pub batch_size: usize,

    /// Override the provider's HTTP endpoint URL. Lets you point any of
    /// the OpenAI-spec providers at a self-hosted OpenAI-compatible server
    /// (vLLM, OpenVINO Model Server, llama.cpp server, etc).
    pub endpoint: Option<String>,
}"

    # 2. Default endpoint to None.
    substituteInPlace graphrag-core/src/embeddings/mod.rs \
      --replace-fail \
        "            batch_size: 32,
        }
    }
}" \
        "            batch_size: 32,
            endpoint: None,
        }
    }
}"

    # 3. Add `endpoint: Option<String>` to TOML-side EmbeddingProviderConfig.
    substituteInPlace graphrag-core/src/embeddings/config.rs \
      --replace-fail \
        "    /// Embedding dimensions (read-only, determined by model)
    #[serde(skip_serializing_if = \"Option::is_none\")]
    pub dimensions: Option<usize>,
}" \
        "    /// Embedding dimensions (read-only, determined by model)
    #[serde(skip_serializing_if = \"Option::is_none\")]
    pub dimensions: Option<usize>,

    /// Override the provider's HTTP endpoint URL (e.g. for OVMS / vLLM).
    #[serde(skip_serializing_if = \"Option::is_none\")]
    pub endpoint: Option<String>,
}"

    # 4. Add endpoint: None to EmbeddingProviderConfig::default.
    substituteInPlace graphrag-core/src/embeddings/config.rs \
      --replace-fail \
        "            batch_size: default_batch_size(),
            dimensions: None,
        }
    }
}" \
        "            batch_size: default_batch_size(),
            dimensions: None,
            endpoint: None,
        }
    }
}"

    # 4b. Plumb endpoint: None into the 9 hand-rolled `Self { ... }`
    #     constructions inside `pub fn examples()`. Each closes with
    #     `dimensions: Some(N),\n                },\n            ),`
    #     which gives us a unique anchor per dimension. 1024 matches 7
    #     of the 9 (the API providers); 384 and 1536 match 1 each.
    substituteInPlace graphrag-core/src/embeddings/config.rs \
      --replace-fail \
        "                    dimensions: Some(384),
                },
            )," \
        "                    dimensions: Some(384),
                    endpoint: None,
                },
            ),"

    substituteInPlace graphrag-core/src/embeddings/config.rs \
      --replace-fail \
        "                    dimensions: Some(1536),
                },
            )," \
        "                    dimensions: Some(1536),
                    endpoint: None,
                },
            ),"

    substituteInPlace graphrag-core/src/embeddings/config.rs \
      --replace-fail \
        "                    dimensions: Some(1024),
                },
            )," \
        "                    dimensions: Some(1024),
                    endpoint: None,
                },
            ),"

    # 5. Plumb endpoint through TOML→runtime conversion.
    substituteInPlace graphrag-core/src/embeddings/config.rs \
      --replace-fail \
        "        Ok(EmbeddingConfig {
            provider,
            model: self.model.clone(),
            api_key,
            cache_dir: self.cache_dir.clone(),
            batch_size: self.batch_size,
        })" \
        "        Ok(EmbeddingConfig {
            provider,
            model: self.model.clone(),
            api_key,
            cache_dir: self.cache_dir.clone(),
            batch_size: self.batch_size,
            endpoint: self.endpoint.clone(),
        })"

    # 6. Add `with_endpoint` builder method to HttpEmbeddingProvider and
    #    apply config.endpoint override at the end of from_config.
    substituteInPlace graphrag-core/src/embeddings/api_providers.rs \
      --replace-fail \
        "    /// Create provider from configuration
    pub fn from_config(config: &EmbeddingConfig) -> Result<Self> {" \
        "    /// Override the provider's API endpoint URL.
    ///
    /// Use this to point an OpenAI-spec backend (OpenAI, Voyage, Cohere,
    /// Jina, Mistral, Together) at a self-hosted server like OpenVINO Model
    /// Server (\`/v3/embeddings\`) or vLLM.
    pub fn with_endpoint(mut self, endpoint: String) -> Self {
        self.endpoint = endpoint;
        self
    }

    /// Create provider from configuration
    pub fn from_config(config: &EmbeddingConfig) -> Result<Self> {"

    substituteInPlace graphrag-core/src/embeddings/api_providers.rs \
      --replace-fail \
        "        let provider = match config.provider {" \
        "        let mut provider = match config.provider {"

    substituteInPlace graphrag-core/src/embeddings/api_providers.rs \
      --replace-fail \
        "            _ => {
                return Err(GraphRAGError::Embedding {
                    message: format!(\"Unsupported API provider: {}\", config.provider),
                })
            },
        };

        Ok(provider)
    }" \
        "            _ => {
                return Err(GraphRAGError::Embedding {
                    message: format!(\"Unsupported API provider: {}\", config.provider),
                })
            },
        };

        if let Some(endpoint) = config.endpoint.clone() {
            provider = provider.with_endpoint(endpoint);
        }

        Ok(provider)
    }"
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

    cargoExtraArgs = "--locked -p graphrag-server -p graphrag-cli";

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
    description = "High-performance Rust GraphRAG implementation (server + CLI), patched for OpenAI-compat endpoint override";
    homepage = "https://github.com/automataIA/graphrag-rs";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    maintainers = [ ];
  };
}

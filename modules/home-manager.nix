{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.graphrag-rs;
  system = pkgs.stdenv.hostPlatform.system;
  flakePkgs = self.packages.${system};

  # Pipeline config (POSTed to /config — note: prefix is /config, not
  # /api/config; see the actix scope-shadowing fix in pkgs/graphrag-rs.nix).
  # Schema is the upstream runtime config (graphrag-core::config::Config),
  # which is JSON-shaped (not TOML). Set null to skip — server runs with
  # env-var defaults only.
  # Auto-generated pipeline config when chat.enable is true: synthesizes
  # an `openai` (or `ollama`) section keyed off the new chat.* options so
  # users don't have to hand-write JSON to enable the chat backend.
  # Merges into pipelineConfig if both are set (explicit wins via
  # `lib.recursiveUpdate`).
  chatPipelineConfig = lib.optionalAttrs cfg.chat.enable (
    if cfg.chat.backend == "openai" then {
      openai = {
        enabled = true;
        base_url = cfg.chat.openai.baseUrl;
        chat_model = cfg.chat.openai.model;
        api_key = cfg.chat.openai.apiKey;
        temperature = cfg.chat.temperature;
        timeout_seconds = cfg.chat.openai.timeoutSeconds;
      } // lib.optionalAttrs (cfg.chat.maxTokens != null) {
        max_tokens = cfg.chat.maxTokens;
      } // lib.optionalAttrs (cfg.chat.openai.extraBody != { }) {
        extra_body = cfg.chat.openai.extraBody;
      };
    } else {
      ollama = {
        enabled = true;
        host = cfg.chat.ollama.url;
        port = cfg.chat.ollama.port;
        chat_model = cfg.chat.ollama.model;
        temperature = cfg.chat.temperature;
      } // lib.optionalAttrs (cfg.chat.maxTokens != null) {
        max_tokens = cfg.chat.maxTokens;
      };
    });

  effectivePipelineConfig =
    if cfg.pipelineConfig != null then
      lib.recursiveUpdate chatPipelineConfig cfg.pipelineConfig
    else if chatPipelineConfig != { } then chatPipelineConfig
    else null;

  pipelineConfigFile =
    if effectivePipelineConfig == null then null
    else (pkgs.formats.json { }).generate "graphrag-rs-pipeline.json" effectivePipelineConfig;

  envVars = {
    EMBEDDING_BACKEND = cfg.embedding.backend;
    EMBEDDING_DIM = toString cfg.embedding.dimension;
    OLLAMA_URL = cfg.embedding.ollama.url;
    OLLAMA_PORT = toString cfg.embedding.ollama.port;
    OLLAMA_EMBEDDING_MODEL = cfg.embedding.ollama.model;
    OPENAI_URL = cfg.embedding.openai.url;
    OPENAI_EMBEDDING_MODEL = cfg.embedding.openai.model;
    OPENAI_API_KEY = cfg.embedding.openai.apiKey;
    QDRANT_URL = cfg.qdrant.url;
    COLLECTION_NAME = cfg.qdrant.collection;
    RUST_LOG = cfg.logLevel;
  } // cfg.environment;

  mcpClientConfig = pkgs.writeText "graphrag-mcp.json" (builtins.toJSON {
    mcpServers.graphrag = {
      type = "stdio";
      command = "${flakePkgs.graphrag-mcp}/bin/graphrag-mcp";
      args = [ ];
      env = {
        GRAPHRAG_BASE_URL = "http://${cfg.host}:${toString cfg.port}";
      };
    };
  });
in
{
  options.services.graphrag-rs = {
    enable = lib.mkEnableOption "graphrag-rs REST server as a systemd user service";

    package = lib.mkOption {
      type = lib.types.package;
      default = flakePkgs.graphrag-server;
      defaultText = "graphrag-rs flake's graphrag-server output";
      description = "graphrag-server package to run.";
    };

    mcpPackage = lib.mkOption {
      type = lib.types.package;
      default = flakePkgs.graphrag-mcp;
      defaultText = "graphrag-rs flake's graphrag-mcp output";
      description = "Stdio MCP wrapper proxying tool calls to the REST server.";
    };

    installMcp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Add graphrag-mcp to home.packages so MCP clients can spawn it.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address used by the MCP wrapper and `mcp.json` to reach the REST server.
        NOTE: Upstream graphrag-server hardcodes its bind to "0.0.0.0:8080" —
        this option only controls how clients address it.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port the MCP wrapper / mcp.json target. Hardcoded upstream: 8080.";
    };

    # ---------- Startup embedding backend (env-var driven) ----------
    # The openai-compat fork wires graphrag-server/src/embeddings.rs's
    # EmbeddingService to talk OpenAI-compat /embeddings against any
    # backend (vLLM, OVMS, llama-server, real OpenAI). /api/documents
    # and /api/query both go through this path; NPU via OVMS is the
    # default in this flake. Hit GET /api/embeddings/stats to confirm
    # the live runtime backend at any time. (Note: graphrag-core's
    # *internal* embedding generator — the one /config returns under
    # config.embeddings — is a separate, hash-only path; it's used by
    # entity-vector storage during graph build, not by the user-facing
    # embedding flow.)
    embedding = {
      backend = lib.mkOption {
        type = lib.types.enum [ "hash" "ollama" "openai" ];
        default = "openai";
        description = ''
          Embedding backend (env var EMBEDDING_BACKEND). Three options:

          - "openai" — point at any OpenAI-compatible /embeddings server
            (vLLM, OpenVINO Model Server, llama-server with --embedding,
            real OpenAI API, OpenRouter, …) via `embedding.openai.*`.
            Recommended default.
          - "ollama" — talk Ollama protocol to a real Ollama instance via
            `embedding.ollama.*`. Useful if you've already pulled embedding
            models there.
          - "hash" — deterministic hash-based fallback. No model required.
        '';
      };

      dimension = lib.mkOption {
        type = lib.types.int;
        default = 1024;
        description = ''
          Embedding vector dimension at startup (env var EMBEDDING_DIM).
          MUST match what your model returns or Qdrant inserts will fail
          with a dim mismatch. Common values: 384 (MiniLM), 768
          (nomic-embed-text, bge-base), 1024 (mxbai, bge-m3, bge-large),
          4096 (Qwen3-Embedding-8B native).
        '';
      };

      ollama = {
        url = lib.mkOption {
          type = lib.types.str;
          default = "http://localhost";
          description = ''
            Host for Ollama (env var OLLAMA_URL). Just the scheme+host —
            port is configured separately via `port` below.
          '';
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 11434;
          description = "Port for Ollama (env var OLLAMA_PORT). 11434 = real Ollama default.";
        };
        model = lib.mkOption {
          type = lib.types.str;
          default = "nomic-embed-text";
          description = "OLLAMA_EMBEDDING_MODEL env var.";
        };
      };

      openai = {
        url = lib.mkOption {
          type = lib.types.str;
          default = "http://127.0.0.1:9000/v3";
          description = ''
            Full OpenAI-compatible API base URL including the version path
            (env var OPENAI_URL). Examples:
              - http://127.0.0.1:8000/v1     vLLM (`vllm serve --task embed`)
              - http://127.0.0.1:9000/v3     OpenVINO Model Server (services.graphrag-rs-npu)
              - http://127.0.0.1:17171/v1    llama-server with --embedding
              - https://api.openai.com/v1    real OpenAI
          '';
        };
        model = lib.mkOption {
          type = lib.types.str;
          default = "embeddings";
          description = ''
            Model name sent in the request body's `model` field. For OVMS
            the Mediapipe graph name is "embeddings"; for vLLM it's the
            HF repo path; for OpenAI it's e.g. "text-embedding-3-small".
          '';
        };
        apiKey = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = ''
            Bearer token (env var OPENAI_API_KEY). Empty disables the
            Authorization header — fine for self-hosted servers (vLLM,
            OVMS, llama-server) that don't authenticate.
          '';
        };
      };
    };

    qdrant = {
      url = lib.mkOption {
        type = lib.types.str;
        default = "http://localhost:6334";
        description = "Qdrant gRPC endpoint (env var QDRANT_URL). Falls back to in-memory if unreachable.";
      };
      collection = lib.mkOption {
        type = lib.types.str;
        default = "graphrag";
        description = "Qdrant collection name (env var COLLECTION_NAME).";
      };
    };

    # ---------- Chat LLM (entity extraction, query, gleaning) ----------
    # Routed through graphrag-core's ChatClient enum (added in our
    # openai-compat fork). When enabled, an `openai` (or `ollama`) section
    # is synthesized into the pipelineConfig and POSTed to /config on
    # startup so the runtime picks the right backend.
    chat = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable the chat LLM in graphrag-rs's runtime pipeline (entity
          extraction, query planning, answer generation). When true, a
          minimal pipeline config is synthesized and auto-POSTed to
          /config so graphrag-core wires the configured backend.

          Without this, ingest still works (embeddings only) but the
          graph stays at entity-count zero — there's no LLM to extract
          entities + relationships from chunk text.
        '';
      };

      backend = lib.mkOption {
        type = lib.types.enum [ "openai" "ollama" ];
        default = "openai";
        description = ''
          Which chat backend the pipeline uses. "openai" hits any
          OpenAI-compat /chat/completions endpoint (vLLM, llama-server,
          OpenAI itself, OpenRouter); "ollama" talks Ollama's native API.
        '';
      };

      temperature = lib.mkOption {
        type = lib.types.float;
        default = 0.2;
        description = "Sampling temperature for entity-extraction prompts.";
      };

      maxTokens = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = 2000;
        description = "Maximum tokens to generate per chat call. Null = backend default.";
      };

      openai = {
        baseUrl = lib.mkOption {
          type = lib.types.str;
          default = "http://127.0.0.1:8000/v1";
          description = ''
            Full OpenAI-compatible base URL including the version path.
            Examples:
              - http://127.0.0.1:17171/v1   llama-server (services.llama-server)
              - http://127.0.0.1:8000/v1    vLLM
              - https://api.openai.com/v1   real OpenAI
          '';
        };
        model = lib.mkOption {
          type = lib.types.str;
          default = "gpt-4o-mini";
          description = ''
            Model name passed in the request body. For self-hosted
            servers this is whatever GET /models reports; for llama-server
            running a single GGUF, the filename without extension usually
            works (e.g. "Qwen3.6-27B-Q4_K_M").
          '';
        };
        apiKey = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Bearer token. Empty disables the Authorization header.";
        };
        timeoutSeconds = lib.mkOption {
          type = lib.types.int;
          default = 600;
          description = "HTTP request timeout in seconds (upstream default is 60). Set higher for slow local models.";
        };
        extraBody = lib.mkOption {
          type = (pkgs.formats.json { }).type;
          default = { };
          example = lib.literalExpression ''{ chat_template_kwargs = { enable_thinking = false; }; }'';
          description = ''
            Extra top-level fields merged into every /chat/completions
            request body. Lets you pass server-specific knobs without
            touching the server CLI. Examples:

              - llama.cpp / vLLM Qwen3 thinking suppression:
                  { chat_template_kwargs.enable_thinking = false; }
              - vLLM JSON-only output:
                  { response_format = { type = "json_object"; }; }
              - OpenAI structured outputs:
                  { response_format = { type = "json_schema"; ... }; }

            Existing fields set elsewhere (model, max_tokens, temperature,
            stop, top_p) take precedence over collisions.
          '';
        };
      };

      ollama = {
        url = lib.mkOption {
          type = lib.types.str;
          default = "http://localhost";
          description = "Ollama host (used only when chat.backend = \"ollama\").";
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 11434;
        };
        model = lib.mkOption {
          type = lib.types.str;
          default = "llama3.1:8b";
          description = "Ollama chat model identifier (e.g. \"llama3.1:8b\", \"qwen2.5:7b-instruct\").";
        };
      };
    };

    pipelineConfig = lib.mkOption {
      type = lib.types.nullOr (pkgs.formats.json { }).type;
      default = null;
      description = ''
        Optional pipeline config rendered to JSON and POSTed to /config
        after the server starts. Schema is the upstream runtime config
        (`graphrag-core::config::Config`); see what `GET /config/default`
        returns for the full shape and example values.

        Set null to skip — server runs with env-var defaults only.
      '';
    };

    applyPipelineConfig = lib.mkOption {
      type = lib.types.bool;
      default = cfg.pipelineConfig != null || cfg.chat.enable;
      defaultText = "auto: true if pipelineConfig or chat.enable is set";
      description = "ExecStartPost POSTs the pipeline config to /config once /health is up.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for the systemd unit.";
    };

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      description = "RUST_LOG value for the server.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = lib.mkIf cfg.installMcp [ cfg.mcpPackage ];

    xdg.configFile."graphrag-rs/mcp.json".source = mcpClientConfig;
    xdg.configFile."graphrag-rs/pipeline.json" = lib.mkIf (pipelineConfigFile != null) {
      source = pipelineConfigFile;
    };

    systemd.user.services.graphrag-rs = {
      Unit = {
        Description = "graphrag-rs REST server (knowledge graph over Obsidian vault)";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };

      Service = lib.mkMerge [
        {
          ExecStart = "${cfg.package}/bin/graphrag-server";
          Restart = "on-failure";
          RestartSec = "5s";
          Environment = lib.mapAttrsToList (k: v: "${k}=${v}") envVars;
        }
        (lib.mkIf cfg.applyPipelineConfig {
          ExecStartPost = pkgs.writeShellScript "graphrag-rs-apply-config" ''
            set -eu
            # systemd ExecStartPost runs with an empty PATH; pull in coreutils
            # explicitly so `sleep`, `seq`, etc. resolve. curl is referenced by
            # absolute store path below for the same reason.
            export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
            # /config/* (not /api/config/*) — upstream registers /api/config
            # AFTER /api which shadows it; the flake's vendored patch renames
            # the prefix to /config to sidestep the conflict.
            target="http://${cfg.host}:${toString cfg.port}/config"
            i=0
            while [ "$i" -lt 30 ]; do
              if ${pkgs.curl}/bin/curl -fs "http://${cfg.host}:${toString cfg.port}/health" >/dev/null 2>&1; then
                break
              fi
              i=$((i + 1))
              sleep 1
            done
            ${pkgs.curl}/bin/curl -fsS -X POST "$target" \
              -H 'Content-Type: application/json' \
              --data-binary @${pipelineConfigFile}
          '';
        })
      ];

      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}

{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.graphrag-rs;
  system = pkgs.stdenv.hostPlatform.system;
  flakePkgs = self.packages.${system};

  tomlFormat = pkgs.formats.toml { };

  # When openaiBackend.enable is true, synthesize a minimal pipeline config
  # that points the [embeddings] section at the user's OpenAI-compatible
  # server (e.g. OVMS /v3/embeddings). The patched graphrag-core honors the
  # `endpoint` field so this gets routed correctly.
  openaiPipelineConfig = lib.optionalAttrs cfg.openaiBackend.enable {
    embeddings = {
      provider = "openai";
      model = cfg.openaiBackend.model;
      api_key = cfg.openaiBackend.apiKey;
      endpoint = cfg.openaiBackend.apiBase;
      batch_size = cfg.openaiBackend.batchSize;
    } // lib.optionalAttrs (cfg.openaiBackend.dimensions != null) {
      dimensions = cfg.openaiBackend.dimensions;
    };
  };

  effectivePipelineConfig =
    if cfg.pipelineConfig != null then cfg.pipelineConfig
    else if cfg.openaiBackend.enable then openaiPipelineConfig
    else null;

  pipelineConfigFile =
    if effectivePipelineConfig == null then null
    else tomlFormat.generate "graphrag-rs-pipeline.toml" effectivePipelineConfig;

  envVars = {
    EMBEDDING_BACKEND = cfg.embedding.backend;
    EMBEDDING_DIM = toString cfg.embedding.dimension;
    OLLAMA_URL = cfg.embedding.ollama.url;
    OLLAMA_EMBEDDING_MODEL = cfg.embedding.ollama.model;
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
    # graphrag-server's startup EmbeddingService only recognizes "hash" or
    # "ollama" (graphrag-server/src/embeddings.rs). The patched OpenAI path
    # only kicks in once a pipeline config is POSTed — see openaiBackend
    # below. Leave this as "hash" if you're using openaiBackend.
    embedding = {
      backend = lib.mkOption {
        type = lib.types.enum [ "hash" "ollama" ];
        default = "hash";
        description = ''
          STARTUP backend (env var EMBEDDING_BACKEND). Upstream graphrag-server
          only supports "hash" (deterministic, no model) or "ollama" (HTTP to
          OLLAMA_URL/api/embeddings) at startup. The full OpenAI path requires
          a pipeline config POST — set `services.graphrag-rs.openaiBackend`
          for that.
        '';
      };

      dimension = lib.mkOption {
        type = lib.types.int;
        default = 768;
        description = "Embedding vector dimension at startup (env var EMBEDDING_DIM).";
      };

      ollama = {
        url = lib.mkOption {
          type = lib.types.str;
          default = "http://localhost:11434";
          description = "OLLAMA_URL env var. Only used when embedding.backend = \"ollama\".";
        };
        model = lib.mkOption {
          type = lib.types.str;
          default = "nomic-embed-text";
          description = "OLLAMA_EMBEDDING_MODEL env var.";
        };
      };
    };

    # ---------- Pipeline embedding via patched OpenAI backend ----------
    # The flake ships a vendored patch (pkgs/graphrag-rs.nix prePatch) that
    # exposes `endpoint: Option<String>` on graphrag-core's EmbeddingConfig.
    # That lets graphrag-rs's `[openai]` provider be redirected at any
    # OpenAI-spec server — vLLM, llama.cpp server, OpenVINO Model Server's
    # /v3/embeddings (NPU), etc.
    openaiBackend = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          When true, synthesize a pipeline config that points the [openai]
          embedding provider at `apiBase` and POST it via ExecStartPost.

          NPU recipe: stand up OVMS serving an embedding model on
          /v3/embeddings, then set `enable = true; apiBase = "http://localhost:8000/v3/embeddings"`.
        '';
      };

      apiBase = lib.mkOption {
        type = lib.types.str;
        default = "http://127.0.0.1:8000/v3/embeddings";
        description = "Full OpenAI-compatible embeddings endpoint URL (NOT just the host).";
      };

      model = lib.mkOption {
        type = lib.types.str;
        default = "Qwen3-Embedding-0.6B";
        description = "Model name as exposed by the OpenAI-compatible server.";
      };

      apiKey = lib.mkOption {
        type = lib.types.str;
        default = "dummy";
        description = "API key. OVMS doesn't authenticate, but the patched provider still requires the field; \"dummy\" is fine.";
      };

      dimensions = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Embedding dimensions. Null = let provider/model defaults decide.";
      };

      batchSize = lib.mkOption {
        type = lib.types.int;
        default = 32;
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

    pipelineConfig = lib.mkOption {
      type = lib.types.nullOr tomlFormat.type;
      default = null;
      description = ''
        Explicit pipeline config (TOML attrset). If non-null, takes precedence
        over openaiBackend's auto-generated config. Schema is the upstream
        [mode]/[general]/[hybrid.*] format — set this for full pipeline
        control beyond just embeddings.
      '';
    };

    applyPipelineConfig = lib.mkOption {
      type = lib.types.bool;
      default = effectivePipelineConfig != null;
      defaultText = "auto: true if pipelineConfig or openaiBackend is set";
      description = "ExecStartPost POSTs the pipeline config to /api/config once /health is up.";
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
    xdg.configFile."graphrag-rs/pipeline.toml" = lib.mkIf (pipelineConfigFile != null) {
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
            # /config/* (not /api/config/*) — upstream registers /api/config
            # AFTER /api which shadows it; the flake's vendored patch renames
            # the prefix to /config to sidestep the conflict.
            target="http://${cfg.host}:${toString cfg.port}/config"
            for _ in $(seq 1 30); do
              if ${pkgs.curl}/bin/curl -fs "http://${cfg.host}:${toString cfg.port}/health" >/dev/null 2>&1; then
                break
              fi
              sleep 1
            done
            # set_config takes JSON. Convert our TOML pipeline config first.
            ${pkgs.remarshal}/bin/toml2json < ${pipelineConfigFile} \
              | ${pkgs.curl}/bin/curl -fsS -X POST "$target" \
                  -H 'Content-Type: application/json' \
                  --data-binary @-
          '';
        })
      ];

      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}

{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.graphrag-rs;
  system = pkgs.stdenv.hostPlatform.system;
  flakePkgs = self.packages.${system};

  tomlFormat = pkgs.formats.toml { };

  # Pipeline config (POSTed to /api/config at runtime, optional). This is
  # the [mode]/[general]/[hybrid.*]/[semantic.*]/[algorithmic.*] schema.
  # The binary itself doesn't read it on startup — env vars do that.
  pipelineConfigFile =
    if cfg.pipelineConfig == null then null
    else tomlFormat.generate "graphrag-rs-pipeline.toml" cfg.pipelineConfig;

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

        NOTE: Upstream graphrag-server hardcodes its bind to "0.0.0.0:8080" in
        graphrag-server/src/main.rs — this option does NOT change what the server
        binds to. It only controls how clients address it. Patch upstream if you
        need real host/port flexibility.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = ''
        Port the MCP wrapper / mcp.json target. Hardcoded upstream: 8080.
        See `host` for the same caveat.
      '';
    };

    embedding = {
      backend = lib.mkOption {
        type = lib.types.enum [ "hash" "ollama" "huggingface" "openai" ];
        default = "ollama";
        description = ''
          Startup embedding backend (env var EMBEDDING_BACKEND). graphrag-server
          starts with this; the full pipeline config can be POSTed later via
          `services.graphrag-rs.pipelineConfig`.

          "hash" = deterministic hash-based embeddings (no model, no NPU).
          "ollama" = HTTP to OLLAMA_URL/api/embeddings (use this for OVMS-via-shim).
        '';
      };

      dimension = lib.mkOption {
        type = lib.types.int;
        default = 768;
        description = "Embedding vector dimension (env var EMBEDDING_DIM). 768 = nomic-embed-text default.";
      };

      ollama = {
        url = lib.mkOption {
          type = lib.types.str;
          default = "http://localhost:11434";
          description = ''
            Base URL for the Ollama-protocol embeddings endpoint (env var
            OLLAMA_URL). Point this at the (TODO) Ollama→OVMS shim once written
            to get NPU-backed embeddings via OVMS's OpenAI-compat /v3/embeddings.
          '';
        };
        model = lib.mkOption {
          type = lib.types.str;
          default = "nomic-embed-text";
          description = "Embedding model name (env var OLLAMA_EMBEDDING_MODEL).";
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

    pipelineConfig = lib.mkOption {
      type = lib.types.nullOr tomlFormat.type;
      default = null;
      example = lib.literalExpression ''
        {
          mode.approach = "hybrid";
          general = {
            output_dir = "./output/hybrid";
            log_level = "info";
            max_threads = 4;
          };
          hybrid = {
            embeddings = { primary_backend = "huggingface"; primary_model = "BAAI/bge-large-en-v1.5"; };
            entity_extraction = { llm_model = "llama3.1:8b"; };
            retrieval = { fusion_strategy = "rrf"; top_k = 10; };
          };
        }
      '';
      description = ''
        Optional pipeline config rendered to TOML and POSTed to /api/config
        after the server starts. Schema: [mode], [general], [hybrid.*]
        (or [semantic.*] / [algorithmic.*]), per upstream
        config/templates/*.toml.

        Set null to skip — server runs with env-var defaults only.
      '';
    };

    applyPipelineConfig = lib.mkOption {
      type = lib.types.bool;
      default = cfg.pipelineConfig != null;
      defaultText = "true if pipelineConfig is set";
      description = ''
        Run a oneshot ExecStartPost that POSTs `pipelineConfig` to
        /api/config once the server is up. Disable to manage the config
        yourself (e.g. via the Swagger UI at /swagger).
      '';
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
            target="http://${cfg.host}:${toString cfg.port}/api/config"
            # Wait for the server to come up (up to 30s).
            for _ in $(seq 1 30); do
              if ${pkgs.curl}/bin/curl -fs "http://${cfg.host}:${toString cfg.port}/health" >/dev/null 2>&1; then
                break
              fi
              sleep 1
            done
            ${pkgs.curl}/bin/curl -fsS -X POST "$target" \
              -H 'Content-Type: application/toml' \
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

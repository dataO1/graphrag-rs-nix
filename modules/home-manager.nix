{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.graphrag-rs;
  system = pkgs.stdenv.hostPlatform.system;
  flakePkgs = self.packages.${system};

  tomlFormat = pkgs.formats.toml { };

  # Render the merged config from typed Nix options. extraConfig wins over
  # any computed defaults so users can drop in arbitrary keys (e.g. retrieval
  # strategy tweaks, reranker config) without us having to model them all.
  computedConfig = lib.recursiveUpdate
    {
      server = {
        host = cfg.host;
        port = cfg.port;
      };
      embeddings = lib.filterAttrs (_: v: v != null) {
        backend = cfg.embeddings.backend;
        model = cfg.embeddings.model;
        dimension = cfg.embeddings.dimension;
        batch_size = cfg.embeddings.batchSize;
      } // lib.optionalAttrs (cfg.embeddings.backend == "ollama") {
        host = cfg.embeddings.ollama.host;
        port = cfg.embeddings.ollama.port;
      } // lib.optionalAttrs (cfg.embeddings.backend == "openai") {
        api_base = cfg.embeddings.openai.apiBase;
      };
      llm = lib.filterAttrs (_: v: v != null) {
        backend = cfg.llm.backend;
        model = cfg.llm.model;
        temperature = cfg.llm.temperature;
      } // lib.optionalAttrs (cfg.llm.backend == "ollama") {
        host = cfg.llm.ollama.host;
        port = cfg.llm.ollama.port;
      };
      storage = {
        backend = cfg.storage.backend;
        path = cfg.dataDir;
      };
      ingest = {
        sources = cfg.sources;
      };
    }
    cfg.extraConfig;

  configFile = tomlFormat.generate "graphrag-rs.toml" computedConfig;

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
      description = ''
        Stdio MCP wrapper that proxies tool calls to the REST server. Installed
        on PATH so MCP clients (Claude Code, opencode, crush) can spawn it.
      '';
    };

    installMcp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Add graphrag-mcp to home.packages so MCP clients can spawn it.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "REST API bind address. Default localhost-only.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8910;
      description = "REST API port. graphrag-server upstream default is 8080; we shift it.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.dataHome}/graphrag-rs";
      defaultText = "\${config.xdg.dataHome}/graphrag-rs";
      description = "Where graphrag-rs stores its graph + cache state.";
    };

    sources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/home/alice/Notes" ];
      description = "Directories to ingest into the graph (markdown/text).";
    };

    embeddings = {
      backend = lib.mkOption {
        type = lib.types.enum [ "huggingface" "ollama" "openai" "voyage" "cohere" "jina" "mistral" "together" ];
        default = "ollama";
        description = ''
          Embedding backend. Default "ollama" because graphrag-rs's Ollama
          backend exposes host/port — easiest path to reach a local OVMS
          OpenAI-compat endpoint via a thin shim. Switch to "openai" if/when
          graphrag-rs's OpenAI backend is verified to honor `api_base`.
        '';
      };

      model = lib.mkOption {
        type = lib.types.str;
        default = "nomic-embed-text";
        description = "Embedding model identifier (backend-specific).";
      };

      dimension = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Embedding vector dimension. Null = use backend default.";
      };

      batchSize = lib.mkOption {
        type = lib.types.int;
        default = 32;
      };

      ollama = {
        host = lib.mkOption {
          type = lib.types.str;
          default = "http://localhost";
          description = "Ollama-protocol host (point at OVMS shim or real Ollama).";
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 11434;
        };
      };

      openai = {
        apiBase = lib.mkOption {
          type = lib.types.str;
          default = "http://127.0.0.1:8000/v3";
          description = ''
            OpenAI-compatible API base. For OVMS this is `http://host:port/v3`.
            graphrag-rs's `[openai] api_base` support is unverified — leave on
            "ollama" backend until confirmed.
          '';
        };
      };
    };

    llm = {
      backend = lib.mkOption {
        type = lib.types.enum [ "ollama" "openai" "candle" "mock" ];
        default = "ollama";
      };
      model = lib.mkOption {
        type = lib.types.str;
        default = "llama3.1:8b";
      };
      temperature = lib.mkOption {
        type = lib.types.float;
        default = 0.2;
      };
      ollama = {
        host = lib.mkOption {
          type = lib.types.str;
          default = "http://localhost";
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 11434;
        };
      };
    };

    storage = {
      backend = lib.mkOption {
        type = lib.types.enum [ "qdrant" "lancedb" "memory" ];
        default = "qdrant";
      };
    };

    extraConfig = lib.mkOption {
      type = tomlFormat.type;
      default = { };
      description = ''
        Extra TOML keys merged on top of the generated config. Use this for
        anything not modeled as a typed option (retrieval strategy, reranker,
        community detection params, etc).
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

    # Drop the MCP client config in a known place so the user can symlink it
    # into ~/.config/{claude,opencode,crush}/mcp.json, or `cat` it for
    # reference. We deliberately don't write directly into those files —
    # those are managed elsewhere in this dotfiles tree.
    xdg.configFile."graphrag-rs/mcp.json".source = mcpClientConfig;
    xdg.configFile."graphrag-rs/config.toml".source = configFile;

    systemd.user.services.graphrag-rs = {
      Unit = {
        Description = "graphrag-rs REST server (knowledge graph over Obsidian vault)";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };

      Service = {
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${cfg.dataDir}";
        ExecStart = "${cfg.package}/bin/graphrag-server --config ${configFile}";
        Restart = "on-failure";
        RestartSec = "5s";
        Environment = lib.mapAttrsToList (k: v: "${k}=${v}") ({
          RUST_LOG = cfg.logLevel;
          GRAPHRAG_DATA_DIR = cfg.dataDir;
        } // cfg.environment);
      };

      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}

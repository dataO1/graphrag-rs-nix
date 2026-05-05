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

  # Synthesizes the `embeddings` block of the posted pipeline JSON from
  # the same `embedding.*` options that drive the env vars. Mirrors what
  # chatPipelineConfig does for chat. The shape matches graphrag-core's
  # `Config.embeddings` (dimension/backend/model/api_endpoint/api_key/...);
  # POST /config will rebuild the active EmbeddingService from this block,
  # so this is the single source of truth post-refactor. Env vars remain
  # as bootstrap defaults until the POST lands a few hundred ms later.
  embeddingsPipelineConfig = {
    embeddings = {
      backend = cfg.embedding.backend;
      dimension = cfg.embedding.dimension;
      fallback_to_hash = false;
    } // lib.optionalAttrs (cfg.embedding.backend == "openai") {
      api_endpoint = cfg.embedding.openai.url;
      model = cfg.embedding.openai.model;
    } // lib.optionalAttrs (cfg.embedding.backend == "openai" && cfg.embedding.openai.apiKey != "") {
      api_key = cfg.embedding.openai.apiKey;
    } // lib.optionalAttrs (cfg.embedding.backend == "ollama") {
      # Ollama host:port encoded into api_endpoint; the server splits it.
      api_endpoint = "${cfg.embedding.ollama.url}:${toString cfg.embedding.ollama.port}";
      model = cfg.embedding.ollama.model;
    };
  };

  effectivePipelineConfig =
    let
      base = lib.recursiveUpdate embeddingsPipelineConfig chatPipelineConfig;
    in
    if cfg.pipelineConfig != null then
      lib.recursiveUpdate base cfg.pipelineConfig
    else base;

  # Always non-null now: even with chat disabled and no user-supplied
  # pipelineConfig, embeddingsPipelineConfig is the floor. POSTing this
  # on every boot is what keeps `Config.embeddings` (the single source of
  # truth post-refactor) in sync with the user's nix-declared backend.
  pipelineConfigFile = (pkgs.formats.json { }).generate "graphrag-rs-pipeline.json" effectivePipelineConfig;

  # ---------- Path-based ingestion ----------
  # POST /api/documents accepts {path}/{paths}/{pathsGlob} when the
  # server has at least one allowed root. Empty allowedRoots disables
  # path-ingest entirely (the only ingest form that still works is
  # the legacy {title, content} body). Sandbox check is canonicalize +
  # starts_with against this list — symlinks that escape will fail
  # canonicalize. See graphrag-server/src/ingest_policy.rs.
  ingestEnvVars = lib.optionalAttrs (cfg.ingest.allowedRoots != [ ]) {
    INGEST_ALLOWED_ROOTS = lib.concatStringsSep ":" cfg.ingest.allowedRoots;
  } // {
    INGEST_MAX_FILE_BYTES = toString cfg.ingest.maxFileBytes;
    INGEST_ALLOWED_EXTENSIONS = lib.concatStringsSep "," cfg.ingest.allowedExtensions;
    INGEST_FOLLOW_SYMLINKS = if cfg.ingest.followSymlinks then "1" else "0";
  } // lib.optionalAttrs (cfg.ingest.preprocessorUrl != null) {
    INGEST_PREPROCESSOR_URL = cfg.ingest.preprocessorUrl;
  };

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
    APPEND_DEBOUNCE_SECS = toString cfg.autoAppendDebounceSecs;
    EXTRACTION_CONCURRENCY = toString cfg.extractionConcurrency;
    RUST_LOG = cfg.logLevel;
  } // ingestEnvVars // cfg.environment;

  mcpClientConfig = pkgs.writeText "knowledge-mcp.json" (builtins.toJSON {
    mcpServers.knowledge = {
      type = "stdio";
      command = "${cfg.mcpPackage}/bin/knowledge-mcp";
      args = [ ];
      env = {
        KNOWLEDGE_BASE_URL = "http://${cfg.host}:${toString cfg.port}";
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
      default = flakePkgs.knowledge-mcp;
      defaultText = "graphrag-rs flake's knowledge-mcp output";
      description = "Stdio MCP server (`knowledge-mcp`) exposing your local knowledge graph (`recall`/`remember`/`forget`/`catalog`/`status`) over the graphrag-rs REST backend.";
    };

    installMcp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Add `knowledge-mcp` to home.packages so MCP clients can spawn it.";
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
        waitForReady = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            ExecStartPre polls `<url>/models` until it returns 200 before
            launching graphrag-server. Fixes the startup race where the
            embedding probe (graphrag-server/src/embeddings.rs:194) fires
            before the backend (e.g. OVMS container) has bound its port —
            on a probe failure graphrag-server silently falls back to hash
            embeddings and ingests garbage vectors for the rest of the
            session.

            Only applies when `embedding.backend = "openai"`. Set false if
            you point at a remote service that's always up (e.g. real
            OpenAI) or want graphrag-server to start regardless.
          '';
        };
        waitTimeoutSeconds = lib.mkOption {
          type = lib.types.int;
          default = 120;
          description = ''
            Max seconds to wait for the OpenAI-compat endpoint before
            giving up and starting anyway (graphrag-server will then fall
            back to hash embeddings as if waitForReady were false). Cold
            OVMS NPU model loads typically finish in 15–30s; bump if your
            backend is slower.
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

    # ---------- Path-based ingestion ----------
    # Allows agents to POST {path}, {paths}, or {pathsGlob} to
    # /api/documents instead of inlining file contents into their
    # prompt. The server reads off disk, sandboxes, dedups, and
    # ingests. Non-text formats (pdf, docx, image, audio, video)
    # route through the optional preprocessor service when configured
    # — see graphrag-rs-nix/TODO.md § "Multimodal preprocessor".
    ingest = {
      allowedRoots = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "/home/data01/notes" "/home/data01/Documents" ];
        description = ''
          Absolute filesystem paths the server is allowed to read for
          path-based ingestion. Empty (the default) disables
          path-ingestion entirely — only the legacy `{title, content}`
          POST shape will work, which keeps the server's read surface
          at zero until you opt in.

          Each entry is canonicalized at boot; non-existent roots are
          warned and dropped. A request path is accepted iff its own
          canonical form starts_with at least one entry; symlinks
          fail canonicalize unless `followSymlinks` is true.

          (Plumbed as colon-separated env var INGEST_ALLOWED_ROOTS.)
        '';
      };

      maxFileBytes = lib.mkOption {
        type = lib.types.int;
        default = 16 * 1024 * 1024;
        description = ''
          Per-file size cap (env var INGEST_MAX_FILE_BYTES). Larger
          files land as `rejected` in the response. graphrag chunking
          + entity extraction over a single multi-hundred-MB blob is
          almost never the intent — raise explicitly when it is.
        '';
      };

      allowedExtensions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "md" "markdown" "mdx" "txt" "text" "rst" "org" "adoc" "asciidoc" "tex"
          "json" "yaml" "yml" "toml" "ini" "csv" "tsv" "log"
          "rs" "py" "js" "mjs" "cjs" "ts" "tsx" "jsx"
          "go" "c" "h" "cpp" "cc" "hpp" "hh" "java" "kt" "kts"
          "rb" "php" "swift" "scala" "clj" "ex" "exs" "erl" "hs"
          "sql" "sh" "bash" "zsh" "fish" "ps1"
          "nix" "dhall"
          "html" "htm" "xml" "svg" "css" "scss" "less"
          "graphql" "gql" "proto" "thrift"
        ];
        description = ''
          Lower-case extensions (no leading dot) that are read
          directly as UTF-8 text (env var INGEST_ALLOWED_EXTENSIONS,
          comma-separated). Anything outside the list either routes
          through `preprocessorUrl` (when set) or is reported as
          `unsupported` in the response.

          The default list covers markdown, prose, code, structured
          data, and shell — the formats graphrag chunks well today.
          Non-text formats (pdf, docx, png, mp3, mp4, ...) deliberately
          aren't here so callers don't accidentally embed binary as
          UTF-8 garbage; route them through the preprocessor instead.
        '';
      };

      preprocessorUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "http://127.0.0.1:9100/preprocess";
        description = ''
          Optional URL of a preprocessor service that converts non-
          text files to markdown before ingest (env var
          INGEST_PREPROCESSOR_URL). When set, files whose extension
          is NOT in `allowedExtensions` are POSTed as
          `{ "path": "<absolute>" }`; the response is parsed as
          `{ "markdown": "...", "title"?: "..." }` and ingested.

          Null (default) means non-text files are reported as
          `unsupported` and skipped. The planned Nemotron-3-Nano-Omni
          preprocessor (PDF/DOCX/image/audio/video → markdown) lives
          here once it ships — see graphrag-rs-nix/TODO.md.
        '';
      };

      followSymlinks = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          When false (default), any caller-supplied path that is itself
          a symlink is rejected as a defense-in-depth measure (env var
          INGEST_FOLLOW_SYMLINKS=0). Canonicalize already follows
          symlinks for sandbox enforcement, so a symlink whose target
          lives inside `allowedRoots` would be readable — this knob
          is for shops that don't want callers feeding symlinks at all.
        '';
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
      default = true;
      description = ''
        ExecStartPost POSTs the pipeline config to /config once /health
        is up. Defaults to true because the synthesized embeddings block
        is the single source of truth for the active embedding backend
        post-refactor — without this POST the server runs with whatever
        Config defaults the binary ships (currently hash/384), regardless
        of `embedding.*` settings here.

        Set false only if you intend to drive /config externally (e.g.
        for testing or a custom pipeline JSON via `pipelineConfig`).
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

    # ---------- Filesystem watcher (knowledge-watcher) ----------
    # Optional sidecar that watches a set of root directories with
    # inotify and keeps the local knowledge graph synced — initial
    # walk on boot + live debounced upserts on every editor save.
    # Stable doc id = absolute path so the server's
    # upsert-by-user_id flow takes care of "I edited my markdown"
    # correctly (content_hash dedup is automatic; on real changes
    # the new chunks land at version+1 and the prior version's
    # chunks get marked superseded).
    watcher = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Run `knowledge-watcher` as a second user systemd unit
          alongside `graphrag-rs.service`. Off by default — opt in
          when you want a folder kept auto-synced.
        '';
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = flakePkgs.knowledge-watcher;
        defaultText = "graphrag-rs flake's knowledge-watcher output";
        description = "Watcher package to run.";
      };

      watchPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = cfg.ingest.allowedRoots;
        defaultText = "services.graphrag-rs.ingest.allowedRoots";
        description = ''
          Absolute filesystem paths to watch (env var
          `WATCHER_ROOTS`, colon-separated). Defaults to the
          server's `ingest.allowedRoots` so the watcher and the
          server's path-ingest sandbox always agree about what's
          eligible. Override only when you want the watcher to see
          a strict subset.
        '';
      };

      debounceMs = lib.mkOption {
        type = lib.types.int;
        default = 300;
        description = ''
          Inotify debounce window in milliseconds (env var
          `WATCHER_DEBOUNCE_MS`). One editor save typically fires
          3-5 events; 300 ms is comfortable for Vim/VSCode/Obsidian
          atomic-write patterns. Drop to 50-100 ms for very
          interactive feel; raise on slow filesystems.
        '';
      };

      maxInFlight = lib.mkOption {
        type = lib.types.int;
        default = 4;
        description = ''
          Max concurrent ingest POSTs (env var
          `WATCHER_MAX_IN_FLIGHT`). The initial walk + bursty live
          events use a semaphore so we don't open thousands of
          HTTP connections to the embedding service at once.
        '';
      };

      initialIndex = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run a recursive walk over `watchPaths` at startup,
          ingesting every eligible file (env var
          `WATCHER_INITIAL_INDEX=1`). gitignore-aware — uses the
          same engine ripgrep does (BurntSushi's `ignore` crate).
          The server's content-hash dedup makes second-runs free.

          Set false to skip the walk and only react to live
          events.
        '';
      };

      allowedExtensions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = cfg.ingest.allowedExtensions;
        defaultText = "services.graphrag-rs.ingest.allowedExtensions";
        description = ''
          Lower-case extensions (no leading dot) the watcher will
          ingest (env var `WATCHER_ALLOWED_EXTENSIONS`,
          comma-separated). Defaults to the server's
          `ingest.allowedExtensions` so they stay consistent.
          Non-text formats (pdf, docx, png, …) are deliberately not
          here; they'll route through the preprocessor when one is
          configured (TODO).
        '';
      };
    };

    extractionConcurrency = lib.mkOption {
      type = lib.types.int;
      default = 4;
      example = 8;
      description = ''
        Cap on concurrent in-flight LLM entity-extraction calls
        (env var `EXTRACTION_CONCURRENCY`). graphrag-core's
        per-chunk extraction runs through `buffer_unordered`; this
        knob bounds how many chunks can be hitting the chat backend
        at the same time.

        **Match this to the chat backend's parallel-slot count.** For
        llama-server: `services.llama-servers.<name>.parallel`. For
        vLLM: `--max-num-seqs`. Going higher than the backend's slot
        count just queues requests and adds latency; lower wastes
        GPU throughput.

        Per-call ctx requirement is ~4K tokens (chunk 512 + prompt
        ~350 + output cap 1.5K + 20% margin, clamped to floor 4096).
        Per-slot ctx on llama-server = `--ctx-size / --parallel`;
        ensure that's ≥ 4K (and ideally ≥ 8K for healthy headroom on
        recall calls that share the same backend).

        On a 90K/parallel=4 layout each slot gets 22.5K — comfortable
        for both extraction and graph-aware recall.
      '';
    };

    autoAppendDebounceSecs = lib.mkOption {
      type = lib.types.int;
      default = 60;
      example = 30;
      description = ''
        Debounce window for the in-server auto-append coalescer
        (env var `APPEND_DEBOUNCE_SECS`). Every successful new
        ingest signals the coalescer; after this many seconds of
        silence (no new ingests), it runs entity extraction over
        the delta in-process — same code path that
        `POST /api/graph/append` calls.

        * `60` (default) — newly `remember`'d docs become
          graph-queryable in `default`/`local`/`reason` modes
          within ~1 min of the last ingest.
        * Lower (e.g. `15`) — quicker turnaround for interactive
          ingest at the cost of more LLM calls when ingest
          patterns drip rather than burst.
        * `0` — disable the coalescer entirely. Operators then
          drive append manually via `curl -X POST
          /api/graph/append` or an external cron.

        Bursts of ingests (e.g. a `pathsGlob` over a folder)
        collapse into a single append regardless of size — the
        debounce timer resets on every new arrival, so the loop
        only fires once the user has stopped typing for the
        configured window.

        Replaces the previous external `appendInterval` cron
        (graphrag-rs-append.timer) — see graphrag-rs commit
        f454955 for the in-server coalescer that supersedes it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = lib.mkIf cfg.installMcp [ cfg.mcpPackage ];

    xdg.configFile."knowledge-mcp/mcp.json".source = mcpClientConfig;
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
        (lib.mkIf (cfg.embedding.backend == "openai" && cfg.embedding.openai.waitForReady) {
          # Block startup until the OpenAI-compat /models endpoint
          # answers. graphrag-server's embedding probe is one-shot at
          # init (embeddings.rs:194) — if it fires before OVMS/vLLM has
          # bound its port, it silently degrades to hash embeddings for
          # the rest of the process lifetime. Cross-scope ordering on
          # the system-level OVMS unit isn't expressible from a user
          # unit, so we poll instead. Exit 0 on timeout so graphrag-server
          # still starts (matches the explicit-fallback contract).
          ExecStartPre = pkgs.writeShellScript "graphrag-rs-wait-embeddings" ''
            set -u
            export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
            url="${cfg.embedding.openai.url}/models"
            deadline=$(( $(date +%s) + ${toString cfg.embedding.openai.waitTimeoutSeconds} ))
            echo "graphrag-rs: waiting for embedding endpoint $url"
            while [ "$(date +%s)" -lt "$deadline" ]; do
              if ${pkgs.curl}/bin/curl -fs -o /dev/null --max-time 3 "$url"; then
                echo "graphrag-rs: embedding endpoint ready"
                exit 0
              fi
              sleep 2
            done
            echo "graphrag-rs: embedding endpoint did not respond within ${toString cfg.embedding.openai.waitTimeoutSeconds}s; starting anyway (will fall back to hash)"
            exit 0
          '';
        })
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

    # Append cron retired in favor of the in-server coalescer
    # (graphrag-rs commit f454955). graphrag-server now spawns a
    # background tokio task that wakes on every successful ingest,
    # debounces by `autoAppendDebounceSecs`, and runs the append
    # in-process — no curl, no oneshot service, no timer. Set
    # `autoAppendDebounceSecs = 0` if you want to drive append
    # entirely externally.

    # Optional filesystem watcher: keeps the local knowledge graph
    # synced with a set of root directories. Stable doc id =
    # absolute path → server-side upsert-by-user_id handles edits
    # cleanly (new chunks at version+1, prior version's chunks
    # marked superseded; nothing deleted). Off by default.
    systemd.user.services.knowledge-watcher = lib.mkIf cfg.watcher.enable {
      Unit = {
        Description = "knowledge-watcher: keep the local knowledge graph synced with watched folders";
        # Wait for graphrag-rs.service to be Active so the initial
        # walk hits a live server. graphrag-rs.service can come up
        # before this; if knowledge-watcher fails it'll restart.
        Requires = [ "graphrag-rs.service" ];
        After = [ "graphrag-rs.service" ];
      };
      Service = {
        ExecStart = "${cfg.watcher.package}/bin/knowledge-watcher";
        Restart = "on-failure";
        RestartSec = "5s";
        Environment = lib.mapAttrsToList (k: v: "${k}=${v}") {
          WATCHER_BASE_URL = "http://${cfg.host}:${toString cfg.port}";
          WATCHER_ROOTS = lib.concatStringsSep ":" cfg.watcher.watchPaths;
          WATCHER_DEBOUNCE_MS = toString cfg.watcher.debounceMs;
          WATCHER_MAX_IN_FLIGHT = toString cfg.watcher.maxInFlight;
          WATCHER_INITIAL_INDEX = if cfg.watcher.initialIndex then "1" else "0";
          WATCHER_ALLOWED_EXTENSIONS = lib.concatStringsSep "," cfg.watcher.allowedExtensions;
          WATCHER_LOG = cfg.logLevel;
        };
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}

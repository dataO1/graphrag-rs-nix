# NixOS module: NPU-backed embedding service for graphrag-rs.
#
# Stands up:
#   - An OpenVINO Model Server container serving a static-shape embedding
#     model on /v3/embeddings (OpenAI-compatible).
#   - A oneshot that builds the static-shape model + tokenizer + Mediapipe
#     graph the first time it runs (and again when options change).
#   - Optionally a second OVMS on NPU (:9001) for query-only embeddings.
#
# Distilled from the in-house `mneme` flake's openvino.nix.

{ self }:
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkEnableOption mkIf mkMerge mkDefault types;
  inherit (lib) optionalString concatMapStringsSep mapAttrs' nameValuePair optionalAttrs;

  cfg = config.services.graphrag-rs-npu;
  pull = import ./ovms-pull.nix { inherit pkgs lib cfg; };
in
{
  options.services.graphrag-rs-npu = {
    enable = mkEnableOption "graphrag-rs NPU embedding service (OVMS + static-model build)";

    user = mkOption {
      type = types.str;
      default = "graphrag-npu";
      description = ''
        User that owns the OVMS state dir. Set to your login user
        (e.g. "alice") if you want to read/write the model dir directly;
        otherwise the default synthetic system user is created.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "users";
      description = "Group used for state ownership.";
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/graphrag-rs-npu";
      description = "Where the prebuilt static-shape model lives.";
    };

    embeddingModel = mkOption {
      type = types.str;
      default = "mixedbread-ai/mxbai-embed-large-v1";
      description = ''
        HuggingFace repo of the embedding model. Must be a stock-arch
        encoder (BERT, RoBERTa, XLM-RoBERTa, ModernBERT) that
        `optimum-intel` natively supports.
      '';
    };

    embeddingMaxSeqLen = mkOption {
      type = types.int;
      default = 512;
      description = ''
        Static input sequence length baked into the IR. NPU 3 requires
        fully-static shapes; this is the per-request token limit.
      '';
    };

    embeddingPooling = mkOption {
      type = types.enum [ "CLS" "LAST" ];
      default = "CLS";
      description = ''
        Pooling strategy applied by OVMS. Must match what the model was
        trained with. OVMS does not support MEAN.
      '';
    };

    embeddingDevice = mkOption {
      type = types.enum [ "CPU" "GPU" "NPU" "AUTO" ];
      default = "NPU";
      description = "OpenVINO target device.";
    };

    reranker = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Build a second Mediapipe graph for /v3/rerank.";
      };

      model = mkOption {
        type = types.str;
        default = "tomaarsen/Qwen3-Reranker-4B-seq-cls";
        description = "HuggingFace repo of the reranker model.";
      };

      maxSeqLen = mkOption {
        type = types.int;
        default = 1024;
        description = "Tokenizer max length for query+doc.";
      };

      device = mkOption {
        type = types.enum [ "CPU" "GPU" "AUTO" ];
        default = "GPU";
        description = ''
          OpenVINO target device for the rerank model. NPU is rejected —
          OVMS' RerankCalculatorOV does batched [N, seq] inference.
          "GPU" = Intel Arc iGPU (NOT NVIDIA dGPU).
        '';
      };

      numStreams = mkOption {
        type = types.int;
        default = 1;
        description = "Per-model OpenVINO NUM_STREAMS.";
      };

      name = mkOption {
        type = types.str;
        default = "reranker";
        description = "Mediapipe graph name for /v3/rerank.";
      };
    };

    ports = {
      openvino = mkOption {
        type = types.port;
        default = 8000;
        description = "OVMS REST endpoint.";
      };
    };

    queryNpu = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Run a second OVMS instance targeting NPU on port 9001 for
          interactive query embeddings. Extraction stays on the main
          OVMS. Requires `embeddingDevice != "NPU"`.
        '';
      };
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the OVMS port in the firewall.";
    };
  };

  config = mkIf cfg.enable {
    users.users.${cfg.user} = mkMerge [
      (mkIf (cfg.user == "graphrag-npu") {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.stateDir;
        createHome = true;
      })
      { extraGroups = [ "render" "video" ]; }
    ];
    users.groups.graphrag-npu = mkIf (cfg.group == "graphrag-npu") { };

    users.groups.render.gid = mkDefault 303;
    users.groups.video.gid = mkDefault 26;

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -"
      "Z ${cfg.stateDir}/ovms-models 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.stateDir}/ovms-cache 0750 ${cfg.user} ${cfg.group} -"
    ] ++ lib.optionals cfg.queryNpu.enable [
      "d /var/lib/graphrag-rs-npu-query 0750 data01 users -"
      "Z /var/lib/graphrag-rs-npu-query/ovms-models 0750 data01 users -"
    ];

    boot.kernelModules = [ "intel_vpu" ];

    networking.firewall.allowedTCPPorts =
      mkIf cfg.openFirewall [ cfg.ports.openvino ];

    virtualisation.podman.enable = mkDefault true;

    # ── Main pull service ──
    systemd.services."graphrag-ovms-pull" = {
      description = "graphrag-rs-npu: build static-shape embedding model for OVMS";
      wantedBy = [ "podman-graphrag-ovms.service" ];
      before = [ "podman-graphrag-ovms.service" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = "${pull.pullScript}/bin/graphrag-ovms-pull";
        RemainAfterExit = true;
        TimeoutStartSec = "30min";
      };
    };

    # ── Main OVMS container ──
    virtualisation.oci-containers.containers."graphrag-ovms" = {
      image = pull.ovmsImage;
      autoStart = true;
      ports = [ "127.0.0.1:${toString cfg.ports.openvino}:8000" ];
      volumes = [
        "${cfg.stateDir}/ovms-models:/models:ro"
        "${cfg.stateDir}/ovms-cache:/cache:rw"
      ];
      cmd = [ "--rest_port" "8000" "--config_path" "/models/config.json" ];
      extraOptions = [
        "--user=0:0"
        "--device=/dev/accel/accel0"
        "--device=/dev/dri"
        "--group-add=${toString config.users.groups.render.gid}"
        "--group-add=${toString config.users.groups.video.gid}"
      ];
    };

    # ── Query NPU (second OVMS on :9001) ──
    systemd.services."graphrag-ovms-pull-query" = mkIf cfg.queryNpu.enable {
      description = "graphrag-rs-npu: build NPU query-embedding model";
      wantedBy = [ "podman-graphrag-ovms-query.service" ];
      before = [ "podman-graphrag-ovms-query.service" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        RemainAfterExit = true;
        TimeoutStartSec = "30min";
        ExecStart = "${pull.pullScript}/bin/graphrag-ovms-pull";
        Environment = [
          "GRS_MODELS_DIR=/var/lib/graphrag-rs-npu-query/ovms-models"
          "GRS_MODEL=${cfg.embeddingModel}"
          "GRS_SEQ_LEN=${toString cfg.embeddingMaxSeqLen}"
          "GRS_POOLING=${cfg.embeddingPooling}"
          "GRS_DEVICE=NPU"
          "GRS_RERANKER_MODEL="
          "PYTHONPATH=${pull.pullPyExtras}"
          "LD_LIBRARY_PATH=${lib.makeLibraryPath [
            pkgs.stdenv.cc.cc.lib pkgs.zlib pkgs.libffi pkgs.openssl pkgs.glib
          ]}"
        ];
      };
    };

    virtualisation.oci-containers.containers."graphrag-ovms-query" = mkIf cfg.queryNpu.enable {
      image = pull.ovmsImage;
      autoStart = true;
      ports = [ "127.0.0.1:9001:8000" ];
      volumes = [
        "/var/lib/graphrag-rs-npu-query/ovms-models:/models:ro"
        "${cfg.stateDir}/ovms-cache:/cache:rw"
      ];
      cmd = [ "--rest_port" "8000" "--config_path" "/models/config.json" ];
      extraOptions = [
        "--user=0:0"
        "--device=/dev/accel/accel0"
        "--group-add=${toString config.users.groups.render.gid}"
        "--group-add=${toString config.users.groups.video.gid}"
      ];
    };

    # Restart triggers — force OVMS restart when pull script changes
    systemd.services."podman-graphrag-ovms".restartTriggers = [
      pull.pullScript
    ];
    systemd.services."podman-graphrag-ovms-query".restartTriggers = mkIf cfg.queryNpu.enable [
      pull.pullScript
    ];
  };
}

{ self }:
{ config, lib, pkgs, ... }:

# NixOS module: NPU-backed embedding service for graphrag-rs.
#
# Stands up:
#   - An OpenVINO Model Server container serving a static-shape embedding
#     model on /v3/embeddings (OpenAI-compatible).
#   - A oneshot that builds the static-shape model + tokenizer + Mediapipe
#     graph the first time it runs (and again when options change).
#   - Optionally a second OVMS on NPU (:9001) for query-only embeddings.

let
  inherit (lib) mkOption mkEnableOption mkIf mkMerge mkDefault types;
  inherit (lib) optionalString concatMapStringsSep;

  cfg = config.services.graphrag-rs-npu;

  ovmsImage = "openvino/model_server:2026.0-gpu";

  pullPyEnv = pkgs.python3.withPackages (p: with p; [
    openvino
    optimum
    transformers
    pip
  ]);

  pullPyExtras = pkgs.runCommand "graphrag-ovms-pull-pip-extras" {
    nativeBuildInputs = [ pullPyEnv pkgs.cacert ];
    outputHash = "sha256-0EirSnNqdqoSjhlVqkIwGQBvHOg5GhLmaPKl1hkm14M=";
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
  } ''
    mkdir -p $out
    ${pullPyEnv}/bin/python3 -m pip install \
      --target="$out" \
      --no-compile \
      "openvino-tokenizers>=2025.2,<2026.3" \
      "nncf>=2.17"
  '';

  pullPyScript = pkgs.writeText "graphrag-ovms-pull.py" ''
    """Build static-shape OVMS embedding (+ optional rerank) models.
    All paths written relative to GRS_MODELS_DIR so the script can run
    outside a container; OVMS itself mounts that dir at /models."""

    import json
    import os
    import shutil
    import subprocess
    from pathlib import Path

    EMBED_MODEL     = os.environ["GRS_MODEL"]
    EMBED_SEQ_LEN   = int(os.environ["GRS_SEQ_LEN"])
    EMBED_POOLING   = os.environ["GRS_POOLING"]
    EMBED_DEVICE    = os.environ["GRS_DEVICE"]
    RERANK_MODEL    = os.environ.get("GRS_RERANKER_MODEL", "")
    RERANK_SEQ_LEN  = int(os.environ.get("GRS_RERANKER_SEQ_LEN", "1024"))
    RERANK_DEVICE   = os.environ.get("GRS_RERANKER_DEVICE", "GPU")
    RERANK_NUM_STREAMS = int(os.environ.get("GRS_RERANKER_NUM_STREAMS", "1"))
    RERANK_NAME     = os.environ.get("GRS_RERANKER_NAME", "reranker")

    BT = Path("/models")
    HD = Path(os.environ["GRS_MODELS_DIR"])
    STAGING = HD / ".staging"

    EMB = BT / "embeddings"
    HEMB = HD / "embeddings"

    print(f"[embed 1/6] Exporting {EMBED_MODEL} via optimum-cli (INT8) -> {STAGING}")
    subprocess.run([
        "optimum-cli", "export", "openvino",
        "--model", EMBED_MODEL,
        "--task", "feature-extraction",
        "--weight-format", "int8",
        str(STAGING),
    ], check=True)

    print(f"[embed 2/6] Reading IR + reshaping inputs to [1, {EMBED_SEQ_LEN}]")
    import openvino as ov
    core = ov.Core()
    model = core.read_model(str(STAGING / "openvino_model.xml"))
    model.reshape([1, EMBED_SEQ_LEN])

    print(f"[embed 3/6] Saving static IR -> {HEMB}/openvino_model.xml")
    HEMB.mkdir(parents=True, exist_ok=True)
    ov.save_model(model, str(HEMB / "openvino_model.xml"), compress_to_fp16=False)

    print(f"[embed 4/6] Converting tokenizer -> {HEMB}/openvino_tokenizer.{{xml,bin}}")
    from openvino_tokenizers import convert_tokenizer
    from transformers import AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(EMBED_MODEL, trust_remote_code=True)
    ov_tokenizer = convert_tokenizer(tokenizer, model)
    ov.save_model(ov_tokenizer, str(HEMB / "openvino_tokenizer.xml"), compress_to_fp16=False)

    print(f"[embed 5/6] Writing graph.pbtxt (EmbeddingsCalculatorOV, target_device={EMBED_DEVICE}, pooling={EMBED_POOLING})")
    graph_pbtxt = f"""
input_stream: "REQUEST:input"
output_stream: "RESPONSE:output"
node {{
  calculator: "EmbeddingsCalculatorOV"
  input_side_packet: "SESSIONABLE:embedding_model"
  input_stream: "REQUEST:input"
  output_stream: "RESPONSE:output"
  node_options: {{
    [type.googleapis.com/mediapipe.EmbeddingsCalculatorOptions] {{
      model_path: "./"
      target_device: "{EMBED_DEVICE}"
      pooling: "{EMBED_POOLING}"
    }}
  }}
}}
"""
    (HEMB / "graph.pbtxt").write_text(graph_pbtxt.strip())

    if RERANK_MODEL:
        print(f"[rerank 1/3] Exporting {RERANK_MODEL} via optimum-cli -> {STAGING}-rerank")
        subprocess.run([
            "optimum-cli", "export", "openvino",
            "--model", RERANK_MODEL,
            "--task", "text-classification",
            "--weight-format", "int8",
            str(STAGING) + "-rerank",
        ], check=True)

        print(f"[rerank 2/3] Reshaping reranker IR to [1, {RERANK_SEQ_LEN}]")
        rerank_model = core.read_model(str(STAGING) + "-rerank/openvino_model.xml")
        rerank_model.reshape([1, RERANK_SEQ_LEN])

        RR = BT / RERANK_NAME
        HRR = HD / RERANK_NAME
        HRR.mkdir(parents=True, exist_ok=True)
        ov.save_model(rerank_model, str(HRR / "openvino_model.xml"), compress_to_fp16=False)

        print(f"[rerank 3/3] Writing graph.pbtxt (RerankCalculatorOV, target_device={RERANK_DEVICE})")
        rr_graph = f"""
input_stream: "REQUEST:input"
output_stream: "RESPONSE:output"
node {{
  calculator: "RerankCalculatorOV"
  input_side_packet: "SESSIONABLE:rerank_model"
  input_stream: "REQUEST:input"
  output_stream: "RESPONSE:output"
  node_options: {{
    [type.googleapis.com/mediapipe.RerankCalculatorOptions] {{
      model_path: "./"
      target_device: "{RERANK_DEVICE}"
      num_streams: {RERANK_NUM_STREAMS}
    }}
  }}
}}
"""
        (HRR / "graph.pbtxt").write_text(rr_graph.strip())

    config = {
        "model_config_list": [],
        "mediapipe_config_list": [
            {"name": "embeddings", "graph_path": "/models/embeddings/graph.pbtxt"}
        ]
    }
    if RERANK_MODEL:
        config["mediapipe_config_list"].append(
            {"name": RERANK_NAME, "graph_path": f"/models/{RERANK_NAME}/graph.pbtxt"}
        )
    with open(HD / "config.json", "w") as f:
        json.dump(config, f, indent=2)

    print("[done]")
  '';

  rerankerStampPart =
    if cfg.reranker.enable then
      " r_model=${cfg.reranker.model} r_seq=${toString cfg.reranker.maxSeqLen} r_dev=${cfg.reranker.device} r_streams=${toString cfg.reranker.numStreams}"
    else
      " r=disabled";

  pullScript = pkgs.writeShellApplication {
    name = "graphrag-ovms-pull";
    runtimeInputs = [ pullPyEnv pkgs.coreutils ];
    text = ''
      set -euo pipefail
      MODELS_DIR="${cfg.stateDir}/ovms-models"
      STAMP_FILE="$MODELS_DIR/.graphrag-stamp"
      STAMP="model=${cfg.embeddingModel} seq=${toString cfg.embeddingMaxSeqLen} pool=${cfg.embeddingPooling} dev=${cfg.embeddingDevice}${rerankerStampPart} script=${pullPyScript} env=${pullPyEnv} extras=${pullPyExtras}"

      mkdir -p "$MODELS_DIR"

      ARTIFACTS_OK=0
      if [ -f "$MODELS_DIR/config.json" ] && [ -f "$MODELS_DIR/embeddings/openvino_model.xml" ]; then
        ${if cfg.reranker.enable then ''
        if [ -f "$MODELS_DIR/${cfg.reranker.name}/openvino_model.xml" ]; then
          ARTIFACTS_OK=1
        fi
        '' else ''
        ARTIFACTS_OK=1
        ''}
      fi

      if [ "$ARTIFACTS_OK" = "1" ] \
         && [ -f "$STAMP_FILE" ] \
         && [ "$(cat "$STAMP_FILE")" = "$STAMP" ]; then
        echo "[graphrag-ovms-pull] config matches stamp, skipping rebuild."
        echo "  $STAMP"
        exit 0
      fi

      echo "[graphrag-ovms-pull] Building OVMS models:"
      echo "  $STAMP"

      env \
        GRS_MODELS_DIR="$MODELS_DIR" \
        GRS_MODEL="${cfg.embeddingModel}" \
        GRS_SEQ_LEN="${toString cfg.embeddingMaxSeqLen}" \
        GRS_POOLING="${cfg.embeddingPooling}" \
        GRS_DEVICE="${cfg.embeddingDevice}" \
        GRS_RERANKER_MODEL="${if cfg.reranker.enable then cfg.reranker.model else ""}" \
        GRS_RERANKER_SEQ_LEN="${toString cfg.reranker.maxSeqLen}" \
        GRS_RERANKER_DEVICE="${cfg.reranker.device}" \
        GRS_RERANKER_NUM_STREAMS="${toString cfg.reranker.numStreams}" \
        GRS_RERANKER_NAME="${cfg.reranker.name}" \
        PYTHONPATH=${pullPyExtras} \
        LD_LIBRARY_PATH=${lib.makeLibraryPath [
          pkgs.stdenv.cc.cc.lib
          pkgs.zlib
          pkgs.libffi
          pkgs.openssl
          pkgs.glib
        ]} \
        ${pullPyEnv}/bin/python3 ${pullPyScript}

      echo "$STAMP" > "$STAMP_FILE"

      if ${pkgs.systemd}/bin/systemctl is-active --quiet podman-graphrag-ovms.service; then
        echo "[graphrag-ovms-pull] Enqueueing OVMS restart (no-block)..."
        ${pkgs.systemd}/bin/systemctl --no-block restart podman-graphrag-ovms.service || true
      fi

      echo "[graphrag-ovms-pull] Done."
    '';
  };
in
{
  options.services.graphrag-rs-npu = {
    enable = mkEnableOption "graphrag-rs NPU embedding service (OVMS + static-model build)";

    user = mkOption {
      type = types.str;
      default = "graphrag-npu";
      description = "User that owns the OVMS state dir.";
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
      description = "HuggingFace repo of the embedding model.";
    };

    embeddingMaxSeqLen = mkOption {
      type = types.int;
      default = 512;
      description = "Static input sequence length baked into the IR.";
    };

    embeddingPooling = mkOption {
      type = types.enum [ "CLS" "LAST" ];
      default = "CLS";
      description = "Pooling strategy. OVMS does not support MEAN.";
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
        description = "OpenVINO target device. GPU = Intel Arc iGPU.";
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

    systemd.services."graphrag-ovms-pull" = {
      description = "graphrag-rs-npu: build static-shape embedding model for OVMS";
      wantedBy = [ "podman-graphrag-ovms.service" ];
      before = [ "podman-graphrag-ovms.service" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = "${pullScript}/bin/graphrag-ovms-pull";
        RemainAfterExit = true;
        TimeoutStartSec = "30min";
      };
    };

    virtualisation.oci-containers.containers."graphrag-ovms" = {
      image = ovmsImage;
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
        ExecStart = "${pullScript}/bin/graphrag-ovms-pull";
        Environment = [
          "GRS_MODELS_DIR=/var/lib/graphrag-rs-npu-query/ovms-models"
          "GRS_MODEL=${cfg.embeddingModel}"
          "GRS_SEQ_LEN=${toString cfg.embeddingMaxSeqLen}"
          "GRS_POOLING=${cfg.embeddingPooling}"
          "GRS_DEVICE=NPU"
          "GRS_RERANKER_MODEL="
          "PYTHONPATH=${pullPyExtras}"
          "LD_LIBRARY_PATH=${lib.makeLibraryPath [
            pkgs.stdenv.cc.cc.lib pkgs.zlib pkgs.libffi pkgs.openssl pkgs.glib
          ]}"
        ];
      };
    };

    virtualisation.oci-containers.containers."graphrag-ovms-query" = mkIf cfg.queryNpu.enable {
      image = ovmsImage;
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

    systemd.services."podman-graphrag-ovms".restartTriggers = [ pullScript ];
    systemd.services."podman-graphrag-ovms-query".restartTriggers = mkIf cfg.queryNpu.enable [ pullScript ];
  };
}

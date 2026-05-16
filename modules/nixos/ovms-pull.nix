# OVMS model pull infrastructure.
#
# Returns:
#   ovmsImage   — OVMS container image tag
#   pullScript  — oneshot that builds static-shape IR + Mediapipe graph
#
# Called from default.nix with { pkgs, lib, cfg } where cfg =
# config.services.graphrag-rs-npu. The pull script references cfg
# for model/stamp/pooling/device/reranker options so it self-rebuilds
# when those change.

{ pkgs, lib, cfg }:

let
  ovmsImage = "openvino/model_server:2026.0-gpu";

  # Host Python env for the pull script. Three of the heavy deps
  # (openvino, optimum, transformers) ship in nixpkgs and come pre-built
  # from cache.nixos.org — no PyPI roundtrip, no pip resolver. The two
  # missing ones (openvino-tokenizers, nncf) come from a tiny
  # fixed-output `pip install --no-deps` further down. Result: pull runs
  # natively on the host (no podman, no `python:3.12-slim` cold-pip),
  # using the binary cache for everything heavy.
  pullPyEnv = pkgs.python3.withPackages (p: with p; [
    openvino
    optimum
    transformers
    pip      # only used by the `pullPyExtras` derivation below
  ]);

  # The two pip-only deps. Tiny (a few MB each) because we use
  # `--no-deps` — their transitive closure (torch, openvino, etc.) is
  # already provided by `pullPyEnv` from nixpkgs. Pinned loosely to
  # nixpkgs' openvino major to avoid ABI drift between the two.
  #
  # Fixed-output derivation: nix allows network access for these only
  # because we promise the result hash matches `outputHash`. First
  # build fails with the real hash; copy it into outputHash, rebuild,
  # locked. Re-run any time the version constraints below change.
  pullPyExtras = pkgs.runCommand "graphrag-ovms-pull-pip-extras" {
    nativeBuildInputs = [ pullPyEnv pkgs.cacert ];
    outputHash = "";
    outputHashAlgo = "sha256";
  } ''
    # install into $out
    mkdir -p $out
    # `--no-compile` skips .pyc bytecode generation. Without it, pip
    # bakes build timestamps into bytecode → non-deterministic output
    # → fixed-output hash drifts between builds. .pyc is regenerated
    # at first import on the consumer side; no functional difference.
    # Install with full deps (no --no-deps). Earlier iterations tried
    # to be clever — install only the 2 missing packages, rely on
    # nixpkgs for the transitive closure. That spiraled into a
    # whack-a-mole exercise (rich, ml-dtypes, optimum-onnx, … all
    # missing piecewise) and the nixpkgs openvino 2025.2 was too old
    # for optimum-intel 1.27 anyway. Cleanest: pip resolves the full
    # closure once. Output is larger (~few hundred MB) but
    # deterministic, fully self-contained, no nixpkgs version clashes.
    ${pullPyEnv}/bin/python3 -m pip install \
      --target="$out" \
      --no-compile \
      "openvino-tokenizers>=2025.2,<2026.3" \
      "nncf>=2.17"
  ''
  # FOD contract: zero references to other /nix/store paths.
  # postBuild verifies (catches accidental absolute paths). If
  # something leaks a store path into a .dist-info/RECORD or an
  # .npy/.pickle, `grep` catches it and we fix the offending dep.
  // {
    postBuild = ''
      echo "Checking for /nix/store references in pip extras..."
      if grep -qr /nix/store "$out"; then
        echo "ERROR: pullPyExtras still has /nix/store references ↑" >&2
        exit 1
      fi
      echo "OK: no /nix/store references in pip extras"
    '';
  };

  # In-container Python that builds the static-shape OVMS model:
  #   1. optimum-cli export <MODEL> → staging (FP/INT8 IR, dynamic shapes)
  #   2. OpenVINO Python API reshape → static [1, seq]
  #   3. ov.save_model → final IR
  #   4. openvino_tokenizers → tokenizer + detokenizer IR
  #   5. config.json + graph.pbtxt → OVMS Mediapipe graph definition
  #   6. Symlink staging → final model directory.
  #
  # Pipeline mirrors the OVMS upstream `export_model.py {embeddings_ov,rerank_ov}`
  # flows but stays in this single script so we don't pull in the OVMS demo
  # tree's dependency chain (mediapipe, etc.) at build time.
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

    # GRS_MODELS_DIR is the host path (e.g. /var/lib/graphrag-rs-npu/ovms-models).
    # We write everything relative to it but the graph paths below still use the
    # in-OVMS-container path "/models" so the script still works if
    # invoked from inside a container too. The caller mounts
    # the actual host dir (services.graphrag-rs-npu.stateDir/ovms-models).
    # The hardcoded "/models" references in config.json + graph.pbtxt
    BT = Path("/models")
    HD = Path(os.environ["GRS_MODELS_DIR"])
    STAGING = HD / ".staging"

    # ── embeddings model ──
    # Each Mediapipe graph's node_options.models_path is "./" relative to the
    # graph name. OVMS resolves the calculator's `models_path: "./"`
    # against /models/<graph_name>/ on disk. So we MUST place
    # openvino_model.xml directly inside /models/embeddings/ — not in
    # a numbered sub-version directory. If the file isn't at
    #   /models/embeddings/openvino_model.xml
    # OVMS fails with:
    #   ir: Could not open the file: "/models/<graph_name>/./openvino_model.xml"
    EMB = BT / "embeddings"
    HEMB = HD / "embeddings"

    print(f"[embed 1/6] Exporting {EMBED_MODEL} via optimum-cli (INT8) → {STAGING}")
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

    print(f"[embed 3/6] Saving static IR → {HEMB}/openvino_model.xml")
    HEMB.mkdir(parents=True, exist_ok=True)
    ov.save_model(model, str(HEMB / "openvino_model.xml"), compress_to_fp16=False)

    print(f"[embed 4/6] Converting tokenizer → {HEMB}/openvino_tokenizer.{'{xml,bin}'}")
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

    # ── reranker model (only if GRS_RERANKER_MODEL is non-empty) ──
    if RERANK_MODEL:
        print(f"[rerank 1/3] Exporting {RERANK_MODEL} via optimum-cli → {STAGING}-rerank")
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

    # ── config.json ──
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

  # Stamp fragment that forces a rebuild when reranker options change.
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
      # Stamp includes the pull script's nix store path AND the python
      # env's path. Any change to either (script content, dep set, dep
      # versions) → new store hash → invalidated stamp → rebuild.
      STAMP="model=${cfg.embeddingModel} seq=${toString cfg.embeddingMaxSeqLen} pool=${cfg.embeddingPooling} dev=${cfg.embeddingDevice}${rerankerStampPart} script=${pullPyScript} env=${pullPyEnv} extras=${pullPyExtras}"

      mkdir -p "$MODELS_DIR"

      # All artifacts present + stamp unchanged ⇒ skip rebuild.
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
{ inherit ovmsImage pullScript pullPyExtras pullPyEnv; }

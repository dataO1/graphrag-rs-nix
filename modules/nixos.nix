{ self }:
{ config, lib, pkgs, ... }:

# NixOS module: NPU-backed embedding service for graphrag-rs.
#
# Stands up:
#   - An OpenVINO Model Server container serving a static-shape embedding
#     model on /v3/embeddings (OpenAI-compatible).
#   - A oneshot that builds the static-shape model + tokenizer + Mediapipe
#     graph the first time it runs (and again whenever model/seq_len/pooling
#     /device options change).
#
# Distilled from the in-house `mneme` flake's openvino.nix. Generalized
# (drops mneme's vault-mcp/qdrant integration and excludePatterns/etc. that
# were specific to mneme's home-walking indexer) so this flake stands alone.
#
# Pair with the home-manager module's `services.graphrag-rs.embedding.backend
# = "ollama"` once the Ollama→OVMS shim is also deployed (TODO). Until then,
# the OVMS endpoint at http://127.0.0.1:<ports.openvino>/v3/embeddings is
# OpenAI-compatible and can be hit directly by anything that supports the
# OpenAI embeddings API.

let
  cfg = config.services.graphrag-rs-npu;

  # NPU support requires the -gpu image variant; the plain image is CPU-only.
  ovmsImage = "openvino/model_server:2026.0-gpu";
  pythonImage = "python:3.12-slim";

  # In-container Python that builds the static-shape OVMS model:
  #   1. optimum-cli export <MODEL> → staging (FP/INT8 IR, dynamic shapes)
  #   2. core.read_model + reshape to [1, SEQ_LEN] → static IR
  #   3. Convert HF tokenizer → OV tokenizer + detokenizer (with padding
  #      forced to SEQ_LEN — required for static shapes on NPU 3)
  #   4. Hand-write Mediapipe graph.pbtxt (EmbeddingsCalculatorOV)
  #   5. Hand-write models/config.json referencing the graph
  pullPyScript = pkgs.writeText "graphrag-ovms-pull.py" ''
    """Build static-shape OVMS embedding (+ optional rerank) models.

    Pipeline mirrors the OVMS upstream `export_model.py {embeddings_ov,rerank_ov}`
    flows but stays in this single script so we don't pull in the OVMS demo
    repo. Both halves write into the same /models tree and produce one
    `config.json` whose `mediapipe_config_list` lists every graph.

    See nixos.nix header for context.
    """
    import json
    import os
    import shutil
    import subprocess
    from pathlib import Path

    EMBED_MODEL = os.environ["GRS_MODEL"]
    EMBED_SEQ_LEN = int(os.environ["GRS_SEQ_LEN"])
    EMBED_POOLING = os.environ["GRS_POOLING"]
    EMBED_DEVICE = os.environ["GRS_DEVICE"]

    # Reranker is optional. When `GRS_RERANKER_MODEL` is empty the rerank
    # branch is skipped entirely and the resulting config has only the
    # embeddings graph (back-compat with deployments that haven't opted in).
    RERANK_MODEL = os.environ.get("GRS_RERANKER_MODEL", "")
    RERANK_SEQ_LEN = int(os.environ.get("GRS_RERANKER_SEQ_LEN", "512"))
    RERANK_DEVICE = os.environ.get("GRS_RERANKER_DEVICE", "CPU")
    RERANK_NUM_STREAMS = os.environ.get("GRS_RERANKER_NUM_STREAMS", "1")
    RERANK_NAME = os.environ.get("GRS_RERANKER_NAME", "reranker")

    MODELS = Path("/models")
    STAGING = MODELS / ".staging"
    EMB = MODELS / "embeddings"
    # The rerank directory MUST be named the same as the mediapipe
    # graph name. OVMS resolves the calculator's `models_path: "./"`
    # against `/models/<graph_name>/`, NOT against the directory of
    # `graph_path` in the config. Mismatch produces:
    #   ir: Could not open the file: "/models/<graph_name>/./openvino_model.xml"
    # The embeddings setup gets away with `embeddings` matching `embeddings`
    # by accident; we make it explicit here.
    RR = MODELS / RERANK_NAME

    if STAGING.exists():
        shutil.rmtree(STAGING)
    if EMB.exists():
        shutil.rmtree(EMB)
    EMB.mkdir(parents=True)
    if RERANK_MODEL:
        if RR.exists():
            shutil.rmtree(RR)
        RR.mkdir(parents=True)

    # ────────────────────────── EMBEDDING ──────────────────────────
    print(f"[embed 1/6] Exporting {EMBED_MODEL} via optimum-cli (INT8) → {STAGING}")
    subprocess.check_call([
        "optimum-cli", "export", "openvino",
        "--model", EMBED_MODEL,
        "--task", "feature-extraction",
        "--weight-format", "int8",
        "--library", "transformers",
        "--trust-remote-code",
        str(STAGING),
    ])

    import openvino as ov
    core = ov.Core()
    print(f"[embed 2/6] Reading IR + reshaping inputs to [1, {EMBED_SEQ_LEN}]")
    model = core.read_model(str(STAGING / "openvino_model.xml"))
    model.reshape({p.get_any_name(): [1, EMBED_SEQ_LEN] for p in model.inputs})

    print(f"[embed 3/6] Saving static IR → {EMB}/openvino_model.xml")
    ov.save_model(model, str(EMB / "openvino_model.xml"), compress_to_fp16=False)

    print("[embed 4/6] Converting HF tokenizer → OpenVINO tokenizer + detokenizer")
    from openvino_tokenizers import convert_tokenizer
    from transformers import AutoTokenizer
    hf_tok = AutoTokenizer.from_pretrained(EMBED_MODEL, trust_remote_code=True)
    # Force max_length so the converted OV tokenizer pads to that shape. NPU 3
    # needs every input tensor at compile-time-known shapes; without this,
    # short inputs become e.g. [1, 7] and the EmbeddingsCalculatorOV's
    # RET_CHECK fails when feeding the static [1, SEQ_LEN] model.
    hf_tok.model_max_length = EMBED_SEQ_LEN
    for kwargs in [
        dict(with_detokenizer=True, use_max_padding=True),
        dict(with_detokenizer=True, max_length=EMBED_SEQ_LEN, use_max_padding=True),
        dict(with_detokenizer=True, max_length=EMBED_SEQ_LEN, pad_to_max_length=True, truncation=True),
        dict(with_detokenizer=True),
    ]:
        try:
            ov_tok, ov_detok = convert_tokenizer(hf_tok, **kwargs)
            print(f"  convert_tokenizer kwargs that worked: {sorted(kwargs)}")
            break
        except TypeError as e:
            print(f"  convert_tokenizer rejected {sorted(kwargs)}: {e}")
            continue
    else:
        raise RuntimeError("no convert_tokenizer parameter set succeeded")
    ov.save_model(ov_tok,   str(EMB / "openvino_tokenizer.xml"))
    ov.save_model(ov_detok, str(EMB / "openvino_detokenizer.xml"))

    print(f"[embed 5/6] Writing graph.pbtxt (EmbeddingsCalculatorOV, target_device={EMBED_DEVICE}, pooling={EMBED_POOLING})")
    graph_pbtxt = (
        "# Generated by graphrag-rs-npu (nixos module)\n"
        f"# model={EMBED_MODEL} seq_len={EMBED_SEQ_LEN} pooling={EMBED_POOLING} device={EMBED_DEVICE}\n"
        "input_stream: \"REQUEST_PAYLOAD:input\"\n"
        "output_stream: \"RESPONSE_PAYLOAD:output\"\n"
        "node {\n"
        f"    name: \"{EMBED_MODEL}\",\n"
        "    calculator: \"EmbeddingsCalculatorOV\"\n"
        "    input_side_packet: \"EMBEDDINGS_NODE_RESOURCES:embeddings_servable\"\n"
        "    input_stream: \"REQUEST_PAYLOAD:input\"\n"
        "    output_stream: \"RESPONSE_PAYLOAD:output\"\n"
        "    node_options: {\n"
        "        [type.googleapis.com / mediapipe.EmbeddingsCalculatorOVOptions]: {\n"
        "            models_path: \"./\",\n"
        "            normalize_embeddings: true,\n"
        # truncate=true clips/pads inputs to the model's static seq_len.
        # Required for NPU 3 (baked-static shapes); harmless on dynamic IRs.
        "            truncate: true,\n"
        f"            pooling: {EMBED_POOLING},\n"
        f"            target_device: \"{EMBED_DEVICE}\",\n"
        # CACHE_DIR persists OpenVINO JIT-compiled kernels across
        # OVMS restarts. First-ever start still pays the compile
        # cost; every subsequent start (rebuild, OOM, reboot)
        # restores from cache in ~ms instead of seconds-to-minutes.
        # Per-graph subdir avoids cross-model cache poisoning.
        "            plugin_config: '{\"NUM_STREAMS\":\"1\",\"CACHE_DIR\":\"/cache/embeddings\"}',\n"
        "        }\n"
        "    }\n"
        "}\n"
    )
    (EMB / "graph.pbtxt").write_text(graph_pbtxt)
    print("[embed 6/6] Embeddings artifacts ready.")
    shutil.rmtree(STAGING, ignore_errors=True)

    # ────────────────────────── RERANKER ──────────────────────────
    # Mirrors OVMS upstream `export_model.py rerank_ov` recipe
    # (https://github.com/openvinotoolkit/model_server/blob/main/demos/common/export_models/export_model.py).
    # Dynamic-shape model + tokenizer, no static reshape, no padding
    # kwargs — that's what `RerankCalculatorOV` expects. Earlier
    # attempts to make this work on NPU via static-shape reshape +
    # forced tokenizer padding were abandoned 2026-05-08: the
    # calculator does a single batched forward pass per HTTP request
    # ([N, seq] → set_tensor → infer in `rerank_calculator_ov.cc`),
    # which is fundamentally incompatible with NPU's batch=1 compile
    # constraint. Use `target_device: "GPU"` (Intel Arc iGPU on the
    # Arrow Lake-HX SoC; idle, separate from any NVIDIA dGPU; OVMS'
    # rerank demo documents CPU/GPU only).
    mediapipe_entries = [
        {"name": "embeddings", "graph_path": "/models/embeddings/graph.pbtxt"}
    ]

    if RERANK_MODEL:
        if RERANK_DEVICE == "NPU":
            raise RuntimeError(
                "reranker.device=NPU is unsupported by OVMS' RerankCalculatorOV "
                "(single batched [N,seq] forward pass per request conflicts with "
                "NPU's batch=1 compile constraint; OVMS' own rerank demo only "
                "documents CPU/GPU). Use 'GPU' (Intel Arc iGPU on the SoC, idle "
                "and separate from any NVIDIA dGPU) or 'CPU'. The embedder "
                "still runs on NPU happily — that path IS upstream-validated."
            )

        print(f"[rerank 1/3] Exporting {RERANK_MODEL} via optimum-cli (INT8, text-classification) → {STAGING}")
        if STAGING.exists():
            shutil.rmtree(STAGING)
        # `text-classification` is the OVMS-canonical task for
        # cross-encoders. The seq-cls community variants of Qwen3-Reranker
        # (`tomaarsen/Qwen3-Reranker-{0.6B,4B,8B}-seq-cls`) map cleanly
        # to this task. The official `Qwen/Qwen3-Reranker-*` repos are
        # CausalLMs that score via "yes"/"no" token logits — that path
        # needs OpenVINO GenAI's `TextRerankPipeline`, NOT OVMS.
        subprocess.check_call([
            "optimum-cli", "export", "openvino",
            "--model", RERANK_MODEL,
            "--task", "text-classification",
            "--weight-format", "int8",
            "--library", "transformers",
            "--trust-remote-code",
            "--disable-convert-tokenizer",  # we convert it ourselves below
            str(STAGING),
        ])

        print(f"[rerank 2/3] Moving rerank IR + converting tokenizer → {RR}")
        # Move the rerank model directly — no reshape, no compress-to-fp16.
        # The IR's input shapes stay dynamic so the calculator can pass
        # whatever [N, seq] tensor it builds from the request to the
        # iGPU/CPU plugin (both honor dynamic shapes natively).
        shutil.move(str(STAGING / "openvino_model.xml"), str(RR / "openvino_model.xml"))
        shutil.move(str(STAGING / "openvino_model.bin"), str(RR / "openvino_model.bin"))

        # Tokenizer: match upstream OVMS' `export_rerank_tokenizer`.
        # Just `add_special_tokens=False` — the calculator inserts the
        # special tokens itself. No padding kwargs (model is dynamic,
        # iGPU/CPU honor the runtime shape).
        rhf_tok = AutoTokenizer.from_pretrained(RERANK_MODEL, trust_remote_code=True)
        rhf_tok.model_max_length = RERANK_SEQ_LEN
        rov_tok = convert_tokenizer(rhf_tok, add_special_tokens=False)
        if isinstance(rov_tok, tuple):
            rov_tok = rov_tok[0]
        ov.save_model(rov_tok, str(RR / "openvino_tokenizer.xml"))

        print(f"[rerank 3/3] Writing graph.pbtxt (RerankCalculatorOV, target_device={RERANK_DEVICE})")
        # RerankCalculatorOV is the simple single-calculator form (mirrors
        # EmbeddingsCalculatorOV's shape). The OVMS export script also
        # offers a two-servable form (`RerankCalculator`) where tokenizer
        # and rerank are separate `OpenVINOModelServerSessionCalculator`s
        # behind a `subconfig.json`. We use the single-calculator form
        # for parity with our embedder graph.
        rgraph_pbtxt = (
            "# Generated by graphrag-rs-npu (nixos module)\n"
            f"# model={RERANK_MODEL} seq_len={RERANK_SEQ_LEN} device={RERANK_DEVICE} num_streams={RERANK_NUM_STREAMS}\n"
            "input_stream: \"REQUEST_PAYLOAD:input\"\n"
            "output_stream: \"RESPONSE_PAYLOAD:output\"\n"
            "node {\n"
            f"    name: \"{RERANK_MODEL}\",\n"
            "    calculator: \"RerankCalculatorOV\"\n"
            "    input_side_packet: \"RERANK_NODE_RESOURCES:rerank_servable\"\n"
            "    input_stream: \"REQUEST_PAYLOAD:input\"\n"
            "    output_stream: \"RESPONSE_PAYLOAD:output\"\n"
            "    node_options: {\n"
            "        [type.googleapis.com / mediapipe.RerankCalculatorOVOptions]: {\n"
            "            models_path: \"./\",\n"
            f"            target_device: \"{RERANK_DEVICE}\",\n"
            # CACHE_DIR mirrors the embedder graph above — persists
            # OpenVINO JIT kernels across OVMS restarts. Saves ~5–10 s
            # of cold-start latency on every restart of the 4B model.
            f"            plugin_config: '{{\"NUM_STREAMS\":\"{RERANK_NUM_STREAMS}\",\"CACHE_DIR\":\"/cache/{RERANK_NAME}\"}}',\n"
            "        }\n"
            "    }\n"
            "}\n"
        )
        (RR / "graph.pbtxt").write_text(rgraph_pbtxt)

        mediapipe_entries.append(
            {"name": RERANK_NAME, "graph_path": f"/models/{RERANK_NAME}/graph.pbtxt"}
        )
        shutil.rmtree(STAGING, ignore_errors=True)

    # ────────────────────────── CONFIG ─────────────────────────────
    print(f"[config] Writing /models/config.json with {len(mediapipe_entries)} graph(s)")
    config = {
        "model_config_list": [],
        "mediapipe_config_list": mediapipe_entries,
    }
    (MODELS / "config.json").write_text(json.dumps(config, indent=2))

    print("Done.")
  '';

  # Idempotent wrapper around the export container. The stamp file encodes
  # (embed model + seq + pool + device, plus reranker model + seq + device
  # if enabled). Rebuild kicks in whenever any tracked field changes — so
  # toggling the reranker on, swapping its model, or moving it CPU↔NPU all
  # trigger a rebuild and OVMS restart on the next deploy.
  rerankerStampPart =
    if cfg.reranker.enable then
      " r_model=${cfg.reranker.model} r_seq=${toString cfg.reranker.maxSeqLen} r_dev=${cfg.reranker.device} r_streams=${toString cfg.reranker.numStreams}"
    else
      " r=disabled";

  pullScript = pkgs.writeShellApplication {
    name = "graphrag-ovms-pull";
    runtimeInputs = [ pkgs.podman pkgs.coreutils ];
    text = ''
      set -euo pipefail
      MODELS_DIR="${cfg.stateDir}/ovms-models"
      STAMP_FILE="$MODELS_DIR/.graphrag-stamp"
      # Stamp includes the pull script's nix store path. Any change to
      # the script content (export task, reshape logic, tokenizer kwargs,
      # etc.) → new store hash → invalidated stamp → rebuild. Without
      # this, edits to pullPyScript that don't touch the cfg.* values
      # silently kept stale artifacts on disk (hit this 2026-05-08 when
      # a rerank tokenizer kwargs fix didn't apply because the cfg
      # values hadn't changed).
      STAMP="model=${cfg.embeddingModel} seq=${toString cfg.embeddingMaxSeqLen} pool=${cfg.embeddingPooling} dev=${cfg.embeddingDevice}${rerankerStampPart} script=${pullPyScript}"

      mkdir -p "$MODELS_DIR"

      # All artifacts present + stamp unchanged ⇒ skip rebuild. The
      # reranker artifact check is conditional on whether the reranker is
      # enabled in this build's config.
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

      ${pkgs.podman}/bin/podman run --rm \
        --user=0:0 \
        --workdir /tmp \
        -v "$MODELS_DIR":/models:rw \
        -v ${pullPyScript}:/pull.py:ro \
        -e GRS_MODEL="${cfg.embeddingModel}" \
        -e GRS_SEQ_LEN="${toString cfg.embeddingMaxSeqLen}" \
        -e GRS_POOLING="${cfg.embeddingPooling}" \
        -e GRS_DEVICE="${cfg.embeddingDevice}" \
        -e GRS_RERANKER_MODEL="${if cfg.reranker.enable then cfg.reranker.model else ""}" \
        -e GRS_RERANKER_SEQ_LEN="${toString cfg.reranker.maxSeqLen}" \
        -e GRS_RERANKER_DEVICE="${cfg.reranker.device}" \
        -e GRS_RERANKER_NUM_STREAMS="${toString cfg.reranker.numStreams}" \
        -e GRS_RERANKER_NAME="${cfg.reranker.name}" \
        -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
        ${pythonImage} \
        bash -c '
          set -e
          echo "Installing optimum[openvino] + openvino-tokenizers..."
          pip install --quiet --no-warn-script-location \
            "optimum[openvino]>=1.20" "openvino-tokenizers" "transformers"
          python3 /pull.py
        '

      echo "$STAMP" > "$STAMP_FILE"

      # Artifacts on disk were just rebuilt. If OVMS is already running
      # from a previous deploy, it's still holding the OLD artifacts in
      # memory — kick it so the new model graphs are picked up.
      # Best-effort: a fresh boot won't have OVMS running yet, in which
      # case `is-active` returns false and we skip silently. The
      # `wantedBy` / `before` ordering on the unit handles the cold-
      # start case independently.
      #
      # CRITICAL: must use `--no-block` here. Without it, `systemctl
      # restart` blocks waiting for the OVMS unit to reach active. But
      # the OVMS unit has `before=graphrag-ovms-pull` ordering — its
      # restart job is queued behind THIS pull job's completion. So
      # blocking creates a deadlock: pull waits for OVMS active, OVMS
      # waits for pull to finish. Hit this in production 2026-05-08;
      # fix is to enqueue the restart and let our own ExecStart return.
      if ${pkgs.systemd}/bin/systemctl is-active --quiet podman-graphrag-ovms.service; then
        echo "[graphrag-ovms-pull] Enqueueing OVMS restart (no-block) so the new artifacts get picked up..."
        ${pkgs.systemd}/bin/systemctl --no-block restart podman-graphrag-ovms.service || true
      fi

      echo "[graphrag-ovms-pull] Done."
    '';
  };
in
{
  options.services.graphrag-rs-npu = {
    enable = lib.mkEnableOption "graphrag-rs NPU embedding service (OVMS + static-model build)";

    user = lib.mkOption {
      type = lib.types.str;
      default = "graphrag-npu";
      description = ''
        User that owns the OVMS state dir. Set to your login user
        (e.g. "alice") if you want to read/write the model dir directly;
        otherwise the default synthetic system user is created.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "users";
      description = "Group used for state ownership. Defaults to \"users\" so a normal login user has access.";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/graphrag-rs-npu";
      description = "Where the prebuilt static-shape model lives.";
    };

    embeddingModel = lib.mkOption {
      type = lib.types.str;
      default = "mixedbread-ai/mxbai-embed-large-v1";
      description = ''
        HuggingFace repo of the embedding model. Must be a stock-arch
        encoder (BERT, RoBERTa, XLM-RoBERTa, ModernBERT) that
        `optimum-intel` natively supports, with a pooling strategy that
        matches `embeddingPooling` (CLS or LAST — OVMS does not support MEAN).

        Default mxbai-embed-large-v1: 335M params, 512 ctx, native CLS
        pooling, 1024 dim, MTEB ~64.7. Verified to compile on Arrow Lake
        NPU 3 (per the in-house `npu-diagnose.sh static-search`).

        IMPORTANT: this model's output dimension MUST match the
        `services.graphrag-rs.embedding.dimension` set in the home-manager
        module (passed as EMBEDDING_DIM env var to graphrag-server).
        Mismatched dims silently corrupt the Qdrant collection.
      '';
    };

    embeddingMaxSeqLen = lib.mkOption {
      type = lib.types.int;
      default = 512;
      description = ''
        Static input sequence length baked into the IR before NPU compile.
        NPU 3 (Arrow Lake) requires fully-static shapes; this is the
        per-request token limit. Pick the largest your model+NPU pair
        handles. ModernBERT-style models have been verified at 2048.
      '';
    };

    embeddingPooling = lib.mkOption {
      type = lib.types.enum [ "CLS" "LAST" ];
      default = "CLS";
      description = ''
        Pooling strategy applied by OVMS before returning the embedding.
        Must match what the model was trained with — using CLS on a
        MEAN-trained model degrades quality significantly. OVMS does not
        support MEAN.
      '';
    };

    embeddingDevice = lib.mkOption {
      type = lib.types.enum [ "CPU" "GPU" "NPU" "AUTO" ];
      default = "NPU";
      description = ''
        OpenVINO target device. Fall back to "CPU" if the model fails to
        load on NPU (NPU 3 requires fully-static shapes; some models can't
        be reshaped successfully).
      '';
    };

    reranker = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Build a second Mediapipe graph in the same OVMS instance that
          serves a cross-encoder reranker on `/v3/rerank`. Disabled by
          default — opt-in once the chosen reranker model is verified
          to compile on the target device. When enabled, the same
          `graphrag-ovms-pull` oneshot exports both models and the
          OVMS process picks them both up via `mediapipe_config_list`.

          See `GraphRAG-rs Reranker Model Selection.md` in the vault for
          the picking-the-model exercise. The default model is the OVMS-
          friendly seq-cls variant of Qwen3-Reranker-0.6B.
        '';
      };

      model = lib.mkOption {
        type = lib.types.str;
        default = "tomaarsen/Qwen3-Reranker-4B-seq-cls";
        description = ''
          HuggingFace repo of the reranker model. Must support
          `optimum-cli export openvino --task text-classification` —
          i.e. a sequence-classification head over an
          encoder/cross-encoder backbone, OR a community-converted
          seq-cls variant of a decoder-style reranker.

          Tested values:
            - `tomaarsen/Qwen3-Reranker-4B-seq-cls` (default; Qwen3-4B
              with cls head; INT8 ≈ 4 GB; MTEB-R 69.76 — top local
              score; multilingual incl. DE; targets iGPU which has
              dynamic system-RAM allocation, not NPU's fixed budget).
            - `tomaarsen/Qwen3-Reranker-0.6B-seq-cls` (lighter — INT8
              ≈ 600 MB — for low-memory deploys).
            - `BAAI/bge-reranker-v2-m3` (XLM-RoBERTa cross-encoder;
              568 M params; INT8 ≈ 570 MB; OVMS rerank-demo reference).

          AVOID: the official `Qwen/Qwen3-Reranker-*` repos (CausalLMs
          that score via "yes"/"no" token logits — need OpenVINO
          GenAI's `TextRerankPipeline`, NOT OVMS' `RerankCalculatorOV`).
        '';
      };

      maxSeqLen = lib.mkOption {
        type = lib.types.int;
        default = 1024;
        description = ''
          Sets `tokenizer.model_max_length` — i.e. the upper bound at
          which the tokenizer truncates inputs. Cross-encoders see
          `[CLS] query [SEP] document` packed into one sequence, so
          this must accommodate query+doc tokens together. With the
          NPU path retired this is no longer a static-shape constraint
          on the IR; it's just the tokenizer's truncation cap.

          Default 1024 covers a query (~50 tokens) + a ~1500-character
          chunk excerpt (~400 tokens) with substantial headroom. Raise
          if you ingest long-form prose; lower for tighter RAG budgets.
        '';
      };

      device = lib.mkOption {
        type = lib.types.enum [ "CPU" "GPU" "AUTO" ];
        default = "GPU";
        description = ''
          OpenVINO target device for the rerank model. NPU is rejected
          by the build script — OVMS' `RerankCalculatorOV` does a
          single batched `[N, seq] → set_tensor → infer` per HTTP
          request, which is fundamentally incompatible with NPU's
          batch=1 compile constraint. OVMS' own rerank demo only
          documents CPU/GPU. (Verified 2026-05-08; see
          `rerank_calculator_ov.cc` upstream + research notes in the
          vault doc `GraphRAG-rs Reranker Model Selection.md`.)

          "GPU" = the Intel Arc iGPU on the Arrow Lake-HX SoC,
          which is otherwise idle on this hardware. NOT the NVIDIA
          dGPU — OpenVINO has no NVIDIA backend. Picking "GPU" leaves
          the NPU 100% dedicated to the embedder (the path that IS
          upstream-validated).

          "CPU" works too but with much higher latency; reserve for
          fallback or single-machine debug.
        '';
      };

      numStreams = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = ''
          Per-model OpenVINO `NUM_STREAMS` (parallel execution streams
          inside the rerank model). NPU's optimal is 1; raise to 2-4
          on CPU/GPU to overlap independent batches. The OVMS upstream
          script defaults to 1 too.
        '';
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "reranker";
        description = ''
          Mediapipe graph name = the `model` field clients send in the
          `/v3/rerank` request body. Matches what graphrag-server's
          `services.graphrag-rs.reranker.model` posts. Keep "reranker"
          unless you have a specific reason to rename — it's referenced
          in stamp metadata and not auto-discovered.
        '';
      };
    };

    ports = {
      openvino = lib.mkOption {
        type = lib.types.port;
        default = 8000;
        description = "OVMS REST endpoint (OpenAI-compatible /v3/embeddings).";
      };
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the OVMS port in the firewall (default: localhost-only).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Synthetic system user; real login users must already exist (we just
    # ensure render/video group membership for NPU access).
    users.users.${cfg.user} = lib.mkMerge [
      (lib.mkIf (cfg.user == "graphrag-npu") {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.stateDir;
        createHome = true;
      })
      { extraGroups = [ "render" "video" ]; }
    ];
    users.groups.graphrag-npu = lib.mkIf (cfg.group == "graphrag-npu") { };

    # Pin render/video GIDs so the OVMS container's --group-add references
    # stay correct. Conventional NixOS values; mkDefault means any other
    # module can override.
    users.groups.render.gid = lib.mkDefault 303;
    users.groups.video.gid = lib.mkDefault 26;

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -"
      "Z ${cfg.stateDir}/ovms-models 0750 ${cfg.user} ${cfg.group} -"
      # OpenVINO plugin compile cache. CACHE_DIR in plugin_config
      # persists JIT-compiled kernels across OVMS restarts so we
      # only pay the kernel-compile cost once per model+device. The
      # OVMS container mounts this rw at /cache (the models dir
      # stays ro for safety).
      "d ${cfg.stateDir}/ovms-cache 0750 ${cfg.user} ${cfg.group} -"
    ];

    # NPU kernel driver.
    boot.kernelModules = [ "intel_vpu" ];

    networking.firewall.allowedTCPPorts =
      lib.mkIf cfg.openFirewall [ cfg.ports.openvino ];

    virtualisation.podman.enable = lib.mkDefault true;

    # Pull oneshot: builds the static-shape model + tokenizer + graph at
    # first run (and whenever the stamped options change). Decoupled from
    # OVMS — runs once, OVMS then serves.
    systemd.services."graphrag-ovms-pull" = {
      description = "graphrag-rs-npu: build static-shape embedding model for OVMS";
      wantedBy = [ "podman-graphrag-ovms.service" ];
      before = [ "podman-graphrag-ovms.service" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        # Root: drives rootful podman + writes to the bind-mounted models dir.
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
        # rw mount for the OpenVINO plugin compile cache (CACHE_DIR
        # in plugin_config). Persists JIT kernels across OVMS
        # restarts.
        "${cfg.stateDir}/ovms-cache:/cache:rw"
      ];
      cmd = [
        "--rest_port" "8000"
        "--config_path" "/models/config.json"
      ];
      extraOptions = [
        "--user=0:0"
        # NPU access (Intel VPU driver, kernel module `intel_vpu`)
        "--device=/dev/accel/accel0"
        # Intel iGPU access — required when reranker.device = "GPU"
        # (or "AUTO"). The container also needs /dev/dri/card* so the
        # OpenCL/L0 driver inside OpenVINO can probe the iGPU. Without
        # this, the GPU plugin fails at servable load with:
        #   [GPU] Can't get PERFORMANCE_HINT property as no supported
        #         devices found...
        # We pass all DRI render nodes (host has 128 + 129 — usually
        # 128=Intel iGPU, 129=NVIDIA dGPU but OpenVINO only enumerates
        # Intel devices, so passing the dGPU node is harmless).
        "--device=/dev/dri"
        "--group-add=${toString config.users.groups.render.gid}"
        "--group-add=${toString config.users.groups.video.gid}"
      ];
    };

    # Force OVMS to restart on every nixos-rebuild that touches the
    # pull pipeline. Without this, the chain breaks: pullPyScript edits
    # change pullScript → graphrag-ovms-pull.service config → but the
    # OVMS container config is unchanged, so systemd never restarts
    # OVMS, so pull (wantedBy = OVMS) never gets pulled in. Result:
    # new artifacts on disk, OVMS still serving the old ones in
    # memory. Hit this 2026-05-08; manual `systemctl start
    # graphrag-ovms-pull.service` was the workaround.
    #
    # restartTriggers takes a list whose hash, when changed, marks the
    # unit for restart on activation. Embedding pullScript's store
    # path means any change to the script (or any of its inputs)
    # forces OVMS restart, which triggers pull via wantedBy.
    systemd.services."podman-graphrag-ovms".restartTriggers = [
      pullScript
    ];
  };
}

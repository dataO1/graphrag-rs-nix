# Local Model Recommendations — graphrag-rs on neo-16

**Hardware:** RTX 5090 Laptop (Blackwell sm_120, 24 GB VRAM, NVFP4/MXFP4/FP8/INT4), Intel Core Ultra 9 275HX (NPU 4 used by OpenVINO embeddings), 96 GB DDR5.
**Last reviewed:** 2026-05-04.
**Quality > speed.** Verified live against HF / NVIDIA / Qwen / Ollama.

## Top-10 chat / extraction LLMs for graphrag-rs (24 GB)

| # | Model (params) | Best quant for 24 GB | VRAM @ 32k | Max ctx (pure GPU) | Modality (in → out) | Key benchmarks | Why ranked here | Pull |
|---|---|---|---|---|---|---|---|---|
| 1 | **Qwen3.6-35B-A3B** (35B/3B MoE) | UD-Q4_K_XL ≈ 22 GB / MXFP4_MOE | ~23 GB | ~96k | T/I/V → T | flagship-tier coding + agent (beats Qwen3.5-397B MoE on agentic) | best quality-per-VRAM that still fully fits; 1M ctx with YaRN | `Qwen/Qwen3.6-35B-A3B` |
| 2 | **Nemotron-3-Nano-Omni-30B-A3B-Reasoning** (31B/3B MoE) | **NVFP4 20.9 GB** (Blackwell-native) | ~22 GB | 128–256k | **T/I/V/A → T** + ASR + tools | MMLongBench-Doc 57.5, Video-MME 72.2, VoiceBench 89.4, ASR WER 5.95, OSWorld 47.4 | only model handling full PDF + image + video + audio in one pass on this GPU; NVFP4 lossless on sm_120 | `nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-NVFP4` |
| 3 | Qwen3-Next-80B-A3B-Thinking | Q3_K_M + ~25 GB CPU offload | ~24 GB GPU + 25 GB RAM | 64k offloaded | T → T | RULER-256k strong | best reasoning if you tolerate offload | `Qwen/Qwen3-Next-80B-A3B-Thinking` |
| 4 | GLM-4.6 | Q2_K_XL heavy offload | 24 GB GPU + 60 GB RAM | 32k | T → T | top open agent | only via heavy offload on 24 GB | `zai-org/GLM-4.6` |
| 5 | DeepSeek-V4-Flash | Q3_K_M offload | 24 GB GPU + 30 GB RAM | 64k | T → T | strong reasoning, fast | speed pick under offload | `deepseek-ai/DeepSeek-V4-Flash` |
| 6 | GLM-4.5-Air | Q4_K_M ~22 GB | ~23 GB | 128k | T → T | balanced agent | fully on-GPU agent, no multimodal | `zai-org/GLM-4.5-Air-GGUF` |
| 7 | **Qwen3.6-27B** (dense 27.8B) | UD-Q4_K_XL **17.6 GB** | ~19 GB | **~128k pure GPU** | T/I/V → T | MMLU-Pro 86.2, GPQA-D 87.8, AIME 94.1, SWE-bench 77.2, Terminal-Bench 59.3 | best **dense** model that fully fits with huge KV headroom; cleanest quant behavior; 1M YaRN | `Qwen/Qwen3.6-27B` |
| 8 | Qwen3-VL-30B-A3B-Instruct | Q4_K_M ~18 GB | ~20 GB | 128k | T/I/V → T | MMMU strong | superseded by Nemotron-Omni for omni; Qwen-family VL fallback | `Qwen/Qwen3-VL-30B-A3B-Instruct` |
| 9 | Mistral Small 4 (~24B dense) | Q5_K_M ~18 GB | ~20 GB | 128k | T → T | strong instruction | EU-friendly fully-on-GPU | `mistralai/Mistral-Small-4-Instruct` |
| 10 | Gemma 4 31B | Q4_K_M ~19 GB | ~22 GB | 128k | T/I → T | strong multilingual | fully on-GPU dense alt | `google/gemma-4-31b-it` |

## Embedding model

| Model | Dim | Max seq | MTEB / MMTEB | Verdict |
|---|---|---|---|---|
| **Qwen3-Embedding-8B** *(current, on NPU via OVMS)* | 32–4096 (Matryoshka) | 32k | EN 75.22, multi 70.58, code 80.68 | **Keep** |
| Llama-Embed-Nemotron-8B | 4096 | 8k | #1 MMTEB Borda | upgrade only if heavily multilingual |
| Jina-Embeddings-v4 | 2048 | 32k | text + image co-embed | pilot if visual-doc retrieval added |

## Quantization on Blackwell sm_120

- **NVFP4** (native tensor-core path on llama.cpp ≥ b8967, vLLM ≥ 0.17): ≈ −0.4 pp vs BF16 (essentially lossless), fastest on this GPU. Prefer when a vendor-published NVFP4 quant exists.
- **MXFP4** also accelerated; works in ik_llama.cpp ≥ b8196.
- **Unsloth UD-Q4_K_XL / Q4_K_M GGUF**: still excellent, slightly larger files, fine when no NVFP4 quant is published.
- For single-user latency Q4_K_M can edge NVFP4 by ~24–30 % on decode; for batch/multi-stream, NVFP4 wins overall.

## Multimodal pairing (graphrag-rs ingest)

- **Always-loaded daily driver**: Qwen3.6-27B (or Qwen3.6-35B-A3B) — coding, chat, text extraction, light image/PDF screenshots.
- **On-demand multimodal preprocessor**: Nemotron-3-Nano-Omni-NVFP4 — PDF/image/video/audio → markdown → feed `mcp__graphrag__add_document` (the MCP only ingests text).
- **Embeddings**: Qwen3-Embedding-8B on NPU (unchanged).

## Watch list (≤30 days)

- Gemma 4 family (Apr 2)
- Qwen3.6 family — 27B dense and 35B-A3B MoE (Apr 21–22)
- DeepSeek V4 preview (Apr 24)
- Nemotron-3 Nano Omni (Apr 28)
- llama.cpp b8967 NVFP4 MMQ for sm_120 (Apr 29)

## Laptop thermals

Sustained 24 GB at full load hits the 175 W TGP cap; expect 10–15 % decode loss after ~60 s. Stand + external blower + flat fan curve recommended. Partial-offload paths push Arrow Lake-HX SOC harder than the GPU — budget ~20 % loss on multi-minute batch runs. The NPU embedding path is independent of CUDA, no contention.

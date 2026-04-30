#!/usr/bin/env bash
# graphrag-e2e.sh — End-to-end diagnostic test suite for graphrag-rs
# Usage: ./graphrag-e2e.sh [--reset] [--cleanup] [--verbose]

set -o pipefail

# --- Configuration ---
BASE_URL="${GRAPHRAG_URL:-http://127.0.0.1:8080}"
NPU_URL="${NPU_URL:-http://127.0.0.1:9000}"
# Default to the local LLM router on :17170 (services.llm-router) which
# multiplexes whichever backend is currently up — vLLM on :8000,
# llama-server on :17171, etc. Test 4 just probes /models and runs a
# small generation, so it doesn't need to know which backend is live.
# Override with LLM_URL=http://127.0.0.1:17171/v1 to test the
# llama-server-direct path that graphrag-server itself talks to.
LLM_URL="${LLM_URL:-http://127.0.0.1:17170/v1}"
LLM_MODEL="${LLM_MODEL:-local-llm}"
QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"
CURL="/run/current-system/sw/bin/curl"
NODE="/etc/profiles/per-user/data01/bin/node"

# --- Helpers ---
PASS=0
FAIL=0
WARN=0
VERBOSE=false
RESET=false
CLEANUP=false

log_pass()  { echo "  ✅ PASS  — $1"; PASS=$((PASS + 1)); }
log_fail()  { echo "  ❌ FAIL  — $1"; FAIL=$((FAIL + 1)); }
log_warn()  { echo "  ⚠️  WARN  — $1"; WARN=$((WARN + 1)); }
log_info()  { echo "  ℹ️  INFO  — $1"; }
log_step()  { echo; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; echo "  $1"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

parse_json() {
  $NODE -e "console.log(JSON.stringify(JSON.parse(process.argv[1]).$2))" "$1" 2>/dev/null
}

jq_field() {
  local result
  result=$($NODE -e "console.log(JSON.parse(process.argv[1]).$2)" "$1" 2>/dev/null) || echo ""
  echo "$result"
}

http_get() {
  $CURL -sf "$1" 2>&1
}

http_post() {
  $CURL -sf "$1" -X POST -H 'Content-Type: application/json' -d "$2" 2>&1
}

http_delete() {
  $CURL -sf "$1" -X DELETE 2>&1
}

# --- NPU + timing helpers ---
NPU_BUSY_FILE="/sys/class/accel/accel0/device/npu_busy_time_us"

npu_busy() {
  if [ -r "$NPU_BUSY_FILE" ]; then cat "$NPU_BUSY_FILE"; else echo "-1"; fi
}
now_ms() {
  # date +%s%3N is GNU-only; coreutils on NixOS has it. Falls back to seconds.
  date +%s%3N 2>/dev/null || echo $(( $(date +%s) * 1000 ))
}
# Format a (start_npu, end_npu, start_ms, end_ms) tuple into a one-liner.
# Marks the embedding source by NPU delta: ≥1ms NPU work ⇒ NPU/OVMS, else
# either fallback hash or a cached path. Reads /api/embeddings/stats for
# the authoritative backend name (after rebuild — handler is new in this
# graphrag-rs commit).
fmt_call_perf() {
  local b0=$1 b1=$2 t0=$3 t1=$4
  local req_ms=$(( t1 - t0 ))
  if [ "$b0" = "-1" ] || [ "$b1" = "-1" ]; then
    echo "${req_ms}ms (NPU counter unavailable)"
  else
    local npu_us=$(( b1 - b0 ))
    local npu_ms=$(( npu_us / 1000 ))
    if [ "$npu_us" -ge 1000 ] 2>/dev/null; then
      echo "${req_ms}ms wall (NPU +${npu_ms}ms = ${npu_us}us — OVMS path)"
    else
      echo "${req_ms}ms wall (NPU Δ${npu_us}us — hash/cache path)"
    fi
  fi
}
# Best-effort: hit /api/embeddings/stats. If the endpoint isn't there
# yet (older server build), return empty so callers can degrade.
embed_source() {
  $CURL -sf --max-time 2 "$BASE_URL/api/embeddings/stats" 2>/dev/null || echo ""
}

# --- Parse args ---
for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=true ;;
    --reset) RESET=true ;;
    --cleanup) CLEANUP=true ;;
    --help|-h)
      echo "Usage: $0 [--reset] [--cleanup] [--verbose]"
      echo "  --reset    Reset graph (delete all documents and rebuild)"
      echo "  --cleanup  Delete test documents after running"
      echo "  --verbose  Show raw HTTP responses"
      exit 0
      ;;
  esac
done

echo "============================================================"
echo "  GraphRAG-RS End-to-End Diagnostic Suite"
echo "  Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  Target: $BASE_URL"
echo "============================================================"

# ============================================================
# TEST 1: Service Health
# ============================================================
log_step "TEST 1 — Service Health"

RESPONSE=$(http_get "$BASE_URL/health") || { log_fail "Service unreachable"; echo "$RESPONSE"; exit 1; }
log_pass "Health endpoint responds"

if [ "$VERBOSE" = true ]; then echo "$RESPONSE" | head -1; fi

STATUS=$(jq_field "$RESPONSE" "status")
DOC_COUNT=$(jq_field "$RESPONSE" "documentCount")
GRAPH_BUILT=$(jq_field "$RESPONSE" "graphBuilt")
BACKEND=$(jq_field "$RESPONSE" "backend")
log_info "Status: $STATUS | Docs: ${DOC_COUNT:-0} | Graph: ${GRAPH_BUILT:-unknown} | Backend: ${BACKEND:-unknown}"

# ============================================================
# TEST 2: Configuration Check
# ============================================================
log_step "TEST 2 — Configuration"

CONFIG=$(http_get "$BASE_URL/config") || { log_fail "/config unreachable"; exit 1; }

# Check OpenAI chat backend
OA_TIMEOUT=$(jq_field "$CONFIG" "config.openai.timeout_seconds")
OA_ENABLED=$(jq_field "$CONFIG" "config.openai.enabled")
OA_MODEL=$(jq_field "$CONFIG" "config.openai.chat_model")
OA_URL=$(jq_field "$CONFIG" "config.openai.base_url")

log_info "OpenAI backend: enabled=$OA_ENABLED model=$OA_MODEL url=$OA_URL timeout=${OA_TIMEOUT}s"

if [ "$OA_ENABLED" != "true" ]; then
  log_fail "OpenAI chat backend not enabled"
else
  if [ -n "$OA_TIMEOUT" ] && [ "$OA_TIMEOUT" != "" ] && [ "$OA_TIMEOUT" -lt 300 ] 2>/dev/null; then
    log_warn "OpenAI timeout is ${OA_TIMEOUT}s (recommend >= 300s for 27B models)"
  elif [ -n "$OA_TIMEOUT" ]; then
    log_pass "OpenAI timeout adequate (${OA_TIMEOUT}s)"
  else
    log_warn "Could not parse timeout_seconds"
  fi
fi

# Check embedding config
EMB_BACKEND=$(jq_field "$CONFIG" "config.embeddings.backend")
EMB_DIM=$(jq_field "$CONFIG" "config.embeddings.dimension")
log_info "Embeddings (graphrag-core internal config): backend=$EMB_BACKEND dim=$EMB_DIM"
# The /config struct is graphrag-core's *internal* embedding config —
# NOT the runtime path graphrag-server actually uses for /api/documents
# and /api/query (which goes through EmbeddingService). The new
# /api/embeddings/stats endpoint reports the latter. Older server builds
# without the endpoint return empty here.
EMB_STATS_INIT=$(embed_source)
if [ -n "$EMB_STATS_INIT" ]; then
  EMB_RUNTIME_BACKEND=$(jq_field "$EMB_STATS_INIT" "backend")
  EMB_RUNTIME_DIM=$(jq_field "$EMB_STATS_INIT" "dimension")
  EMB_REQS_BEFORE=$(jq_field "$EMB_STATS_INIT" "stats.total_requests")
  log_info "Embeddings (runtime EmbeddingService): backend=$EMB_RUNTIME_BACKEND dim=$EMB_RUNTIME_DIM total_requests=$EMB_REQS_BEFORE"
  case "$EMB_RUNTIME_BACKEND" in
    openai)         log_pass "Runtime embedding backend = openai (OVMS / NPU expected)" ;;
    ollama)         log_pass "Runtime embedding backend = ollama" ;;
    hash-fallback)  log_warn "Runtime embedding backend = hash-fallback (OVMS unreachable at startup?)" ;;
    *)              log_warn "Runtime embedding backend = '$EMB_RUNTIME_BACKEND' (unknown)" ;;
  esac
else
  EMB_REQS_BEFORE=""
  log_info "Embeddings: /api/embeddings/stats not exposed (older server build)"
fi

# ============================================================
# TEST 3: NPU Embedding Service (OVMS)
# ============================================================
log_step "TEST 3 — NPU Embedding Service (OVMS)"

# Check if OVMS is reachable. OVMS doesn't expose /health; the standard
# KFServing readiness endpoint is /v2/health/ready (returns 200 when
# every loaded model reports READY).
NPU_HEALTH=$(http_get "$NPU_URL/v2/health/ready" 2>&1)
if [ -n "${NPU_HEALTH:-}" ] || $CURL -sf -o /dev/null "$NPU_URL/v2/health/ready"; then
  log_pass "OVMS health check passed"
  if [ "$VERBOSE" = true ]; then echo "$NPU_HEALTH" | head -1; fi
else
  log_fail "OVMS unreachable at $NPU_URL"
  log_info "Embeddings will fall back to hash mode"
fi

# Test actual embedding generation. graphrag-rs-npu mounts the Mediapipe
# graph at /v3 (see flake.nix:218), not /v1.
log_info "Sending test embedding request..."
EMB_RESPONSE=$(http_post "$NPU_URL/v3/embeddings" '{
  "model": "embeddings",
  "input": "test sentence for NPU embedding"
}' 2>&1)

if [ -n "${EMB_RESPONSE:-}" ]; then
  log_pass "OVMS /embeddings endpoint responds"
  if [ "$VERBOSE" = true ]; then echo "$EMB_RESPONSE" | head -1; fi
else
  log_warn "OVMS /embeddings endpoint failed (may be normal depending on route)"
fi

# ============================================================
# TEST 4: LLM backend reachability + a quick generation probe
# ============================================================
# By default LLM_URL points at the local LLM router (:17170) which
# multiplexes vLLM / llama-server / etc. behind a stable model name.
# The router's response shape is OpenAI-compatible, so this same
# test works whether the active backend is vLLM (Magistral, Qwen,
# …) or a llama-server build. Override LLM_URL=…:17171/v1 to hit
# llama-server directly.
log_step "TEST 4 — LLM Backend ($LLM_URL)"

LLM_MODELS=$(http_get "$LLM_URL/models" 2>/dev/null) || {
  log_fail "LLM endpoint unreachable at $LLM_URL"
  SKIP_LLM=true
}

if [ -n "${LLM_MODELS:-}" ]; then
  log_pass "LLM endpoint reachable"
  MODEL_LIST=$(jq_field "$LLM_MODELS" "data[0].id" 2>/dev/null || echo "unknown")
  log_info "First reported model id: $MODEL_LIST"
  log_info "Probe will request model: $LLM_MODEL  (override via env LLM_MODEL=…)"

  # Quick generation test. Use the configured LLM_MODEL — the router
  # exposes stable ids ("local-llm", "local-magistral", "local-qwen3.6")
  # rather than whatever model the active backend reports, so we don't
  # have to follow GGUF/AWQ name churn here.
  #
  # max_tokens is generous (200) so a reasoning model can finish its
  # thinking and still emit "hello" before the cap. We deliberately do
  # NOT send chat_template_kwargs here — vLLM with Mistral tokenizers
  # rejects it (400 "chat_template is not supported for Mistral
  # tokenizers"), and Qwen3 / DeepSeek tokenizers handle reasoning
  # within a generous budget. graphrag-server itself sets
  # extra_body.chat_template_kwargs for its own Qwen3 path; that's a
  # separate concern from this smoke test.
  log_info "Running quick LLM generation test..."
  GEN_TEST=$(http_post "$LLM_URL/chat/completions" "{
    \"model\": \"$LLM_MODEL\",
    \"messages\": [{\"role\":\"user\",\"content\":\"Reply with only the word hello, lowercase, no punctuation.\"}],
    \"max_tokens\": 200,
    \"temperature\": 0
  }" 2>/dev/null)

  if [ -n "${GEN_TEST:-}" ]; then
    GEN_CONTENT=$(echo "$GEN_TEST" | $NODE -e "const r=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); console.log(r.choices?.[0]?.message?.content || 'empty')" 2>/dev/null)
    if [ -n "${GEN_CONTENT:-}" ] && [ "$GEN_CONTENT" != "empty" ]; then
      log_pass "LLM generation works (got response: $GEN_CONTENT)"
    else
      log_warn "LLM returned empty response"
    fi
  else
    log_warn "LLM generation test timed out or failed"
  fi
fi

# ============================================================
# TEST 5: Qdrant Vector Store
# ============================================================
log_step "TEST 5 — Qdrant Vector Store"

QDRANT_INFO=$(http_get "$QDRANT_URL/collections" 2>/dev/null) || {
  log_fail "Qdrant unreachable at $QDRANT_URL"
}

if [ -n "${QDRANT_INFO:-}" ]; then
  log_pass "Qdrant reachable"
  # Qdrant /collections wraps results under .result.collections, not
  # .collections at the root.
  COLLECTIONS=$(echo "$QDRANT_INFO" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).result?.collections?.map(c=>c.name).join(', ') || 'none')" 2>/dev/null)
  log_info "Collections: $COLLECTIONS"
fi

# ============================================================
# TEST 6: Document Ingestion
# ============================================================
log_step "TEST 6 — Document Ingestion"

# Ingest document 1: Transformer Architecture
DOC1_ID="e2e-test-transformer-$$"
DOC1_NPU_BEFORE=$(npu_busy); DOC1_T0=$(now_ms)
DOC1_RESPONSE=$(http_post "$BASE_URL/api/documents" "{
  \"id\": \"$DOC1_ID\",
  \"title\": \"Transformer Architecture\",
  \"content\": \"The Transformer architecture, introduced by Vaswani et al. in 2017, revolutionized natural language processing by replacing recurrent neural networks with self-attention mechanisms. This architecture became the foundation for BERT, GPT, and subsequent large language models. The key insight was that attention allows the model to focus on relevant parts of the input sequence regardless of their distance, enabling parallel computation and better long-range dependency modeling. Multi-head attention further improved this by allowing the model to attend to different representations simultaneously. Self-attention computes pairwise interactions between all positions in the sequence, enabling the model to capture long-range dependencies that are difficult for recurrent architectures.\"
}" 2>&1)
DOC1_T1=$(now_ms); DOC1_NPU_AFTER=$(npu_busy)

if [ -n "${DOC1_RESPONSE}" ] && echo "$DOC1_RESPONSE" | grep -q '"success":true'; then
  log_pass "Document 1 ingested (Transformer)"
  DOC1_DOCID=$(echo "$DOC1_RESPONSE" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).documentId)" 2>/dev/null)
  log_info "  Document ID: $DOC1_DOCID"
  log_info "  Perf: $(fmt_call_perf "$DOC1_NPU_BEFORE" "$DOC1_NPU_AFTER" "$DOC1_T0" "$DOC1_T1")"
else
  log_fail "Document 1 ingestion failed: $DOC1_RESPONSE"
fi

sleep 1

# Ingest document 2: Large Language Models
DOC2_ID="e2e-test-llm-$$"
DOC2_NPU_BEFORE=$(npu_busy); DOC2_T0=$(now_ms)
DOC2_RESPONSE=$(http_post "$BASE_URL/api/documents" "{
  \"id\": \"$DOC2_ID\",
  \"title\": \"Large Language Models Survey\",
  \"content\": \"Large Language Models (LLMs) like GPT-4, Claude, and Llama have demonstrated remarkable capabilities across diverse tasks. These models are trained on massive text corpora using autoregressive next-token prediction. Key techniques include attention mechanisms, residual connections, layer normalization, and massive parallel training on GPU clusters. The scaling laws discovered by Kaplan et al. show that model performance improves predictably with compute, data, and parameter count. Recent advances include mixture-of-experts architectures, which activate only a subset of parameters per token, enabling larger models at lower inference cost. Retrieval Augmented Generation (RAG) combines LLMs with external knowledge bases to reduce hallucination and improve factual accuracy. Graph-based RAG systems further enhance this by building knowledge graphs from documents and using graph traversal for retrieval.\"
}" 2>&1)
DOC2_T1=$(now_ms); DOC2_NPU_AFTER=$(npu_busy)

if [ -n "${DOC2_RESPONSE}" ] && echo "$DOC2_RESPONSE" | grep -q '"success":true'; then
  log_pass "Document 2 ingested (LLM Survey)"
  DOC2_DOCID=$(echo "$DOC2_RESPONSE" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).documentId)" 2>/dev/null)
  log_info "  Document ID: $DOC2_DOCID"
  log_info "  Perf: $(fmt_call_perf "$DOC2_NPU_BEFORE" "$DOC2_NPU_AFTER" "$DOC2_T0" "$DOC2_T1")"
else
  log_fail "Document 2 ingestion failed: $DOC2_RESPONSE"
fi

# Show the embedding-service request counter delta to confirm both
# ingests went through the runtime EmbeddingService (and not, e.g., a
# Qdrant-only fast path that would skip embedding entirely).
EMB_STATS_AFTER_INGEST=$(embed_source)
if [ -n "$EMB_STATS_AFTER_INGEST" ] && [ -n "$EMB_REQS_BEFORE" ]; then
  EMB_REQS_AFTER=$(jq_field "$EMB_STATS_AFTER_INGEST" "stats.total_requests")
  EMB_DELTA=$(( EMB_REQS_AFTER - EMB_REQS_BEFORE ))
  log_info "EmbeddingService total_requests delta after ingest: +$EMB_DELTA"
fi

# Verify documents are in Qdrant
sleep 2
HEALTH_AFTER=$(http_get "$BASE_URL/health")
DOC_COUNT_AFTER=$(jq_field "$HEALTH_AFTER" "documentCount" 2>/dev/null || echo "0")
log_info "Documents in store after ingestion: $DOC_COUNT_AFTER"

if [ "$DOC_COUNT_AFTER" -ge 2 ]; then
  log_pass "Both documents visible in store"
else
  log_warn "Only $DOC_COUNT_AFTER documents visible (may include pre-existing docs)"
fi

# ============================================================
# TEST 7: Hydration Round-Trip (Phase G + H restart-survival proxy)
# ============================================================
# Runs FIRST (before the expensive build) so the build can be skipped
# when the entity graph already exists in the Qdrant sidecars. POST
# /config replays the same hydration code path the systemd unit fires
# on every boot, without the operational risk of restarting the unit
# mid-traffic.
log_step "TEST 7 — Hydration Round-Trip (POST /config replays restart)"

PRE_STATS=$(http_get "$BASE_URL/api/graph/stats" 2>&1)
PRE_ENT=$(echo "$PRE_STATS" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).entityCount ?? 0)" 2>/dev/null)
PRE_REL=$(echo "$PRE_STATS" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).relationshipCount ?? 0)" 2>/dev/null)
PRE_DOC=$(echo "$PRE_STATS" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).documentCount ?? 0)" 2>/dev/null)
log_info "Pre-restart in-memory: documentCount=$PRE_DOC entityCount=$PRE_ENT relationshipCount=$PRE_REL"

# The IN-MEMORY pre-stats are NOT the right reference for this test.
# build_graph populates in-memory by calling KnowledgeGraph::add_entity
# directly, which appends a fresh petgraph node every time — including
# duplicates with the same entity id. Same for relationships. So
# in-memory may have e.g. 161 entity nodes that condense to 63 unique
# ids on persist (UUID5 over entity.id collides → one Qdrant point
# per id). Hydration restores from the sidecar = the unique-id view,
# so the pre/post comparison would falsely flag the dedup as a
# regression.
#
# Instead, we read the SIDECAR counts directly from Qdrant. They're
# the canonical "what would survive a restart" view, and what
# hydration must round-trip exactly.
SIDE_ENT=$($CURL -sf "$QDRANT_URL/collections/graphrag-entities" 2>/dev/null | $NODE -e "
  try { console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).result?.points_count ?? 0); } catch (e) { console.log(0); }
" 2>/dev/null)
SIDE_REL=$($CURL -sf "$QDRANT_URL/collections/graphrag-relationships" 2>/dev/null | $NODE -e "
  try { console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).result?.points_count ?? 0); } catch (e) { console.log(0); }
" 2>/dev/null)
log_info "Sidecar (truth): graphrag-entities=$SIDE_ENT graphrag-relationships=$SIDE_REL"

CFG_RESP=$(http_get "$BASE_URL/config" 2>&1)
CFG_INNER=$(echo "$CFG_RESP" | $NODE -e "
  try {
    const r = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
    console.log(JSON.stringify(r.config));
  } catch (e) { console.log(''); }
" 2>/dev/null)

HYDRATION_ENT=0
HYDRATION_REL=0

if [ -z "$CFG_INNER" ] || [ "$CFG_INNER" = "null" ] || [ "$CFG_INNER" = "undefined" ]; then
  log_warn "GET /config returned no live config; skipping round-trip (POST /config not yet fired by ExecStartPost?)"
else
  HYD_T0=$(now_ms)
  HYD_RESP=$(http_post "$BASE_URL/config" "$CFG_INNER" 2>&1)
  HYD_T1=$(now_ms)

  if [ -z "$HYD_RESP" ] || ! echo "$HYD_RESP" | grep -q '"success":true'; then
    log_fail "POST /config failed: $(echo "$HYD_RESP" | head -c 200)"
  else
    log_pass "POST /config round-trip succeeded ($((HYD_T1 - HYD_T0))ms)"

    HYD_FIELDS=$(echo "$HYD_RESP" | $NODE -e "
      try {
        const r = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
        const h = r.hydrated || {};
        console.log(\`documents=\${h.documents ?? '?'} chunks=\${h.chunks ?? '?'} entities=\${h.entities ?? '?'} relationships=\${h.relationships ?? '?'} skipped=\${h.skipped ?? '?'} orphans=\${h.relationships_skipped_orphan ?? '?'}\`);
      } catch (e) { console.log(''); }
    " 2>/dev/null)
    HYDRATION_ENT=$(echo "$HYD_RESP" | $NODE -e "
      try { console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).hydrated?.entities ?? 0); } catch (e) { console.log(0); }
    " 2>/dev/null)
    HYDRATION_REL=$(echo "$HYD_RESP" | $NODE -e "
      try { console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).hydrated?.relationships ?? 0); } catch (e) { console.log(0); }
    " 2>/dev/null)

    if [ -n "$HYD_FIELDS" ] && ! echo "$HYD_FIELDS" | grep -q 'entities=?'; then
      log_pass "hydrated summary present in response"
      log_info "  Hydrated: $HYD_FIELDS"
    else
      log_warn "POST /config response missing hydrated summary (older server build?)"
    fi

    POST_STATS=$(http_get "$BASE_URL/api/graph/stats" 2>&1)
    POST_ENT=$(echo "$POST_STATS" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).entityCount ?? 0)" 2>/dev/null)
    POST_REL=$(echo "$POST_STATS" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).relationshipCount ?? 0)" 2>/dev/null)
    POST_DOC=$(echo "$POST_STATS" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).documentCount ?? 0)" 2>/dev/null)
    log_info "Post-restart: documentCount=$POST_DOC entityCount=$POST_ENT relationshipCount=$POST_REL"

    # documentCount comparison stays against in-memory pre — chunks
    # are deterministically rebuilt from text, no dedup quirks.
    if [ "${POST_DOC:-0}" -ge "$((PRE_DOC - 1))" ] 2>/dev/null; then
      log_pass "documentCount survived round-trip ($PRE_DOC → $POST_DOC)"
    else
      log_fail "documentCount regressed: $PRE_DOC → $POST_DOC (chunk hydration broken)"
    fi

    # entityCount/relationshipCount: compare to SIDECAR truth, not
    # in-memory pre. After hydration the in-memory graph is built up
    # via merge_entity/add_relationship from the persisted set, so
    # the post count must exactly match the sidecar count.
    #
    # If pre > sidecar, that's the build_graph duplicate-node bug
    # (raw petgraph count > unique-id count); persist correctly
    # dedupes on the way out. We log it as INFO so it's visible
    # without flagging hydration as broken.
    if [ "${SIDE_ENT:-0}" -gt 0 ] 2>/dev/null; then
      if [ "${POST_ENT:-0}" -eq "$SIDE_ENT" ] 2>/dev/null; then
        log_pass "entityCount matches sidecar ($POST_ENT == $SIDE_ENT)"
      elif [ "${POST_ENT:-0}" -ge "$SIDE_ENT" ] 2>/dev/null; then
        # Post can legitimately exceed sidecar if a build/extend
        # already ran since the round-trip and added more entities.
        log_pass "entityCount ≥ sidecar ($POST_ENT ≥ $SIDE_ENT, post-extend drift)"
      else
        log_fail "entityCount under sidecar: $POST_ENT < $SIDE_ENT (hydration lost entities)"
      fi
      if [ "${POST_REL:-0}" -eq "$SIDE_REL" ] 2>/dev/null; then
        log_pass "relationshipCount matches sidecar ($POST_REL == $SIDE_REL)"
      elif [ "${POST_REL:-0}" -ge "$SIDE_REL" ] 2>/dev/null; then
        log_pass "relationshipCount ≥ sidecar ($POST_REL ≥ $SIDE_REL)"
      else
        log_fail "relationshipCount under sidecar: $POST_REL < $SIDE_REL (hydration lost relationships)"
      fi

      # Surface the build_graph duplicate-node bug as INFO so it's
      # visible without poisoning the test result.
      if [ "${PRE_ENT:-0}" -gt "$SIDE_ENT" ] 2>/dev/null; then
        log_info "  Note: in-memory pre ($PRE_ENT) > sidecar ($SIDE_ENT). build_graph creates duplicate petgraph nodes on same id; persist dedupes. Hydration round-trip restores the dedupe-correct view, which is intentional, not a regression."
      fi
    else
      log_info "Sidecar empty — round-trip is a no-op verification (cold start; Test 8 will populate)"
    fi
  fi
fi

# Use post-hydration counts as the authoritative graph-state signal
# for downstream gating. POST_ENT may be unset if the round-trip was
# skipped above; default to PRE_ENT in that case.
ENTITY_COUNT="${POST_ENT:-$PRE_ENT}"
REL_COUNT="${POST_REL:-$PRE_REL}"

# ============================================================
# TEST 8: Conditional Graph Build (LLM Entity Extraction)
# ============================================================
# Only fires when the persisted graph is empty (cold-start: fresh
# Qdrant, never built before, OR sidecar collections wiped). When the
# round-trip in Test 7 already restored a populated graph, this is a
# no-op — saves the 30-60s LLM extraction loop on every e2e run.
# Override with FORCE_BUILD=1 if you specifically want to re-extract.
log_step "TEST 8 — Graph Build (conditional — LLM Entity Extraction)"

if [ "${FORCE_BUILD:-0}" != "1" ] && [ "${ENTITY_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  log_pass "Skipping build — persisted graph already populated ($ENTITY_COUNT entities, $REL_COUNT relationships)"
  log_info "  Set FORCE_BUILD=1 to re-extract anyway (only useful after entity_types/prompt/model changes)."
else
  if [ "${FORCE_BUILD:-0}" = "1" ]; then
    log_info "FORCE_BUILD=1 set — re-running full extraction over the entire corpus"
  else
    log_info "Cold start (entityCount=0) — running build to populate the graph"
  fi
  log_info "Initiating graph build... (this may take 2-5 minutes for 27B model)"
  BUILD_START=$(date +%s)

  BUILD_RESPONSE=$(http_post "$BASE_URL/api/graph/build" '{}' 2>&1) || {
    log_fail "Graph build request failed: $BUILD_RESPONSE"
    BUILD_FAILED=true
  }

  BUILD_END=$(date +%s)
  BUILD_DURATION=$(( BUILD_END - BUILD_START ))
  log_info "Graph build completed in ${BUILD_DURATION}s"

  if [ -z "${BUILD_FAILED:-}" ]; then
    BUILD_ENTITIES_NUM=$(echo "$BUILD_RESPONSE" | $NODE -e "const r=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); console.log(r.message || 'no message')" 2>/dev/null || echo "no message")
    log_info "Build result: $BUILD_ENTITIES_NUM"

    STATS=$(http_get "$BASE_URL/api/graph/stats")
    ENTITY_COUNT=$(jq_field "$STATS" "entityCount" 2>/dev/null || echo "0")
    REL_COUNT=$(jq_field "$STATS" "relationshipCount" 2>/dev/null || echo "0")
    log_info "Graph stats: entities=$ENTITY_COUNT relationships=$REL_COUNT"

    if [ -n "$ENTITY_COUNT" ] && [ "$ENTITY_COUNT" -gt 0 ] 2>/dev/null; then
      log_pass "Graph build produced $ENTITY_COUNT entities and ${REL_COUNT:-0} relationships"
    else
      log_warn "Graph build completed but extracted ${ENTITY_COUNT:-0} entities (LLM may have returned invalid JSON)"
      log_info "Check journalctl --user -u graphrag-rs for extraction logs"
    fi
  fi
fi

# ============================================================
# TEST 9: Query (if graph has entities)
# ============================================================
log_step "TEST 9 — Query"

if [ -n "$ENTITY_COUNT" ] && [ "$ENTITY_COUNT" -gt 0 ] 2>/dev/null; then
  # Server expects `query`, not `question` (graphrag-server's QueryRequest
  # struct — different from /api/graph/build which takes free-form input).
  Q_NPU_BEFORE=$(npu_busy); Q_T0=$(now_ms)
  QUERY_RESPONSE=$(http_post "$BASE_URL/api/query" '{
    "query": "What is the Transformer architecture and how does it relate to attention?",
    "top_k": 5
  }' 2>&1)
  Q_T1=$(now_ms); Q_NPU_AFTER=$(npu_busy)

  if [ -n "${QUERY_RESPONSE}" ]; then
    log_pass "Query endpoint responds"
    log_info "  Perf: $(fmt_call_perf "$Q_NPU_BEFORE" "$Q_NPU_AFTER" "$Q_T0" "$Q_T1")"
    if [ "$VERBOSE" = true ]; then
      echo "$QUERY_RESPONSE" | head -50
    fi
  else
    log_warn "Query returned empty response"
  fi
else
  log_warn "Skipping query test (no entities in graph)"
fi

# ============================================================
# TEST 10: MCP Server (graphrag-mcp stdio bridge)
# ============================================================
log_step "TEST 10 — MCP Server (graphrag-mcp)"

MCP_BIN=$(command -v graphrag-mcp 2>/dev/null \
  || ls /etc/profiles/per-user/*/bin/graphrag-mcp 2>/dev/null | head -1)

if [ -z "$MCP_BIN" ] || [ ! -x "$MCP_BIN" ]; then
  log_warn "graphrag-mcp binary not found (skip — set installMcp=true on the HM module)"
else
  log_info "Using $MCP_BIN"
  # Drive a full tool tour through one stdio session — the MCP server
  # reads newline-delimited JSON-RPC 2.0 and replies in registration
  # order. EOF on stdin closes the loop cleanly; timeout guards
  # genuinely-stuck child processes (e.g. backend hanging on build).
  # Per-call ids let us pluck specific responses out of the stream
  # regardless of ordering.
  MCP_DOC_ID="e2e-mcp-$$"
  MCP_OUT=$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"graphrag-e2e","version":"1.0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"graph_stats","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_documents","arguments":{}}}' \
    "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"add_document\",\"arguments\":{\"id\":\"$MCP_DOC_ID\",\"title\":\"MCP Test Doc\",\"content\":\"Diffusion models like DDPM and DDIM denoise latent images iteratively. Stable Diffusion uses a U-Net backbone.\"}}}" \
    '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"query","arguments":{"question":"diffusion model","max_results":3}}}' \
    '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"query_explain","arguments":{"question":"What is a Transformer?","max_results":3}}}' \
    '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"query_reason","arguments":{"question":"How do Transformers and diffusion models differ in their use of attention?","max_results":3}}}' \
    "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"delete_document\",\"arguments\":{\"id\":\"$MCP_DOC_ID\"}}}" \
    | GRAPHRAG_BASE_URL="$BASE_URL" timeout 180 "$MCP_BIN" 2>/dev/null)

  if [ -z "$MCP_OUT" ]; then
    log_fail "graphrag-mcp produced no output"
  else
    # Pluck a response by id — the protocol guarantees id round-trip.
    # Wrapped in an IIFE because top-level `return` is illegal in
    # node -e (it's not a function body).
    mcp_resp() {
      echo "$MCP_OUT" | $NODE -e "
        (function() {
          const lines = require('fs').readFileSync('/dev/stdin','utf8').trim().split(/\n/);
          for (const l of lines) {
            try { const r = JSON.parse(l); if (r.id === $1) { console.log(JSON.stringify(r)); return; } } catch (e) {}
          }
        })();
      " 2>/dev/null
    }
    # And helpers to dig into the result envelope MCP returns.
    mcp_proto() { echo "$1" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).result?.protocolVersion || '')" 2>/dev/null; }
    mcp_tools_count() { echo "$1" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).result?.tools?.length ?? 0)" 2>/dev/null; }
    mcp_tools_names() { echo "$1" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).result?.tools?.map(t=>t.name).join(', ') || '')" 2>/dev/null; }
    mcp_is_error()    { echo "$1" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).result?.isError ?? 'parse-fail')" 2>/dev/null; }
    # Tool calls return result.content[0].text — a JSON-encoded string of
    # the upstream REST response. Decode that and pluck a top-level key.
    mcp_call_text_field() {
      echo "$1" | $NODE -e "
        const r = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
        const txt = r.result?.content?.[0]?.text ?? '';
        try { console.log(JSON.parse(txt).$2 ?? ''); } catch (e) { console.log(''); }
      " 2>/dev/null
    }

    # 1 — initialize handshake
    R1=$(mcp_resp 1)
    INIT_PROTO=$(mcp_proto "$R1")
    if [ "$INIT_PROTO" = "2024-11-05" ]; then
      log_pass "initialize handshake (protocol $INIT_PROTO)"
    else
      log_fail "initialize failed (got proto: '$INIT_PROTO')"
    fi

    # 2 — tools/list
    R2=$(mcp_resp 2)
    TOOL_COUNT=$(mcp_tools_count "$R2")
    TOOL_NAMES=$(mcp_tools_names "$R2")
    if [ "${TOOL_COUNT:-0}" -ge 9 ] 2>/dev/null; then
      log_pass "tools/list advertises $TOOL_COUNT tools"
      log_info "  Tools: $TOOL_NAMES"
    else
      log_fail "tools/list count too low: $TOOL_COUNT (expected ≥9 — query, query_explain, query_reason, graph_stats, list_documents, add_document, delete_document, append_graph, build_graph)"
    fi

    # 3 — tools/call graph_stats
    R3=$(mcp_resp 3)
    if [ "$(mcp_is_error "$R3")" = "false" ]; then
      ENT=$(mcp_call_text_field "$R3" "entityCount")
      REL=$(mcp_call_text_field "$R3" "relationshipCount")
      log_pass "tools/call graph_stats — entities=$ENT relationships=$REL"
    else
      log_fail "tools/call graph_stats failed (isError=$(mcp_is_error "$R3"))"
    fi

    # 4 — tools/call list_documents
    R4=$(mcp_resp 4)
    if [ "$(mcp_is_error "$R4")" = "false" ]; then
      TOTAL=$(mcp_call_text_field "$R4" "total")
      log_pass "tools/call list_documents — total=$TOTAL"
    else
      log_fail "tools/call list_documents failed (isError=$(mcp_is_error "$R4"))"
    fi

    # 5 — tools/call add_document (creates a doc the query test will hit)
    R5=$(mcp_resp 5)
    if [ "$(mcp_is_error "$R5")" = "false" ]; then
      ADD_OK=$(mcp_call_text_field "$R5" "success")
      ADD_ID=$(mcp_call_text_field "$R5" "documentId")
      if [ "$ADD_OK" = "true" ]; then
        log_pass "tools/call add_document — id=$ADD_ID"
      else
        log_fail "tools/call add_document returned success=false"
      fi
    else
      log_fail "tools/call add_document failed (isError=$(mcp_is_error "$R5"))"
    fi

    # 6 — tools/call query (the bug the user just reported: 400 from
    # backend because MCP was sending question/max_results instead of
    # query/top_k). isError=false here means the field translation
    # works end-to-end.
    R6=$(mcp_resp 6)
    if [ "$(mcp_is_error "$R6")" = "false" ]; then
      Q_RESULTS=$(echo "$R6" | $NODE -e "
        const r = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
        const txt = r.result?.content?.[0]?.text ?? '';
        try { console.log((JSON.parse(txt).results || []).length); } catch (e) { console.log('?'); }
      " 2>/dev/null)
      log_pass "tools/call query — got $Q_RESULTS results (translation question→query, max_results→top_k)"
    else
      Q_ERR=$(echo "$R6" | $NODE -e "
        const r = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
        console.log(r.result?.content?.[0]?.text || JSON.stringify(r));
      " 2>/dev/null | head -c 200)
      log_fail "tools/call query failed: $Q_ERR"
    fi

    # 7 — tools/call delete_document (cleans up the doc we added)
    R7=$(mcp_resp 7)
    if [ "$(mcp_is_error "$R7")" = "false" ]; then
      log_pass "tools/call delete_document — cleaned up $MCP_DOC_ID"
    else
      log_warn "tools/call delete_document failed (isError=$(mcp_is_error "$R7"))"
    fi

    # 8 — tools/call query_explain (graph-aware answer + attribution).
    # query_explain routes to mode=explain server-side. The metadata
    # (confidence, keyEntities, reasoningSteps, sources) is computed
    # from data already gathered for the answer — same compute cost
    # as a metadata-less ask, so we only expose this rich variant.
    R8=$(mcp_resp 8)
    if [ "$(mcp_is_error "$R8")" = "false" ]; then
      ASK_FIELDS=$(echo "$R8" | $NODE -e "
        const r = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
        const txt = r.result?.content?.[0]?.text ?? '';
        try {
          const p = JSON.parse(txt);
          const conf = (p.confidence ?? 'null');
          const ke = (p.keyEntities || p.key_entities || []).length;
          const rs = (p.reasoningSteps || p.reasoning_steps || []).length;
          const sr = (p.sources || []).length;
          const ans = (p.answer || '').slice(0, 80).replace(/\n/g, ' ');
          console.log(\`confidence=\${conf} keyEntities=\${ke} reasoningSteps=\${rs} sources=\${sr} | answer: \${ans}\`);
        } catch (e) { console.log('PARSE-FAIL'); }
      " 2>/dev/null)
      log_pass "tools/call query_explain — $ASK_FIELDS"
    else
      log_fail "tools/call query_explain failed (isError=$(mcp_is_error "$R8"))"
    fi

    # 10 — tools/call query_reason (multi-hop decomposition; slowest).
    R10=$(mcp_resp 10)
    if [ "$(mcp_is_error "$R10")" = "false" ]; then
      REASON_ANSWER=$(echo "$R10" | $NODE -e "
        const r = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
        const txt = r.result?.content?.[0]?.text ?? '';
        try {
          const p = JSON.parse(txt);
          const a = (p.answer || '');
          console.log(a.length > 0 ? a.slice(0, 80).replace(/\n/g, ' ') : 'EMPTY');
        } catch (e) { console.log('PARSE-FAIL'); }
      " 2>/dev/null)
      if [ "$REASON_ANSWER" = "EMPTY" ] || [ "$REASON_ANSWER" = "PARSE-FAIL" ]; then
        log_warn "tools/call query_reason returned no answer (entity graph likely empty)"
      else
        log_pass "tools/call query_reason — answer: $REASON_ANSWER..."
      fi
    else
      log_fail "tools/call query_reason failed (isError=$(mcp_is_error "$R10"))"
    fi

    # build_graph deliberately not invoked here — it's a 15-60s LLM
    # round-trip per ingested doc and Test 7 already covered it via the
    # REST path. Rebuilding the graph just to re-prove MCP wiring would
    # double the e2e runtime for no signal.
  fi
fi

# ============================================================
# TEST 11: Graph Append Endpoint (incremental fast-path)
# ============================================================
log_step "TEST 11 — Graph Append (POST /api/graph/append)"

# Test 7 just ran a full build over every chunk; the live chunk count
# now equals processed_chunk_count, so /append should hit the fast
# no-op path and return ~immediately with documentCount: 0. This
# verifies (a) the endpoint exists, (b) the no-op fast-path works,
# (c) last_built_at is exposed via graph_stats.
APPEND_T0=$(now_ms)
APPEND_RESPONSE=$(http_post "$BASE_URL/api/graph/append" '{}' 2>&1)
APPEND_T1=$(now_ms)

if [ -z "${APPEND_RESPONSE:-}" ]; then
  log_fail "/api/graph/append returned no body (older server build? rebuild needed)"
elif echo "$APPEND_RESPONSE" | grep -q '"success":true'; then
  APPEND_NEW=$(echo "$APPEND_RESPONSE" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).documentCount ?? 'unknown')" 2>/dev/null)
  APPEND_MSG=$(echo "$APPEND_RESPONSE" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).message ?? '')" 2>/dev/null)
  APPEND_MS=$(( APPEND_T1 - APPEND_T0 ))
  log_pass "Append endpoint responds (newChunks=$APPEND_NEW in ${APPEND_MS}ms)"
  log_info "  Message: $APPEND_MSG"
  # Sanity check: the no-op should be <1s. Anything slower means the
  # fast-path tripped a full rebuild despite no chunks growing.
  if [ "$APPEND_NEW" = "0" ] && [ "$APPEND_MS" -gt 1000 ] 2>/dev/null; then
    log_warn "no-op append took ${APPEND_MS}ms — fast-path may not be engaging"
  fi
else
  log_fail "Append failed: $APPEND_RESPONSE"
fi

# Confirm /api/graph/stats now exposes lastBuiltAt (set by Test 7's build).
STATS_AFTER=$(http_get "$BASE_URL/api/graph/stats")
LAST_BUILT=$(echo "$STATS_AFTER" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).lastBuiltAt ?? '')" 2>/dev/null)
if [ -n "$LAST_BUILT" ]; then
  log_pass "graph_stats.lastBuiltAt = $LAST_BUILT"
else
  log_warn "graph_stats.lastBuiltAt missing (older server build?)"
fi

# ============================================================
# TEST 12: Query Modes — graph-aware /api/query (mode=ask|explain|reason)
# ============================================================
log_step "TEST 12 — Query Modes (mode=ask|explain|reason)"

# These modes call into graphrag-core's ask()/ask_explained()/
# ask_with_reasoning(). They require a configured chat backend AND a
# non-empty entity graph; if Test 7 yielded zero entities (e.g. LLM
# extraction broken) the modes still work but answer quality is low.
ENT_NOW=$(echo "$STATS_AFTER" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).entityCount ?? 0)" 2>/dev/null)

if [ "${ENT_NOW:-0}" -eq 0 ] 2>/dev/null; then
  log_warn "Skipping mode=ask/explain (entity graph is empty — see Test 7)"
else
  # mode=ask
  ASK_T0=$(now_ms)
  ASK_RESP=$(http_post "$BASE_URL/api/query" '{"query":"What is the Transformer architecture?","top_k":5,"mode":"ask"}' 2>&1)
  ASK_T1=$(now_ms)
  ASK_ANSWER=$(echo "$ASK_RESP" | $NODE -e "
    try { console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).answer ?? ''); } catch (e) { console.log(''); }
  " 2>/dev/null)
  ASK_BACKEND=$(echo "$ASK_RESP" | $NODE -e "
    try { console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).backend ?? ''); } catch (e) { console.log(''); }
  " 2>/dev/null)
  if [ -n "$ASK_ANSWER" ] && [ "$ASK_BACKEND" = "graphrag" ]; then
    log_pass "mode=ask returned answer (backend=$ASK_BACKEND, $((ASK_T1 - ASK_T0))ms, ${#ASK_ANSWER}b)"
    log_info "  Answer head: $(echo "$ASK_ANSWER" | head -c 120 | tr '\n' ' ')..."
  else
    log_fail "mode=ask: empty answer or wrong backend ($ASK_BACKEND); raw: $(echo "$ASK_RESP" | head -c 200)"
  fi

  # mode=explain
  EXP_T0=$(now_ms)
  EXP_RESP=$(http_post "$BASE_URL/api/query" '{"query":"What is the Transformer architecture?","top_k":5,"mode":"explain"}' 2>&1)
  EXP_T1=$(now_ms)
  EXP_FIELDS=$(echo "$EXP_RESP" | $NODE -e "
    try {
      const p = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
      const conf = p.confidence ?? 'null';
      const ke = (p.keyEntities || []).length;
      const rs = (p.reasoningSteps || []).length;
      const sr = (p.sources || []).length;
      const ans = (p.answer || '').length;
      console.log(\`answer=\${ans}b confidence=\${conf} keyEntities=\${ke} reasoningSteps=\${rs} sources=\${sr}\`);
    } catch (e) { console.log(''); }
  " 2>/dev/null)
  EXP_HEAD=$(echo "$EXP_RESP" | $NODE -e "
    try { console.log((JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).answer || '').slice(0, 100).replace(/\n/g, ' ')); } catch (e) { console.log(''); }
  " 2>/dev/null)
  if [ -n "$EXP_FIELDS" ]; then
    log_pass "mode=explain returned attribution ($((EXP_T1 - EXP_T0))ms)"
    log_info "  Fields: $EXP_FIELDS"
    [ -n "$EXP_HEAD" ] && log_info "  Answer head: $EXP_HEAD..."
    EXP_FIRST_REASON=$(echo "$EXP_RESP" | $NODE -e "
      try { console.log(((JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).reasoningSteps || [])[0]?.description || '').slice(0, 100).replace(/\n/g, ' ')); } catch (e) { console.log(''); }
    " 2>/dev/null)
    [ -n "$EXP_FIRST_REASON" ] && log_info "  Reasoning step 1: $EXP_FIRST_REASON"
  else
    log_fail "mode=explain failed; raw: $(echo "$EXP_RESP" | head -c 200)"
  fi

  # mode=reason — multi-hop decomposition. Slowest (multiple LLM
  # round-trips); large timeout to keep the test honest. Skip-as-warn
  # if the LLM call takes longer than the test patience window.
  REASON_T0=$(now_ms)
  REASON_RESP=$(GRAPHRAG_TIMEOUT_SECS=180 \
    "$CURL" -sf --max-time 240 "$BASE_URL/api/query" -X POST -H 'Content-Type: application/json' \
      -d '{"query":"How are Transformers and LLMs related, and what role does attention play?","top_k":5,"mode":"reason"}' 2>&1)
  REASON_T1=$(now_ms)
  REASON_ANS_LEN=$(echo "$REASON_RESP" | $NODE -e "
    try { console.log((JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).answer || '').length); } catch (e) { console.log(0); }
  " 2>/dev/null)
  REASON_HEAD=$(echo "$REASON_RESP" | $NODE -e "
    try { console.log((JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).answer || '').slice(0, 120).replace(/\n/g, ' ')); } catch (e) { console.log(''); }
  " 2>/dev/null)
  if [ "${REASON_ANS_LEN:-0}" -gt 0 ] 2>/dev/null; then
    log_pass "mode=reason returned answer ($((REASON_T1 - REASON_T0))ms, ${REASON_ANS_LEN}b)"
    [ -n "$REASON_HEAD" ] && log_info "  Answer head: $REASON_HEAD..."
  else
    log_warn "mode=reason returned no answer (timed out or LLM busy?); raw head: $(echo "$REASON_RESP" | head -c 200)"
  fi
fi

# mode=search must still work (back-compat) — ensure the existing
# semantic-search path didn't regress.
SEARCH_RESP=$(http_post "$BASE_URL/api/query" '{"query":"GraphRAG","top_k":3,"mode":"search"}' 2>&1)
SEARCH_BACKEND=$(echo "$SEARCH_RESP" | $NODE -e "
  try { console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).backend ?? ''); } catch (e) { console.log(''); }
" 2>/dev/null)
if [ "$SEARCH_BACKEND" = "qdrant" ] || [ "$SEARCH_BACKEND" = "memory" ]; then
  log_pass "mode=search back-compat (backend=$SEARCH_BACKEND)"
else
  log_fail "mode=search broke: backend=$SEARCH_BACKEND"
fi

# ============================================================
# TEST 13: Persistence sidecar collections (graphrag-entities / -relationships)
# ============================================================
log_step "TEST 13 — Graph Persistence (Qdrant sidecar collections)"

# After Test 7 (build_graph) the server should have written to two
# new Qdrant collections: <coll>-entities and <coll>-relationships.
# Verify they exist and have ≥1 point each (assuming Test 7 produced
# entities; otherwise warn).
QDRANT_COLLS=$($CURL -sf "$QDRANT_URL/collections" 2>/dev/null | $NODE -e "
  try {
    const r = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
    console.log((r.result?.collections || []).map(c => c.name).join(' '));
  } catch (e) { console.log(''); }
" 2>/dev/null)

if echo "$QDRANT_COLLS" | grep -q "graphrag-entities"; then
  log_pass "graphrag-entities collection exists"
  E_COUNT=$($CURL -sf "$QDRANT_URL/collections/graphrag-entities" 2>/dev/null | $NODE -e "
    try { console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).result?.points_count ?? 0); } catch (e) { console.log(0); }
  " 2>/dev/null)
  if [ "${E_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    log_pass "graphrag-entities holds $E_COUNT entities (entity graph survives restart)"
  else
    log_warn "graphrag-entities exists but is empty (Test 7 produced no entities?)"
  fi
else
  if [ "${ENT_NOW:-0}" -gt 0 ]; then
    log_fail "graphrag-entities collection missing despite entityCount=$ENT_NOW (persistence not wired?)"
  else
    log_info "graphrag-entities collection not yet created (no build with entities has run)"
  fi
fi

if echo "$QDRANT_COLLS" | grep -q "graphrag-relationships"; then
  log_pass "graphrag-relationships collection exists"
  R_COUNT=$($CURL -sf "$QDRANT_URL/collections/graphrag-relationships" 2>/dev/null | $NODE -e "
    try { console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).result?.points_count ?? 0); } catch (e) { console.log(0); }
  " 2>/dev/null)
  log_info "graphrag-relationships holds $R_COUNT relationships"
fi

# Phase H+ (entity-description embeddings): Assert that the entity
# sidecar carries REAL description embeddings, not the 1-D placeholder
# the earlier draft used. The signal we want:
#   1. Vector dim > 1  (was 1 in the placeholder version)
#   2. Vector dim matches the document collection's dim (so entity
#      and document searches live in the same embedding space)
#   3. Vector values are non-zero (not the all-zero fallback used
#      when the EmbeddingService fails)
#   4. Vector self-search round-trips: searching by an entity's own
#      vector should return that entity as the top hit with score≈1.
# Skip-as-warn when the entity collection is empty (no build has run).
if [ "${E_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  E_DIM=$($CURL -sf "$QDRANT_URL/collections/graphrag-entities" 2>/dev/null | $NODE -e "
    try {
      const r = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
      const cfg = r.result?.config?.params?.vectors;
      // Qdrant returns either {size, distance} or {<name>: {size, distance}}
      const size = cfg?.size ?? Object.values(cfg || {})[0]?.size;
      console.log(size ?? '?');
    } catch (e) { console.log('?'); }
  " 2>/dev/null)
  DOC_DIM=$($CURL -sf "$QDRANT_URL/collections/graphrag" 2>/dev/null | $NODE -e "
    try {
      const r = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
      const cfg = r.result?.config?.params?.vectors;
      const size = cfg?.size ?? Object.values(cfg || {})[0]?.size;
      console.log(size ?? '?');
    } catch (e) { console.log('?'); }
  " 2>/dev/null)

  if [ "$E_DIM" = "?" ]; then
    log_warn "could not read graphrag-entities vector dim from Qdrant"
  elif [ "${E_DIM}" -le 1 ] 2>/dev/null; then
    log_fail "graphrag-entities vector dim is $E_DIM — placeholder vectors. Phase H+ persistence not wired."
  else
    log_pass "graphrag-entities vectors are real (dim=$E_DIM)"
    if [ "$E_DIM" = "$DOC_DIM" ]; then
      log_pass "entity dim matches document dim ($E_DIM == $DOC_DIM) — same embedding space"
    else
      log_warn "entity dim ($E_DIM) ≠ document dim ($DOC_DIM); cross-collection comparison won't work"
    fi
  fi

  # Pull one entity point with its vector, check non-zero values.
  E_POINT=$($CURL -sf -X POST "$QDRANT_URL/collections/graphrag-entities/points/scroll" \
    -H 'Content-Type: application/json' \
    -d '{"limit":1,"with_payload":true,"with_vector":true}' 2>/dev/null)
  E_NONZERO=$(echo "$E_POINT" | $NODE -e "
    try {
      const r = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
      const pt = r.result?.points?.[0];
      const vec = pt?.vector;
      const arr = Array.isArray(vec) ? vec : Object.values(vec || {})[0];
      if (!Array.isArray(arr) || arr.length === 0) { console.log('NO-VEC'); return; }
      const sumAbs = arr.reduce((a, b) => a + Math.abs(b), 0);
      const name = pt?.payload?.name ?? '?';
      console.log(\`name=\${name} dim=\${arr.length} sum_abs=\${sumAbs.toFixed(3)}\`);
    } catch (e) { console.log('PARSE-FAIL'); }
  " 2>/dev/null)
  if echo "$E_NONZERO" | grep -q "sum_abs="; then
    SUM_ABS=$(echo "$E_NONZERO" | sed 's/.*sum_abs=//; s/[^0-9.].*//')
    # Use awk for float comparison (bash can't compare 0.001 to 0.0)
    IS_NONZERO=$(echo "$SUM_ABS" | awk '{print ($1 > 0.001) ? 1 : 0}')
    if [ "$IS_NONZERO" = "1" ]; then
      log_pass "sample entity vector is non-zero ($E_NONZERO)"
    else
      log_fail "sample entity vector is all-zero ($E_NONZERO) — embeddings fell back to zero-fill (EmbeddingService failure?)"
    fi
  else
    log_warn "could not extract sample entity vector ($E_NONZERO)"
  fi

  # Vector self-search: take an entity's vector and search the same
  # collection with it. Top hit should be that same entity (cosine≈1.0).
  # This is the readiness check for "wire entity-vector-search into
  # /api/query" — if this round-trips, the substrate is ready.
  E_VECTOR_JSON=$(echo "$E_POINT" | $NODE -e "
    try {
      const r = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
      const pt = r.result?.points?.[0];
      const vec = pt?.vector;
      const arr = Array.isArray(vec) ? vec : Object.values(vec || {})[0];
      console.log(JSON.stringify({ vector: arr, expected_name: pt?.payload?.name ?? '' }));
    } catch (e) { console.log(''); }
  " 2>/dev/null)
  if [ -n "$E_VECTOR_JSON" ] && echo "$E_VECTOR_JSON" | grep -q '"vector"'; then
    EXPECTED_NAME=$(echo "$E_VECTOR_JSON" | $NODE -e "
      console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).expected_name);
    " 2>/dev/null)
    SEARCH_BODY=$(echo "$E_VECTOR_JSON" | $NODE -e "
      const o = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
      console.log(JSON.stringify({ vector: o.vector, limit: 1, with_payload: true }));
    " 2>/dev/null)
    SEARCH_RESP=$($CURL -sf -X POST "$QDRANT_URL/collections/graphrag-entities/points/search" \
      -H 'Content-Type: application/json' -d "$SEARCH_BODY" 2>/dev/null)
    SEARCH_TOP=$(echo "$SEARCH_RESP" | $NODE -e "
      try {
        const r = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
        const top = r.result?.[0];
        console.log(\`name=\${top?.payload?.name ?? '?'} score=\${top?.score ?? '?'}\`);
      } catch (e) { console.log('PARSE-FAIL'); }
    " 2>/dev/null)
    if echo "$SEARCH_TOP" | grep -q "name=$EXPECTED_NAME"; then
      log_pass "entity vector self-search round-trips: $SEARCH_TOP (substrate ready for entity-vector-search retrieval)"
    else
      log_fail "entity vector self-search broken — expected name=$EXPECTED_NAME, got $SEARCH_TOP"
    fi
  else
    log_warn "skipping vector self-search — could not extract sample vector"
  fi
else
  log_info "Skipping entity-vector checks (graphrag-entities is empty)"
fi

# ============================================================
# SUMMARY
# ============================================================
log_step "SUMMARY"

echo ""
echo "  Results: $PASS passed | $FAIL failed | $WARN warnings"
echo ""

if [ "$CLEANUP" = true ]; then
  log_info "Cleaning up test documents..."
  # Delete test documents
  if [ -n "${DOC1_DOCID:-}" ]; then
    http_delete "$BASE_URL/api/documents/$DOC1_DOCID" 2>/dev/null
    log_info "Deleted $DOC1_DOCID"
  fi
  if [ -n "${DOC2_DOCID:-}" ]; then
    http_delete "$BASE_URL/api/documents/$DOC2_DOCID" 2>/dev/null
    log_info "Deleted $DOC2_DOCID"
  fi
fi

# Service state snapshot
echo ""
echo "  Service snapshot:"
echo "    Health: $(http_get "$BASE_URL/health" 2>/dev/null | $NODE -e "const h=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); console.log(\`docs=\${h.documentCount} entities=\${h.graphBuilt ? 'built' : 'not built'} queries=\${h.totalQueries}\`)" 2>/dev/null)"
echo "    Timeout: ${OA_TIMEOUT}s"
echo "    LLM: $OA_MODEL @ $OA_URL"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "  ⚠️  Some tests failed. Check service logs: journalctl --user -u graphrag-rs --no-pager -n 40"
  exit 1
fi

echo "  ✅ All tests passed."

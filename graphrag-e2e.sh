#!/usr/bin/env bash
# graphrag-e2e.sh — End-to-end diagnostic test suite for graphrag-rs
# Usage: ./graphrag-e2e.sh [--reset] [--cleanup] [--verbose]

set -o pipefail

# --- Configuration ---
BASE_URL="${GRAPHRAG_URL:-http://127.0.0.1:8080}"
NPU_URL="${NPU_URL:-http://127.0.0.1:9000}"
LLM_URL="${LLM_URL:-http://127.0.0.1:17171/v1}"
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
# TEST 4: LLM Backend (llama-server)
# ============================================================
log_step "TEST 4 — LLM Backend (llama-server)"

LLM_MODELS=$(http_get "$LLM_URL/models" 2>/dev/null) || {
  log_fail "llama-server unreachable at $LLM_URL"
  SKIP_LLM=true
}

if [ -n "${LLM_MODELS:-}" ]; then
  log_pass "llama-server reachable"
  MODEL_LIST=$(jq_field "$LLM_MODELS" "data[0].id" 2>/dev/null || echo "unknown")
  log_info "Available models: $MODEL_LIST"

  # Quick generation test. Use the model id reported by /models (so the
  # test stays correct as the loaded GGUF changes), and disable Qwen3
  # thinking via chat_template_kwargs so a few-token cap actually yields
  # content (otherwise reasoning tokens consume the whole budget).
  log_info "Running quick LLM generation test..."
  TEST_MODEL="${MODEL_LIST:-Qwen3.6-27B}"
  GEN_TEST=$(http_post "$LLM_URL/chat/completions" "{
    \"model\": \"$TEST_MODEL\",
    \"messages\": [{\"role\":\"user\",\"content\":\"Reply with only the word hello.\"}],
    \"max_tokens\": 32,
    \"temperature\": 0,
    \"chat_template_kwargs\": {\"enable_thinking\": false}
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
# TEST 7: Graph Build (LLM Entity Extraction)
# ============================================================
log_step "TEST 7 — Graph Build (LLM Entity Extraction)"

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
  BUILD_ENTITIES=$(jq_field "$BUILD_RESPONSE" "documentCount" 2>/dev/null || echo "0")
  BUILD_ENTITIES_NUM=$(echo "$BUILD_RESPONSE" | $NODE -e "const r=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); console.log(r.message || 'no message')" 2>/dev/null || echo "no message")
  log_info "Build result: $BUILD_ENTITIES_NUM"

  # Check graph stats
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

# ============================================================
# TEST 8: Query (if graph has entities)
# ============================================================
log_step "TEST 8 — Query"

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
# TEST 9: MCP Server (graphrag-mcp stdio bridge)
# ============================================================
log_step "TEST 9 — MCP Server (graphrag-mcp)"

MCP_BIN=$(command -v graphrag-mcp 2>/dev/null \
  || ls /etc/profiles/per-user/*/bin/graphrag-mcp 2>/dev/null | head -1)

if [ -z "$MCP_BIN" ] || [ ! -x "$MCP_BIN" ]; then
  log_warn "graphrag-mcp binary not found (skip — set installMcp=true on the HM module)"
else
  log_info "Using $MCP_BIN"
  # Send initialize → initialized notification → tools/list → tools/call.
  # MCP framing: newline-delimited JSON-RPC 2.0 on stdin/stdout. EOF on
  # stdin makes graphrag-mcp's read loop exit cleanly; timeout is just a
  # belt-and-braces guard.
  MCP_OUT=$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"graphrag-e2e","version":"1.0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"graph_stats","arguments":{}}}' \
    | GRAPHRAG_BASE_URL="$BASE_URL" timeout 30 "$MCP_BIN" 2>/dev/null)

  if [ -z "$MCP_OUT" ]; then
    log_fail "graphrag-mcp produced no output"
  else
    # Line 1 — initialize response
    INIT_PROTO=$(echo "$MCP_OUT" | sed -n '1p' | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).result?.protocolVersion || '')" 2>/dev/null)
    if [ "$INIT_PROTO" = "2024-11-05" ]; then
      log_pass "MCP initialize handshake (protocol $INIT_PROTO)"
    else
      log_fail "MCP initialize failed (got proto: '$INIT_PROTO')"
    fi

    # Line 2 — tools/list response
    TOOL_COUNT=$(echo "$MCP_OUT" | sed -n '2p' | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).result?.tools?.length ?? 0)" 2>/dev/null)
    TOOL_NAMES=$(echo "$MCP_OUT" | sed -n '2p' | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).result?.tools?.map(t=>t.name).join(', ') || '')" 2>/dev/null)
    if [ "${TOOL_COUNT:-0}" -ge 6 ] 2>/dev/null; then
      log_pass "MCP advertises $TOOL_COUNT tools"
      log_info "Tools: $TOOL_NAMES"
    else
      log_fail "MCP tool count too low: $TOOL_COUNT (expected ≥6)"
    fi

    # Line 3 — tools/call graph_stats response (proxies to /api/graph/stats)
    CALL_ERR=$(echo "$MCP_OUT" | sed -n '3p' | $NODE -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).result?.isError ?? 'parse-fail')" 2>/dev/null)
    if [ "$CALL_ERR" = "false" ]; then
      log_pass "MCP tools/call → graph_stats returned without error"
    else
      log_fail "MCP tools/call → graph_stats failed (isError=$CALL_ERR)"
    fi
  fi
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

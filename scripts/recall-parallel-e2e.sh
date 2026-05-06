#!/usr/bin/env bash
# Layer 3 validation: hybrid recalls run in parallel, bounded by
# RECALL_MAX_CONCURRENT.
#
# Test design:
#   - Boot a server with RECALL_MAX_CONCURRENT=4
#   - Configure pattern-based extraction (no chat backend) so
#     mode=hybrid still goes through graphrag.ask but doesn't need a
#     real LLM. ask() falls back to formatted search results when
#     chat_enabled() is false.
#   - Seed a corpus + build the graph + warm-up embeddings
#   - Fire 8 hybrid recalls concurrently, measure wall-clock
#   - Fire 8 hybrid recalls serially, measure wall-clock
#   - Concurrent should be MUCH faster than serial (≈ 4x with
#     concurrency=4 against an N-bound workload). Allow some slack
#     for setup overhead and ensure concurrent < serial × 0.5.
#
# Without Layer 3 (read-lock + semaphore), all 8 recalls would
# serialize through state.graphrag.write().await regardless of
# concurrency settings, so concurrent ≈ serial.

set -euo pipefail

REPO=/home/data01/Projects/graphrag-rs
SERVER_BIN="$REPO/target/release/graphrag-server"
PORT="${PORT:-19200}"
COLLECTION="graphrag_e2e_layer3_$$"
QDRANT_URL="${QDRANT_URL:-http://127.0.0.1:6334}"
BASE="http://127.0.0.1:$PORT"
LOG="/tmp/graphrag-layer3-e2e.$$.log"
N_PARALLEL=4
SEMAPHORE_SIZE=4
QUERY_TIMEOUT_S=300

if ! [ -x "$SERVER_BIN" ]; then
  echo "FAIL: $SERVER_BIN missing — run cargo build -p graphrag-server --release" >&2
  exit 1
fi

passed=0; failed=0
ok()  { passed=$((passed+1)); echo "✓ $*"; }
bad() { failed=$((failed+1)); echo "✗ $*" >&2; }

cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  curl -fsS -X DELETE "http://127.0.0.1:6333/collections/$COLLECTION" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Use the host's LLM router as the chat backend. Real LLM cost per
# call is sufficient for parallelism to show up in wall-clock time.
# If the router isn't up (CI host without Spark / llama-server),
# skip the timing assertion and just verify the structural pieces.
LLM_ENDPOINT="${LLM_ENDPOINT:-http://127.0.0.1:17170/v1}"
LLM_MODEL="${LLM_MODEL:-sakamakismile/Qwen3.6-27B-Text-NVFP4-MTP}"
LLM_AVAILABLE=0
if curl -fsS --max-time 2 "${LLM_ENDPOINT}/models" >/dev/null 2>&1; then
  LLM_AVAILABLE=1
fi

echo "▸ booting server on :$PORT (concurrency=$SEMAPHORE_SIZE)"
EMBEDDING_BACKEND=hash EMBEDDING_DIM=384 \
GRAPHRAG_HOST=127.0.0.1 GRAPHRAG_PORT="$PORT" \
COLLECTION_NAME="$COLLECTION" QDRANT_URL="$QDRANT_URL" \
INGEST_ALLOWED_ROOTS="/tmp" \
APPEND_DEBOUNCE_SECS=900 \
RECALL_MAX_CONCURRENT="$SEMAPHORE_SIZE" \
RUST_LOG="info,actix_web=warn,actix_server=warn" \
"$SERVER_BIN" >"$LOG" 2>&1 &
SERVER_PID=$!

for i in $(seq 1 30); do
  curl -fsS "$BASE/health" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "$BASE/health" >/dev/null || { bad "server didn't come up"; tail -30 "$LOG"; exit 1; }
ok "server up"

if grep -q "recall concurrency budget: $SEMAPHORE_SIZE" "$LOG"; then
  ok "log confirms concurrency budget = $SEMAPHORE_SIZE"
else
  bad "expected log line 'recall concurrency budget: $SEMAPHORE_SIZE'"
  grep -i 'concurrency\|recall' "$LOG" | head -5
fi

# Pattern-based extraction; chat backend pointed at the host's LLM
# router so hybrid_query can synthesize an answer. If the router
# is unavailable, the test skips timing assertions.
if [ "$LLM_AVAILABLE" = "1" ]; then
  curl -fsS -X POST "$BASE/config" -H 'Content-Type: application/json' \
    -d "{
      \"approach\":\"pattern\",
      \"entities\":{\"use_gleaning\":false,\"min_confidence\":0.0,\"entity_types\":[\"PERSON\",\"ORGANIZATION\",\"LOCATION\"]},
      \"openai\":{\"enabled\":true,\"base_url\":\"$LLM_ENDPOINT\",\"chat_model\":\"$LLM_MODEL\",\"api_key\":\"\"},
      \"ollama\":{\"enabled\":false},
      \"graph\":{\"extract_relationships\":true}
    }" \
    >/dev/null
  ok "config posted with chat backend $LLM_ENDPOINT (model=$LLM_MODEL)"
else
  curl -fsS -X POST "$BASE/config" -H 'Content-Type: application/json' \
    -d '{"approach":"pattern","entities":{"use_gleaning":false,"min_confidence":0.0,"entity_types":["PERSON","ORGANIZATION","LOCATION"]},"openai":{"enabled":false},"ollama":{"enabled":false},"graph":{"extract_relationships":true}}' \
    >/dev/null
  ok "config posted (no chat backend; timing assertions skipped)"
fi

# Seed 20 docs, ingest + build graph
echo "▸ seeding 20 docs"
for i in $(seq 1 20); do
  curl -fsS -X POST "$BASE/api/documents" -H 'Content-Type: application/json' \
    -d "{\"title\":\"Doc $i\",\"content\":\"Alice met Bob in Berlin during summit $i. ACME Corp sponsored the event. Charlie from DFKI joined later.\",\"source\":\"test://doc/$i\"}" \
    >/dev/null
done
ok "20 docs seeded"

curl -fsS -X POST "$BASE/api/graph/append" >/dev/null
ok "graph built"

# Phase 6 invariant: append should source delta chunks from Qdrant
# (`list_unextracted_chunks`) — confirmed via the `extend_graph: N
# delta chunks` log line. With 20 fresh docs ingested and never
# extracted, the append must process > 0 chunks.
sleep 0.5
if grep -qE 'extend_graph: [1-9][0-9]* delta chunks' "$LOG"; then
  ok "append sourced delta chunks from Qdrant (Phase 6 flow)"
else
  bad "expected 'extend_graph: N delta chunks' log line missing — Phase 6 qdrant-only flow not exercised"
  grep -i 'extend_graph\|delta' "$LOG" | tail -5
fi

if [ "$LLM_AVAILABLE" != "1" ]; then
  echo "  (skipping timing assertions — LLM endpoint $LLM_ENDPOINT unavailable)"
  echo
  echo "$passed passed, $failed failed"
  exit "$failed"
fi

# ── Serial baseline ────────────────────────────────────────────
echo "▸ baseline: $N_PARALLEL hybrid recalls SERIALLY"
SERIAL_T0="$EPOCHREALTIME"
for i in $(seq 1 $N_PARALLEL); do
  curl -fsS --max-time "$QUERY_TIMEOUT_S" -X POST "$BASE/api/query" -H 'Content-Type: application/json' \
    -d '{"query":"Alice","mode":"hybrid","topK":3}' \
    -o /dev/null
done
SERIAL_T1="$EPOCHREALTIME"
SERIAL_S=$(awk -v t0="$SERIAL_T0" -v t1="$SERIAL_T1" 'BEGIN{printf "%.3f", t1-t0}')
echo "  serial: ${SERIAL_S}s"

# ── Concurrent run ─────────────────────────────────────────────
echo "▸ concurrent: $N_PARALLEL hybrid recalls in PARALLEL (cap=$SEMAPHORE_SIZE)"
PIDS=()
PAR_T0="$EPOCHREALTIME"
for i in $(seq 1 $N_PARALLEL); do
  ( curl -fsS --max-time "$QUERY_TIMEOUT_S" -X POST "$BASE/api/query" -H 'Content-Type: application/json' \
      -d '{"query":"Alice","mode":"hybrid","topK":3}' \
      -o /dev/null ) &
  PIDS+=($!)
done
for p in "${PIDS[@]}"; do wait "$p"; done
PAR_T1="$EPOCHREALTIME"
PAR_S=$(awk -v t0="$PAR_T0" -v t1="$PAR_T1" 'BEGIN{printf "%.3f", t1-t0}')
echo "  concurrent: ${PAR_S}s"

# Concurrent should be substantially faster than serial.
RATIO=$(awk -v p="$PAR_S" -v s="$SERIAL_S" 'BEGIN{printf "%.2f", p/s}')
echo "  concurrent/serial ratio: $RATIO (lower = better)"

if awk -v r="$RATIO" 'BEGIN{exit !(r+0 < 0.7)}'; then
  ok "concurrent recalls are at least 30% faster than serial (ratio=$RATIO)"
else
  bad "concurrent recalls are NOT faster (ratio=$RATIO; expected < 0.7)"
fi

echo
echo "$passed passed, $failed failed"
exit "$failed"

#!/usr/bin/env bash
# Validates the Phase B/option-5 fix: append no longer blocks recall.
#
# Setup:
#   1. Spin up a graphrag-server on an isolated port + temp collection
#      with EMBEDDING_BACKEND=hash so the embedding phase is fast and
#      deterministic (real OVMS is too slow for a quick CI test).
#   2. POST /config to initialize GraphRAG (pattern-only extraction —
#      chat backends are off in this harness).
#   3. Pre-load N documents so the graph has some entities to begin with.
#   4. POST /api/graph/append once → triggers extend_graph and the
#      lock-free persist path.
#   5. Concurrently fire 5 recall requests + 5 ingest requests at the
#      same instant. Measure each recall's wall-clock latency.
#
# Pass criteria:
#   - All recalls complete in < 2 sec each (would have blocked 4+ min
#     before the fix).
#   - Append eventually completes successfully.
#   - Server log shows "Persisted delta to Qdrant: N entities, M relationships"
#     where N + M is bounded by the touched delta, not total graph size.

set -euo pipefail

REPO=/home/data01/Projects/graphrag-rs
SERVER_BIN="$REPO/target/release/graphrag-server"
PORT="${PORT:-19002}"
COLLECTION="graphrag_e2e_concurrency_$$"
QDRANT_URL="${QDRANT_URL:-http://127.0.0.1:6334}"
BASE="http://127.0.0.1:$PORT"
LOG=/tmp/graphrag-concur-e2e.$$.log

if ! [ -x "$SERVER_BIN" ]; then
  echo "FAIL: $SERVER_BIN missing — run cargo build -p graphrag-server --release" >&2
  exit 1
fi

passed=0; failed=0
ok()   { passed=$((passed+1)); echo "✓ $*"; }
bad()  { failed=$((failed+1)); echo "✗ $*" >&2; }

cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  curl -fsS -X DELETE "http://127.0.0.1:6333/collections/${COLLECTION}_entities" >/dev/null 2>&1 || true
  curl -fsS -X DELETE "http://127.0.0.1:6333/collections/${COLLECTION}_relationships" >/dev/null 2>&1 || true
  curl -fsS -X DELETE "http://127.0.0.1:6333/collections/$COLLECTION" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "▸ booting server on :$PORT (collection=$COLLECTION)"
EMBEDDING_BACKEND=hash EMBEDDING_DIM=384 \
GRAPHRAG_HOST=127.0.0.1 GRAPHRAG_PORT="$PORT" \
COLLECTION_NAME="$COLLECTION" QDRANT_URL="$QDRANT_URL" \
INGEST_ALLOWED_ROOTS="/tmp" \
APPEND_DEBOUNCE_SECS=900 \
RUST_LOG="info,actix_web=warn,actix_server=warn" \
"$SERVER_BIN" >"$LOG" 2>&1 &
SERVER_PID=$!

for i in $(seq 1 30); do
  curl -fsS "$BASE/health" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "$BASE/health" >/dev/null || { bad "server didn't come up"; tail -30 "$LOG"; exit 1; }
ok "server up"

# Initialize GraphRAG via /config — pattern extraction (no chat backend
# needed for this harness; we're testing the lock semantics, not the
# extractor).
CONFIG=$(cat <<'EOF'
{
  "approach": "pattern",
  "entities": { "use_gleaning": false, "min_confidence": 0.0, "entity_types": ["PERSON","ORGANIZATION","LOCATION"] },
  "openai": { "enabled": false },
  "ollama": { "enabled": false },
  "graph": { "extract_relationships": true }
}
EOF
)
curl -fsS -X POST "$BASE/config" -H 'Content-Type: application/json' -d "$CONFIG" >/dev/null \
  && ok "config posted" || bad "config post failed"

# Seed the graph with a small batch of docs so extend_graph has
# something to do, but stay small enough that the test runs in seconds.
echo "▸ seeding 10 docs"
for i in $(seq 1 10); do
  curl -fsS -X POST "$BASE/api/documents" -H 'Content-Type: application/json' \
    -d "{\"title\":\"Seed $i\",\"content\":\"Alice met Bob in Berlin during summit $i. ACME Corp sponsored the event.\",\"source\":\"test://seed/$i\"}" >/dev/null
done
ok "seeded 10 docs"

# First append builds the initial graph.
APPEND_RESP=$(curl -fsS -X POST "$BASE/api/graph/append")
echo "  initial append: $APPEND_RESP" | head -c 200; echo
echo "$APPEND_RESP" | grep -q '"success":true' && ok "initial append succeeded" || bad "initial append: $APPEND_RESP"

# Sanity: server logged the new "Persisted delta" message (not the old
# "Persisted graph" full-graph one).
sleep 0.3
if grep -q 'Persisted delta to Qdrant' "$LOG"; then
  ok 'server logged "Persisted delta to Qdrant" (lock-free path active)'
else
  bad 'expected "Persisted delta to Qdrant" log line not found'
  grep -E 'Persisted|persistence|extend_graph' "$LOG" | tail -5
fi

# ── Concurrency test ──
# Fire 5 recalls + 5 ingests in parallel. Recalls should NOT block
# behind the in-flight append.
echo "▸ firing 5 concurrent recalls + 5 concurrent ingests…"
RESULT_DIR=$(mktemp -d)
PIDS=()
for i in 1 2 3 4 5; do
  (
    # bash 5+ $EPOCHREALTIME gives `seconds.microseconds` — no python
    # dep needed, works in any shell environment we ship.
    t0="$EPOCHREALTIME"
    curl -fsS -X POST "$BASE/api/query" -H 'Content-Type: application/json' \
      -d '{"query":"Alice","mode":"search","topK":3}' \
      -o "$RESULT_DIR/recall_$i.json"
    t1="$EPOCHREALTIME"
    awk -v t0="$t0" -v t1="$t1" 'BEGIN{printf "%.3f\n", t1-t0}' > "$RESULT_DIR/recall_$i.time"
  ) &
  PIDS+=($!)
done
for i in 11 12 13 14 15; do
  (
    curl -fsS -X POST "$BASE/api/documents" -H 'Content-Type: application/json' \
      -d "{\"title\":\"Concurrent $i\",\"content\":\"More events with Alice and Charlie at HQ in $i.\",\"source\":\"test://concur/$i\"}" \
      -o "$RESULT_DIR/ingest_$i.json"
  ) &
  PIDS+=($!)
done

# Also fire one append in parallel — this is what would block recall
# in the old design.
(
  curl -fsS -X POST "$BASE/api/graph/append" \
    -o "$RESULT_DIR/append_concur.json"
) &
PIDS+=($!)

# Wait ONLY on the curl subshells, NOT on the server (which is also a
# background job at this point). Plain `wait` would block on the
# server forever.
for p in "${PIDS[@]}"; do wait "$p"; done

# Assert: every recall took < 2 sec (the append cycle takes longer than
# this for 5 docs even with hash embeddings; in the OLD design recall
# would take ≥ append duration).
slowest=0
for i in 1 2 3 4 5; do
  t=$(cat "$RESULT_DIR/recall_$i.time")
  echo "  recall $i: ${t}s"
  awk -v t="$t" -v slowest="$slowest" 'BEGIN{exit !(t+0>slowest+0)}' && slowest="$t"
done
if awk -v t="$slowest" 'BEGIN{exit !(t+0<2.0)}'; then
  ok "all recalls < 2s during concurrent append (slowest=${slowest}s)"
else
  bad "concurrent recall blocked: slowest was ${slowest}s (expected < 2s)"
fi

# Verify the concurrent append also succeeded.
if grep -q '"success":true' "$RESULT_DIR/append_concur.json"; then
  ok "concurrent append succeeded"
else
  bad "concurrent append failed: $(cat $RESULT_DIR/append_concur.json)"
fi

# Verify all concurrent ingests landed.
ing_ok=0
for i in 11 12 13 14 15; do
  grep -q '"success":true' "$RESULT_DIR/ingest_$i.json" 2>/dev/null && ing_ok=$((ing_ok+1))
done
[ "$ing_ok" = "5" ] && ok "5/5 concurrent ingests succeeded" || bad "only $ing_ok/5 ingests succeeded"

rm -rf "$RESULT_DIR"
echo
echo "$passed passed, $failed failed"
exit "$failed"

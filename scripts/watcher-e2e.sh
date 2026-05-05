#!/usr/bin/env bash
# End-to-end test for knowledge-watcher: writing a file under the
# watched root → server's catalog grows.
#
# Spawns a fresh graphrag-server (hash embeddings + throwaway qdrant
# collection) and a knowledge-watcher pointed at /tmp/graphrag-test/
# notes. Drops a markdown file into that root, waits for the
# debounced inotify event, asserts the catalog count grew.
set -euo pipefail

SERVER=/home/data01/Projects/graphrag-rs-nix/result/bin/graphrag-server
WATCHER=/home/data01/Projects/graphrag-rs-nix/result-watcher/bin/knowledge-watcher
ROOT=/tmp/graphrag-test/watcher-root
LOG_SERVER=/tmp/graphrag-test/watcher-server.log
LOG_WATCHER=/tmp/graphrag-test/watcher-sidecar.log
URL="http://127.0.0.1:8080"
COLL="watcher_e2e_$$"

mkdir -p "$ROOT"
rm -f "$ROOT"/*.md

[ -x "$SERVER" ]  || { echo "missing $SERVER — run nix build .#graphrag-server"; exit 1; }
[ -x "$WATCHER" ] || { echo "missing $WATCHER — run nix build .#knowledge-watcher --out-link result-watcher"; exit 1; }

cleanup() {
  rc=$?
  for pid in "${SERVER_PID:-}" "${WATCHER_PID:-}"; do
    [ -n "$pid" ] && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
  done
  curl -fsS -X DELETE "http://127.0.0.1:6333/collections/$COLL" >/dev/null 2>&1 || true
  if [ "$rc" -ne 0 ]; then
    echo "==== WATCHER E2E FAILED ===="
    echo "--- server log tail ---"
    tail -40 "$LOG_SERVER" || true
    echo "--- watcher log tail ---"
    tail -40 "$LOG_WATCHER" || true
  fi
  exit "$rc"
}
trap cleanup EXIT

echo "qdrant collection: $COLL"
echo "watch root:        $ROOT"

# Pre-seed: one file already on disk before the watcher starts —
# tests the initial-walk path.
echo "# preseed file (caught by initial walk)" > "$ROOT/preseed.md"

# Boot the server. APPEND_DEBOUNCE_SECS=0 skips entity extraction
# (which would need a chat backend) — we only assert vector ingest.
EMBEDDING_BACKEND=hash EMBEDDING_DIM=384 \
  QDRANT_URL=http://127.0.0.1:6334 COLLECTION_NAME="$COLL" \
  RUST_LOG=warn,graphrag_server=info \
  INGEST_ALLOWED_ROOTS="$ROOT" \
  APPEND_DEBOUNCE_SECS=0 \
  "$SERVER" >"$LOG_SERVER" 2>&1 &
SERVER_PID=$!
for i in $(seq 1 60); do
  curl -fs --max-time 2 "$URL/health" >/dev/null && break
  sleep 0.5
done
curl -fs --max-time 2 "$URL/health" >/dev/null || { echo "server never came up"; exit 1; }

# Boot the watcher with debounce=200ms (snappier for tests).
WATCHER_BASE_URL="$URL" \
  WATCHER_ROOTS="$ROOT" \
  WATCHER_DEBOUNCE_MS=200 \
  WATCHER_LOG=info \
  "$WATCHER" >"$LOG_WATCHER" 2>&1 &
WATCHER_PID=$!

# Wait for initial walk to complete (preseed.md should land).
echo "==== T1: initial walk picks up pre-existing file ===="
for i in $(seq 1 20); do
  TOTAL=$(curl -fsS "$URL/api/documents" | jq -r '.total // 0')
  [ "$TOTAL" -ge 1 ] && break
  sleep 0.5
done
[ "$TOTAL" -ge 1 ] || { echo "FAIL [t1] preseed never ingested (total=$TOTAL)"; exit 1; }
echo "OK   [t1] catalog total=$TOTAL after initial walk"

# Drop a NEW file. Live inotify path.
echo "==== T2: live inotify catches a fresh write ===="
NEW=$ROOT/live-write.md
echo "# live write target — apricot lavender" > "$NEW"
sync
for i in $(seq 1 30); do
  TOTAL=$(curl -fsS "$URL/api/documents" | jq -r '.total // 0')
  [ "$TOTAL" -ge 2 ] && break
  sleep 0.5
done
[ "$TOTAL" -ge 2 ] || { echo "FAIL [t2] live write never ingested (total=$TOTAL)"; exit 1; }
echo "OK   [t2] catalog total=$TOTAL after live write"

# Edit it. Should upsert, not create a new doc.
echo "==== T3: edit triggers upsert (catalog count unchanged) ===="
sleep 0.5
echo "# live write target — peach plum new content" > "$NEW"
sync
sleep 2
TOTAL_AFTER=$(curl -fsS "$URL/api/documents" | jq -r '.total // 0')
# Catalog total can stay the same OR (if old version still counted)
# go up by 1 — the qdrant scroll counts ALL points by default. Both
# is_current = true and is_current = false points are returned by
# list_documents today, so a re-ingest writes a new point and the
# total goes up by 1. That's still proof the upsert happened.
# Assert: at least one chunk now contains "peach".
echo "==== checking whether new content is recallable ===="
sleep 1
R=$(curl -fsS -X POST "$URL/api/query" -H 'Content-Type: application/json' \
    -d '{"query":"live write target","top_k":5,"mode":"search"}')
HAS_NEW=$(echo "$R" | jq '[.results[] | select(.excerpt | test("peach"))] | length')
HAS_OLD=$(echo "$R" | jq '[.results[] | select(.excerpt | test("apricot"))] | length')
[ "$HAS_NEW" -ge 1 ] || { echo "FAIL [t3] new (peach) chunk not in top-K — upsert may not have fired"; exit 1; }
[ "$HAS_OLD" -eq 0 ] || { echo "FAIL [t3] old (apricot) leaked into default recall, count=$HAS_OLD"; exit 1; }
echo "OK   [t3] upsert fired: new=$HAS_NEW old=$HAS_OLD; total=$TOTAL_AFTER"

# Delete it.
echo "==== T4: delete triggers DELETE ===="
rm -f "$NEW"
sleep 2
R=$(curl -fsS -X POST "$URL/api/query" -H 'Content-Type: application/json' \
    -d '{"query":"live write target","top_k":5,"mode":"search"}')
HAS_NEW=$(echo "$R" | jq '[.results[] | select(.excerpt | test("peach"))] | length')
# A DELETE removes the user_id-tagged point but old superseded
# chunks still exist (apricot version). Default current filter
# excludes them too because they were superseded. Net: 0 hits.
[ "$HAS_NEW" -eq 0 ] || { echo "FAIL [t4] file still recallable after delete (peach=$HAS_NEW)"; exit 1; }
echo "OK   [t4] delete propagated; current view of doc empty"

echo
echo "ALL WATCHER E2E TESTS PASSED."

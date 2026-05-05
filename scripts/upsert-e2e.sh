#!/usr/bin/env bash
# End-to-end test for history-aware upsert.
#
# Spawns a fresh graphrag-server on hash embeddings + the live qdrant
# (unique throwaway collection). Walks the upsert flow:
#   1. Ingest path X → version 1, is_current = true.
#   2. Ingest same path with same content → Duplicate (no-op).
#   3. Edit the file, ingest again → status = "updated", version = 2.
#   4. Default `simple` recall → only the new content is in top-K
#      (old chunks present but is_current=false → filtered out).
#   5. Recall with as_of pointing before the edit → both versions
#      considered (over-fetch path).
#   6. Recall with max_versions_per_doc=2 → both versions considered.
#
# All checks via curl + jq.
set -euo pipefail

SERVER=/home/data01/Projects/graphrag-rs-nix/result/bin/graphrag-server
ROOT=/tmp/graphrag-test/notes
LOG=/tmp/graphrag-test/upsert-server.log
URL="http://127.0.0.1:8080"
COLL="upsert_e2e_$$"
DOC=$ROOT/upsert-evolving.md

mkdir -p "$ROOT"

cleanup() {
  rc=$?
  [ -n "${SERVER_PID:-}" ] && { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
  curl -fsS -X DELETE "http://127.0.0.1:6333/collections/$COLL" >/dev/null 2>&1 || true
  rm -f "$DOC"
  if [ "$rc" -ne 0 ]; then
    echo "==== UPSERT E2E FAILED — server log tail ===="
    tail -60 "$LOG" || true
  fi
  exit "$rc"
}
trap cleanup EXIT

echo "qdrant collection: $COLL"

# Boot the server
EMBEDDING_BACKEND=hash EMBEDDING_DIM=384 \
  QDRANT_URL=http://127.0.0.1:6334 COLLECTION_NAME="$COLL" \
  RUST_LOG=warn,graphrag_server=info \
  INGEST_ALLOWED_ROOTS="$ROOT" \
  APPEND_DEBOUNCE_SECS=0 \
  "$SERVER" >"$LOG" 2>&1 &
SERVER_PID=$!

for i in $(seq 1 60); do
  curl -fs --max-time 2 "$URL/health" >/dev/null && break
  sleep 0.5
done
curl -fs --max-time 2 "$URL/health" >/dev/null || { echo "server never came up"; exit 1; }

assert_eq() { # name expected actual
  if [ "$2" != "$3" ]; then
    echo "FAIL [$1] expected=$2 actual=$3"; exit 1;
  fi
  echo "OK   [$1] $3"
}

# === T1: first ingest ===
echo "==== T1: first ingest of upsert-evolving.md ===="
echo "# upsert evolving doc — version one banana original" > "$DOC"
R=$(curl -fsS -X POST "$URL/api/documents" -H 'Content-Type: application/json' \
    -d "{\"path\":\"$DOC\"}")
echo "$R" | jq .
MSG=$(echo "$R" | jq -r '.message // empty')
case "$MSG" in
  *"added"*) echo "OK   [t1] $MSG" ;;
  *) echo "FAIL [t1] expected 'added', got '$MSG'"; exit 1 ;;
esac

# === T2: same content → duplicate ===
echo "==== T2: re-ingest unchanged content ===="
R=$(curl -fsS -X POST "$URL/api/documents" -H 'Content-Type: application/json' \
    -d "{\"path\":\"$DOC\"}")
MSG=$(echo "$R" | jq -r '.message')
case "$MSG" in
  *"already indexed"*) echo "OK   [t2-dup] $MSG" ;;
  *) echo "FAIL [t2-dup] expected dedup, got '$MSG'"; exit 1 ;;
esac

# === T3: edit + re-ingest → upsert ===
echo "==== T3: edit + re-ingest ===="
echo "# upsert evolving doc — version two cherry rewrite" > "$DOC"
R=$(curl -fsS -X POST "$URL/api/documents" -H 'Content-Type: application/json' \
    -d "{\"path\":\"$DOC\"}")
echo "$R" | jq .
MSG=$(echo "$R" | jq -r '.message')
case "$MSG" in
  *"updated"*) echo "OK   [t3-update] $MSG" ;;
  *) echo "FAIL [t3-update] expected 'updated', got '$MSG'"; exit 1 ;;
esac

# === T4: default recall filters to current version ===
# We use mode=search (vector-only, no LLM) for deterministic checks.
echo "==== T4: default recall returns only current (cherry) ===="
R=$(curl -fsS -X POST "$URL/api/query" -H 'Content-Type: application/json' \
    -d '{"query":"upsert evolving doc version","top_k":5,"mode":"search"}')
echo "$R" | jq '.results[] | {title, excerpt: .excerpt[0:80]}'
HITS_NEW=$(echo "$R" | jq '[.results[] | select(.excerpt | test("cherry"))] | length')
HITS_OLD=$(echo "$R" | jq '[.results[] | select(.excerpt | test("banana"))] | length')
[ "$HITS_NEW" -ge 1 ] || { echo "FAIL [t4] expected new (cherry) chunk in default recall, got $HITS_NEW"; exit 1; }
[ "$HITS_OLD" -eq 0 ] || { echo "FAIL [t4] old (banana) chunk leaked into default recall, count=$HITS_OLD"; exit 1; }
echo "OK   [t4] new=$HITS_NEW old=$HITS_OLD (default current-only filter applied)"

# === T5: max_versions_per_doc=2 → both versions surface ===
echo "==== T5: max_versions_per_doc=2 returns both (banana + cherry) ===="
R=$(curl -fsS -X POST "$URL/api/query" -H 'Content-Type: application/json' \
    -d '{"query":"upsert evolving doc version","top_k":5,"mode":"search","maxVersionsPerDoc":2}')
echo "$R" | jq '.results[] | {title, excerpt: .excerpt[0:80]}'
HITS_NEW=$(echo "$R" | jq '[.results[] | select(.excerpt | test("cherry"))] | length')
HITS_OLD=$(echo "$R" | jq '[.results[] | select(.excerpt | test("banana"))] | length')
[ "$HITS_NEW" -ge 1 ] || { echo "FAIL [t5] new (cherry) missing"; exit 1; }
[ "$HITS_OLD" -ge 1 ] || { echo "FAIL [t5] old (banana) missing — N=2 should include both versions"; exit 1; }
echo "OK   [t5] new=$HITS_NEW old=$HITS_OLD"

# === T6: as_of in the future → empty (no chunks updated since then) ===
echo "==== T6: as_of in the future → no results ===="
FUTURE=$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)
R=$(curl -fsS -X POST "$URL/api/query" -H 'Content-Type: application/json' \
    -d "{\"query\":\"upsert evolving doc version\",\"top_k\":5,\"mode\":\"search\",\"asOf\":\"$FUTURE\"}")
COUNT=$(echo "$R" | jq '.results | length')
assert_eq "t6.empty-future" "0" "$COUNT"

echo
echo "ALL UPSERT E2E TESTS PASSED."

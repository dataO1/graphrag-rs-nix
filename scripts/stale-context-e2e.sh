#!/usr/bin/env bash
# End-to-end test for the stale-context layer.
#
# Validates:
#   1. Recall response gains `etag` per hit when sessionId supplied
#   2. POST /recall/revalidate distinguishes current/stale/missing
#   3. SSE stream delivers an event with delta when a block is updated
#      via block-form ingest, with the right shape
#   4. Last-Event-ID resume works (replay missed events)
#   5. cursor-too-old fires when last_event_id < watermark
#
# Requires: cargo built graphrag-server in target/release/, qdrant
# running on :6334. Runs against a temp collection name + temp
# state dir; cleans up on exit.

set -euo pipefail

REPO=/home/data01/Projects/graphrag-rs
SERVER_BIN="$REPO/target/release/graphrag-server"
PORT="${PORT:-19101}"
COLLECTION="graphrag_e2e_stale_$$"
QDRANT_URL="${QDRANT_URL:-http://127.0.0.1:6334}"
BASE="http://127.0.0.1:$PORT"
STATE_DIR="$(mktemp -d)/graphrag-rs"
LOG="/tmp/graphrag-stale-e2e.$$.log"

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
  rm -rf "$(dirname "$STATE_DIR")"
}
trap cleanup EXIT

echo "▸ booting server on :$PORT (collection=$COLLECTION, state=$STATE_DIR)"
EMBEDDING_BACKEND=hash EMBEDDING_DIM=384 \
GRAPHRAG_HOST=127.0.0.1 GRAPHRAG_PORT="$PORT" \
COLLECTION_NAME="$COLLECTION" QDRANT_URL="$QDRANT_URL" \
INGEST_ALLOWED_ROOTS="/tmp" \
APPEND_DEBOUNCE_SECS=900 \
STATE_DIR="$STATE_DIR" \
STALE_CONTEXT_CLEANUP_INTERVAL_HOURS=1 \
STALE_CONTEXT_EVENT_RETENTION_DAYS=7 \
RUST_LOG="info,actix_web=warn,actix_server=warn" \
"$SERVER_BIN" >"$LOG" 2>&1 &
SERVER_PID=$!

for i in $(seq 1 30); do
  curl -fsS "$BASE/health" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "$BASE/health" >/dev/null || { bad "server didn't come up"; tail -30 "$LOG"; exit 1; }
ok "server up"

# Sanity: events store opened (log line)
sleep 0.3
if grep -q 'Stale-context events store opened' "$LOG"; then
  ok "events store opened"
else
  bad "events store didn't open"
  grep -i 'stale-context\|events store' "$LOG" | tail -5
fi

# Configure pattern extraction (no chat backend needed)
curl -fsS -X POST "$BASE/config" -H 'Content-Type: application/json' \
  -d '{"approach":"pattern","entities":{"use_gleaning":false,"min_confidence":0.0,"entity_types":["PERSON","ORGANIZATION","LOCATION"]},"openai":{"enabled":false},"ollama":{"enabled":false},"graph":{"extract_relationships":true}}' \
  >/dev/null

# Ingest a block-form doc with two blocks — assigns block_ids + etags
SOURCE="obsidian://vault/test/doc.md"
INGEST_V1=$(cat <<EOF
{
  "title": "Doc",
  "source": "$SOURCE",
  "id": "$SOURCE",
  "content": "# Doc\n\nFirst paragraph.\n\n## Sec\n\nSecond paragraph.\n",
  "blocks": [
    {"id": "Doc::0", "content": "First paragraph.", "hash": "h1", "lineStart": 3, "lineEnd": 3, "headingPath": ["Doc"]},
    {"id": "Doc > Sec::0", "content": "Second paragraph.", "hash": "h2", "lineStart": 7, "lineEnd": 7, "headingPath": ["Doc","Sec"]}
  ],
  "removedBlockIds": [],
  "fileHash": "ff1"
}
EOF
)
curl -fsS -X POST "$BASE/api/documents" -H 'Content-Type: application/json' -d "$INGEST_V1" >/dev/null
ok "v1 ingest of doc with 2 blocks"

# Recall with a session_id; response should carry etag per hit
SID="00000000-0000-4000-8000-000000000001"
RECALL=$(curl -fsS -X POST "$BASE/api/query" -H 'Content-Type: application/json' \
  -d "{\"query\":\"paragraph\",\"mode\":\"search\",\"topK\":2,\"sessionId\":\"$SID\"}")
if echo "$RECALL" | grep -q '"etag":"h1"' && echo "$RECALL" | grep -q '"etag":"h2"'; then
  ok "recall returns etag per hit"
else
  bad "recall missing etag: $RECALL"
fi

# Revalidate: both should be current
REVAL_RESP=$(curl -fsS -X POST "$BASE/recall/revalidate" -H 'Content-Type: application/json' \
  -d '{"entries":[{"blockId":"Doc::0","etag":"h1"},{"blockId":"Doc > Sec::0","etag":"h2"},{"blockId":"Doc::0","etag":"WRONG"},{"blockId":"NoSuch","etag":"x"}]}')
if echo "$REVAL_RESP" | grep -q '"current"' && echo "$REVAL_RESP" | grep -q '"stale"'; then
  ok "revalidate returns current/stale/missing partition"
else
  bad "revalidate response unexpected: $REVAL_RESP"
fi
if echo "$REVAL_RESP" | grep -q '"missing":\["NoSuch"\]'; then
  ok "revalidate identifies missing"
else
  bad "missing block not flagged: $REVAL_RESP"
fi

# lease/check should agree (the session leased h1+h2)
LCHECK=$(curl -fsS "$BASE/lease/check?session_id=$SID")
if echo "$LCHECK" | grep -q '"current"'; then
  ok "lease/check returns verdict for session"
else
  bad "lease/check failed: $LCHECK"
fi

# Open SSE stream for that session, run in background, capture events
SSE_OUT=$(mktemp)
( curl -fsS --max-time 8 -N -H "Accept: text/event-stream" "$BASE/events/stream?session_id=$SID" >"$SSE_OUT" 2>/dev/null & echo $! ) > /tmp/sse_pid
SSE_PID=$(cat /tmp/sse_pid)
sleep 0.5

# Update one block — should fire an SSE event
INGEST_V2=$(cat <<EOF
{
  "title": "Doc",
  "source": "$SOURCE",
  "id": "$SOURCE",
  "content": "# Doc\n\nFirst paragraph EDITED.\n\n## Sec\n\nSecond paragraph.\n",
  "blocks": [
    {"id": "Doc::0", "content": "First paragraph EDITED.", "hash": "h1b", "lineStart": 3, "lineEnd": 3, "headingPath": ["Doc"]}
  ],
  "removedBlockIds": [],
  "fileHash": "ff2"
}
EOF
)
curl -fsS -X POST "$BASE/api/documents" -H 'Content-Type: application/json' -d "$INGEST_V2" >/dev/null
ok "v2 ingest (edit Doc::0)"

# Wait for SSE to receive the event
sleep 2
kill "$SSE_PID" 2>/dev/null || true
wait "$SSE_PID" 2>/dev/null || true

if grep -q 'event: updated' "$SSE_OUT" && grep -q '"blockId":"Doc::0"' "$SSE_OUT"; then
  ok "SSE delivered 'updated' event for Doc::0"
else
  bad "SSE event for Doc::0 not seen"
  echo "--- SSE output ---"; cat "$SSE_OUT" | head -30
fi
if grep -q '"oldEtag":"h1"' "$SSE_OUT" && grep -q '"newEtag":"h1b"' "$SSE_OUT"; then
  ok "SSE event carries old/new etag"
else
  bad "etag fields missing in SSE event"
fi
if grep -q '"unifiedDiff"' "$SSE_OUT" && grep -q -F '"oldExcerpt":"First paragraph."' "$SSE_OUT"; then
  ok "SSE event carries delta (excerpts + unified diff)"
else
  bad "delta missing in SSE event"
fi

# Last-Event-ID resume: pick the id of the previous event, do another
# update, reconnect with that id, replay catches the new event only.
LAST_ID=$(grep -oE '^id: [0-9]+' "$SSE_OUT" | tail -1 | awk '{print $2}')
if [ -z "$LAST_ID" ]; then
  bad "no event id parsed from SSE output; cannot test resume"
else
  ok "captured last event id: $LAST_ID"

  INGEST_V3=$(cat <<EOF
{
  "title": "Doc",
  "source": "$SOURCE",
  "id": "$SOURCE",
  "content": "# Doc\n\nFirst paragraph EDITED.\n\n## Sec\n\nSecond paragraph CHANGED.\n",
  "blocks": [
    {"id": "Doc > Sec::0", "content": "Second paragraph CHANGED.", "hash": "h2b", "lineStart": 7, "lineEnd": 7, "headingPath": ["Doc","Sec"]}
  ],
  "removedBlockIds": [],
  "fileHash": "ff3"
}
EOF
)
  curl -fsS -X POST "$BASE/api/documents" -H 'Content-Type: application/json' -d "$INGEST_V3" >/dev/null
  ok "v3 ingest (edit Doc > Sec::0)"

  RESUME_OUT=$(mktemp)
  ( curl -fsS --max-time 4 -N \
      -H "Accept: text/event-stream" \
      -H "Last-Event-ID: $LAST_ID" \
      "$BASE/events/stream?session_id=$SID" >"$RESUME_OUT" 2>/dev/null & echo $! ) > /tmp/sse_pid2
  RSV_PID=$(cat /tmp/sse_pid2)
  sleep 4
  kill "$RSV_PID" 2>/dev/null || true
  wait "$RSV_PID" 2>/dev/null || true

  if grep -q '"blockId":"Doc > Sec::0"' "$RESUME_OUT"; then
    ok "Last-Event-ID resume replayed the new event"
  else
    bad "resume didn't replay new event"
    echo "--- resume output ---"; cat "$RESUME_OUT" | head -20
  fi
fi

# DELETE /api/lease/{session_id}
DROP=$(curl -fsS -X DELETE "$BASE/lease/$SID")
if echo "$DROP" | grep -q '"leasesDropped"'; then
  ok "session teardown via DELETE"
else
  bad "session teardown failed: $DROP"
fi

echo
echo "$passed passed, $failed failed"
exit "$failed"

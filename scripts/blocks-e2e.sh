#!/usr/bin/env bash
# End-to-end test for block-aware ingest.
#
# Spins up a graphrag-server on an isolated port + qdrant collection,
# fires curl requests that mimic what the Obsidian plugin would send,
# verifies:
#   1. block-form ingest succeeds (HTTP 200, expected counts)
#   2. recall response carries source/lineRange/headingPath/blockId
#   3. editing one block re-embeds 1 chunk; siblings stay current
#   4. removing a block supersedes that chunk only
#
# Requires: cargo built graphrag-server in target/release/, qdrant
# running on :6334. Runs against a temp collection name, leaves the
# server stopped + collection dropped on exit.
set -euo pipefail

REPO=/home/data01/Projects/graphrag-rs
SERVER_BIN="$REPO/target/release/graphrag-server"
PORT="${PORT:-19001}"
COLLECTION="graphrag_e2e_blocks_$$"
QDRANT_URL="${QDRANT_URL:-http://127.0.0.1:6334}"
BASE="http://127.0.0.1:$PORT"

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
  curl -s -X DELETE "$QDRANT_URL/collections/$COLLECTION" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "▸ starting graphrag-server on :$PORT (collection=$COLLECTION)"
EMBEDDING_BACKEND=hash EMBEDDING_DIM=384 \
GRAPHRAG_HOST=127.0.0.1 \
GRAPHRAG_PORT="$PORT" \
COLLECTION_NAME="$COLLECTION" \
QDRANT_URL="$QDRANT_URL" \
INGEST_ALLOWED_ROOTS="/tmp" \
RUST_LOG="info,actix_web=warn,actix_server=warn" \
"$SERVER_BIN" > /tmp/graphrag-e2e.$$.log 2>&1 &
SERVER_PID=$!

# Wait for /health (max 30 s).
for i in $(seq 1 30); do
  if curl -fsS "$BASE/health" >/dev/null 2>&1; then break; fi
  sleep 1
done
if ! curl -fsS "$BASE/health" >/dev/null 2>&1; then
  bad "server didn't come up on :$PORT"
  echo "--- log ---"; tail -30 /tmp/graphrag-e2e.$$.log
  exit 1
fi
ok "server up"

# ── Test 1: block-form ingest with source ──
SOURCE="obsidian://vault/test/foo.md"
INGEST=$(cat <<EOF
{
  "title": "Foo",
  "source": "$SOURCE",
  "id": "$SOURCE",
  "content": "# Foo\n\nHello world.\n\n## Bar\n\nGoodbye.\n",
  "blocks": [
    {"id": "Foo::0", "content": "Hello world.", "hash": "h1", "lineStart": 3, "lineEnd": 3, "headingPath": ["Foo"]},
    {"id": "Foo > Bar::0", "content": "Goodbye.", "hash": "h2", "lineStart": 7, "lineEnd": 7, "headingPath": ["Foo", "Bar"]}
  ],
  "removedBlockIds": [],
  "fileHash": "ff1"
}
EOF
)
RESP=$(curl -fsS -X POST "$BASE/api/documents" -H 'Content-Type: application/json' -d "$INGEST")
if echo "$RESP" | grep -q '"success":true'; then ok "block-form ingest"; else bad "block-form ingest: $RESP"; fi
if echo "$RESP" | grep -q '"ingestedCount":2'; then ok "ingestedCount=2"; else bad "expected 2 ingested, got: $RESP"; fi

# ── Test 2: source rejection without source ──
NOSRC=$(cat <<'EOF'
{"title": "X", "content": "y", "id": "no-source-test"}
EOF
)
HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/documents" -H 'Content-Type: application/json' -d "$NOSRC")
if [ "$HTTP" = "400" ]; then ok "missing source → 400"; else bad "expected 400, got $HTTP"; fi

# ── Test 3: recall returns source + lineRange ──
sleep 1  # let the embed/index settle
QRESP=$(curl -fsS -X POST "$BASE/api/query" -H 'Content-Type: application/json' \
  -d '{"query":"hello","mode":"search","topK":3}')
if echo "$QRESP" | grep -q "\"source\":\"$SOURCE\""; then ok "recall result has source"; else bad "no source in recall: $QRESP"; fi
if echo "$QRESP" | grep -q '"lineStart":3'; then ok "recall result has lineStart"; else bad "no lineStart: $QRESP"; fi
if echo "$QRESP" | grep -q '"headingPath":\["Foo"\]'; then ok "recall result has headingPath"; else bad "no headingPath: $QRESP"; fi
if echo "$QRESP" | grep -q '"blockId":"Foo::0"'; then ok "recall result has blockId"; else bad "no blockId: $QRESP"; fi

# ── Test 4: edit one block (changed=1, expect ingestedCount=1) ──
EDIT=$(cat <<EOF
{
  "title": "Foo",
  "source": "$SOURCE",
  "id": "$SOURCE",
  "content": "# Foo\n\nHello edited world.\n\n## Bar\n\nGoodbye.\n",
  "blocks": [
    {"id": "Foo::0", "content": "Hello edited world.", "hash": "h1b", "lineStart": 3, "lineEnd": 3, "headingPath": ["Foo"]}
  ],
  "removedBlockIds": [],
  "fileHash": "ff2"
}
EOF
)
RESP=$(curl -fsS -X POST "$BASE/api/documents" -H 'Content-Type: application/json' -d "$EDIT")
if echo "$RESP" | grep -q '"ingestedCount":1'; then ok "edit-one-block re-embeds 1 chunk"; else bad "edit ingest: $RESP"; fi

# ── Test 5: remove a block ──
REMOVE=$(cat <<EOF
{
  "title": "Foo",
  "source": "$SOURCE",
  "id": "$SOURCE",
  "content": "# Foo\n\nHello edited world.\n",
  "blocks": [],
  "removedBlockIds": ["Foo > Bar::0"],
  "fileHash": "ff3"
}
EOF
)
RESP=$(curl -fsS -X POST "$BASE/api/documents" -H 'Content-Type: application/json' -d "$REMOVE")
if echo "$RESP" | grep -q '"ingestedCount":0'; then ok "remove-only → 0 ingested"; else bad "remove: $RESP"; fi
if echo "$RESP" | grep -q 'superseded'; then ok "remove → reported superseded"; else bad "remove no superseded msg: $RESP"; fi

echo
echo "$passed passed, $failed failed"
exit "$failed"

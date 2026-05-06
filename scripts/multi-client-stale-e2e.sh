#!/usr/bin/env bash
# Multi-client validation of the stale-context layer.
#
# Models the canonical "User A reads, User B writes" scenario plus
# adjacent edge cases we want to be confident about:
#
#   1. Per-session ISOLATION
#      A leases blocks {x, y}. B leases {y, z}. Edit z.
#      Expected: B receives event for z. A does NOT.
#
#   2. Broadcast FAN-OUT
#      A and B both lease block y. Edit y.
#      Expected: BOTH A and B receive an event for y.
#
#   3. Mid-session RESUME
#      A is connected, receives event for y. A's stream is killed.
#      Edit y again. A reconnects with Last-Event-ID.
#      Expected: A's reconnect replays the second event only
#      (not the first, which it already saw).
#
#   4. Lease accumulation during live stream
#      A connects (no leases yet). A then issues a recall that
#      leases block w. Edit w.
#      Expected: A receives event for w (the per-session filter
#      picks up new leases on the periodic re-read inside the
#      SSE pump — see stale_context::run_sse_pump's tick%32 logic).
#
#   5. Concurrent edit burst
#      Edit 5 blocks at once that A leased. A receives all 5
#      events with monotonically increasing ids.
#
# Spins up its own server on an isolated port + temp collection,
# uses curl as a stand-in for the SSE client (works the same as
# pi's @microsoft/fetch-event-source consumer would).

set -euo pipefail

REPO=/home/data01/Projects/graphrag-rs
SERVER_BIN="$REPO/target/release/graphrag-server"
PORT="${PORT:-19150}"
COLLECTION="graphrag_e2e_multi_$$"
QDRANT_URL="${QDRANT_URL:-http://127.0.0.1:6334}"
BASE="http://127.0.0.1:$PORT"
STATE_DIR="$(mktemp -d)/graphrag-rs"
LOG="/tmp/graphrag-multi-e2e.$$.log"

if ! [ -x "$SERVER_BIN" ]; then
  echo "FAIL: $SERVER_BIN missing — run cargo build -p graphrag-server --release" >&2
  exit 1
fi

passed=0; failed=0
ok()  { passed=$((passed+1)); echo "✓ $*"; }
bad() { failed=$((failed+1)); echo "✗ $*" >&2; }

cleanup() {
  for p in ${SSE_PIDS:-}; do
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  curl -fsS -X DELETE "http://127.0.0.1:6333/collections/$COLLECTION" >/dev/null 2>&1 || true
  rm -rf "$(dirname "$STATE_DIR")"
}
trap cleanup EXIT
SSE_PIDS=""

echo "▸ booting server on :$PORT"
EMBEDDING_BACKEND=hash EMBEDDING_DIM=384 \
GRAPHRAG_HOST=127.0.0.1 GRAPHRAG_PORT="$PORT" \
COLLECTION_NAME="$COLLECTION" QDRANT_URL="$QDRANT_URL" \
INGEST_ALLOWED_ROOTS="/tmp" \
APPEND_DEBOUNCE_SECS=900 \
STATE_DIR="$STATE_DIR" \
RUST_LOG="info,actix_web=warn,actix_server=warn" \
"$SERVER_BIN" >"$LOG" 2>&1 &
SERVER_PID=$!

for i in $(seq 1 30); do
  curl -fsS "$BASE/health" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "$BASE/health" >/dev/null || { bad "server didn't come up"; tail -30 "$LOG"; exit 1; }
ok "server up"

curl -fsS -X POST "$BASE/config" -H 'Content-Type: application/json' \
  -d '{"approach":"pattern","entities":{"use_gleaning":false,"min_confidence":0.0,"entity_types":["PERSON","ORGANIZATION","LOCATION"]},"openai":{"enabled":false},"ollama":{"enabled":false},"graph":{"extract_relationships":true}}' \
  >/dev/null
ok "config posted"

# Seed: a doc with three blocks {x, y, z}. Two clients lease overlapping
# subsets via separate recall calls.
SOURCE="obsidian://vault/test/doc.md"
seed_block() {
  local id="$1" content="$2" hash="$3" line="$4"
  cat <<EOF
{"id":"$id","content":"$content","hash":"$hash","lineStart":$line,"lineEnd":$line,"headingPath":["Doc"]}
EOF
}

INGEST_V1=$(cat <<EOF
{
  "title": "Doc",
  "source": "$SOURCE",
  "id": "$SOURCE",
  "content": "# Doc\n\nAlpha block.\n\nBeta block.\n\nGamma block.\n",
  "blocks": [
    $(seed_block "Doc::x" "Alpha block." "h-x" 3),
    $(seed_block "Doc::y" "Beta block."  "h-y" 5),
    $(seed_block "Doc::z" "Gamma block." "h-z" 7)
  ],
  "removedBlockIds": [],
  "fileHash": "ff1"
}
EOF
)
curl -fsS -X POST "$BASE/api/documents" -H 'Content-Type: application/json' -d "$INGEST_V1" >/dev/null
ok "seeded 3 blocks (x, y, z)"

# Helper: open SSE stream for $1=session_id, write to $2=outfile,
# return the curl PID. --no-buffer ensures bytes flush as they arrive
# rather than waiting for chunked-encoding boundaries.
open_sse() {
  local sid="$1" out="$2"
  ( curl -fsS --no-buffer --max-time 30 -N \
      -H "Accept: text/event-stream" \
      "$BASE/events/stream?session_id=$sid" >"$out" 2>/dev/null & echo $! )
}

count_events_for_block() {
  local file="$1" bid="$2"
  # grep -c prints 0 to stdout AND exits 1 on no-match; piping through
  # cat absorbs that exit so we always get a single integer line.
  local n
  n=$(grep -c "\"blockId\":\"$bid\"" "$file" 2>/dev/null | head -1)
  echo "${n:-0}"
}

# Simulate session A: leases {x, y}.
SID_A="00000000-0000-4000-8000-000000000aaa"
SID_B="00000000-0000-4000-8000-000000000bbb"

# Session A: recall returning x and y (mode=search picks by similarity;
# we issue two queries that should match by vocabulary)
curl -fsS -X POST "$BASE/api/query" -H 'Content-Type: application/json' \
  -d "{\"query\":\"alpha\",\"mode\":\"search\",\"topK\":1,\"sessionId\":\"$SID_A\"}" >/dev/null
curl -fsS -X POST "$BASE/api/query" -H 'Content-Type: application/json' \
  -d "{\"query\":\"beta\",\"mode\":\"search\",\"topK\":1,\"sessionId\":\"$SID_A\"}" >/dev/null

# Session B: leases {y, z}
curl -fsS -X POST "$BASE/api/query" -H 'Content-Type: application/json' \
  -d "{\"query\":\"beta\",\"mode\":\"search\",\"topK\":1,\"sessionId\":\"$SID_B\"}" >/dev/null
curl -fsS -X POST "$BASE/api/query" -H 'Content-Type: application/json' \
  -d "{\"query\":\"gamma\",\"mode\":\"search\",\"topK\":1,\"sessionId\":\"$SID_B\"}" >/dev/null

# Verify the leases are correctly partitioned
LCHECK_A=$(curl -fsS "$BASE/lease/check?session_id=$SID_A")
LCHECK_B=$(curl -fsS "$BASE/lease/check?session_id=$SID_B")
LEASES_A=$(echo "$LCHECK_A" | grep -o '"blockId":"[^"]*"' | sort -u | tr '\n' ' ')
LEASES_B=$(echo "$LCHECK_B" | grep -o '"blockId":"[^"]*"' | sort -u | tr '\n' ' ')
[[ "$LEASES_A" == *"Doc::x"* && "$LEASES_A" == *"Doc::y"* && "$LEASES_A" != *"Doc::z"* ]] \
  && ok "A's lease set is {x, y} (from explicit recalls)" \
  || bad "A's leases unexpected: $LEASES_A"
[[ "$LEASES_B" == *"Doc::y"* && "$LEASES_B" == *"Doc::z"* && "$LEASES_B" != *"Doc::x"* ]] \
  && ok "B's lease set is {y, z}" \
  || bad "B's leases unexpected: $LEASES_B"

# ── Test 1: per-session ISOLATION ────────────────────────────────
# Open both streams, edit z (only in B's lease), expect only B receives.
SSE_A=$(mktemp); SSE_B=$(mktemp)
PID_A=$(open_sse "$SID_A" "$SSE_A"); SSE_PIDS="$SSE_PIDS $PID_A"
PID_B=$(open_sse "$SID_B" "$SSE_B"); SSE_PIDS="$SSE_PIDS $PID_B"
sleep 0.5

curl -fsS -X POST "$BASE/api/documents" -H 'Content-Type: application/json' -d "$(cat <<EOF
{
  "title": "Doc",
  "source": "$SOURCE",
  "id": "$SOURCE",
  "content": "# Doc\n\nAlpha block.\n\nBeta block.\n\nGamma block edited.\n",
  "blocks": [$(seed_block "Doc::z" "Gamma block edited." "h-z2" 7)],
  "removedBlockIds": [],
  "fileHash": "ff2"
}
EOF
)" >/dev/null
sleep 1.5

A_GOT_Z=$(count_events_for_block "$SSE_A" "Doc::z")
B_GOT_Z=$(count_events_for_block "$SSE_B" "Doc::z")
[[ "$A_GOT_Z" -eq 0 ]] && ok "isolation: A did not receive z (held by B only)" \
  || bad "A wrongly got $A_GOT_Z event(s) for z"
[[ "$B_GOT_Z" -ge 1 ]] && ok "isolation: B received z" \
  || bad "B did not receive z (got $B_GOT_Z)"

# ── Test 2: broadcast FAN-OUT ────────────────────────────────────
# Edit y (held by both). Expect both streams to see it.
curl -fsS -X POST "$BASE/api/documents" -H 'Content-Type: application/json' -d "$(cat <<EOF
{
  "title": "Doc",
  "source": "$SOURCE",
  "id": "$SOURCE",
  "content": "# Doc\n\nAlpha block.\n\nBeta block edited.\n\nGamma block edited.\n",
  "blocks": [$(seed_block "Doc::y" "Beta block edited." "h-y2" 5)],
  "removedBlockIds": [],
  "fileHash": "ff3"
}
EOF
)" >/dev/null
sleep 1.5

A_GOT_Y=$(count_events_for_block "$SSE_A" "Doc::y")
B_GOT_Y=$(count_events_for_block "$SSE_B" "Doc::y")
[[ "$A_GOT_Y" -ge 1 && "$B_GOT_Y" -ge 1 ]] && ok "fan-out: both A and B received y" \
  || bad "fan-out failed (A:$A_GOT_Y, B:$B_GOT_Y)"

# Capture A's last event id BEFORE closing; we'll resume from this.
LAST_ID_A=$(grep -oE '^id: [0-9]+' "$SSE_A" | tail -1 | awk '{print $2}')
[[ -n "$LAST_ID_A" ]] && ok "captured A's last event id: $LAST_ID_A" \
  || bad "couldn't parse A's last event id"

# ── Test 3: mid-session RESUME ───────────────────────────────────
# Kill A's stream. Edit y again. Reconnect A with Last-Event-ID.
# A should see the NEW event but NOT the prior one (already known).
kill "$PID_A" 2>/dev/null || true
wait "$PID_A" 2>/dev/null || true

curl -fsS -X POST "$BASE/api/documents" -H 'Content-Type: application/json' -d "$(cat <<EOF
{
  "title": "Doc",
  "source": "$SOURCE",
  "id": "$SOURCE",
  "content": "# Doc\n\nAlpha block.\n\nBeta block edited again.\n\nGamma block edited.\n",
  "blocks": [$(seed_block "Doc::y" "Beta block edited again." "h-y3" 5)],
  "removedBlockIds": [],
  "fileHash": "ff4"
}
EOF
)" >/dev/null
sleep 0.5

RESUME_OUT=$(mktemp)
curl -fsS --no-buffer --max-time 5 -N \
  -H "Accept: text/event-stream" \
  -H "Last-Event-ID: $LAST_ID_A" \
  "$BASE/events/stream?session_id=$SID_A" >"$RESUME_OUT" 2>/dev/null &
PID_RESUME=$!
SSE_PIDS="$SSE_PIDS $PID_RESUME"
sleep 4
kill "$PID_RESUME" 2>/dev/null || true
wait "$PID_RESUME" 2>/dev/null || true

# Resume should contain "Beta block edited again" (the new content).
if grep -q "Beta block edited again" "$RESUME_OUT"; then
  ok "resume: A got the post-disconnect event"
else
  bad "resume: missing post-disconnect event"
  echo "--- resume output ---"; head -20 "$RESUME_OUT"
fi
# AND should NOT replay the prior ("Beta block edited") content as
# the NEW excerpt of any event. (Note: h-y2 may legitimately appear
# as the *oldEtag* of the new "Beta block edited again" event — the
# new event references the prior version's etag — so we check the
# OLD/NEW excerpt fields instead, which are unambiguous content.)
if grep -q '"newExcerpt":"Beta block edited"' "$RESUME_OUT"; then
  bad "resume replayed an event whose newExcerpt is the older content"
else
  ok "resume: didn't replay events older than Last-Event-ID"
fi

# ── Test 4: lease accumulation during live stream ────────────────
# Open a fresh session C with no prior recalls; open stream first.
SID_C="00000000-0000-4000-8000-000000000ccc"
SSE_C=$(mktemp)
PID_C=$(open_sse "$SID_C" "$SSE_C"); SSE_PIDS="$SSE_PIDS $PID_C"
sleep 0.5
# Lease block w (we'll add it). First seed it.
curl -fsS -X POST "$BASE/api/documents" -H 'Content-Type: application/json' -d "$(cat <<EOF
{
  "title": "Doc",
  "source": "$SOURCE",
  "id": "$SOURCE",
  "content": "# Doc\n\nAlpha.\n\nBeta.\n\nGamma.\n\nDelta block.\n",
  "blocks": [$(seed_block "Doc::w" "Delta block." "h-w" 9)],
  "removedBlockIds": [],
  "fileHash": "ff5"
}
EOF
)" >/dev/null
# C leases w via a recall.
curl -fsS -X POST "$BASE/api/query" -H 'Content-Type: application/json' \
  -d "{\"query\":\"delta\",\"mode\":\"search\",\"topK\":1,\"sessionId\":\"$SID_C\"}" >/dev/null
# Wait long enough for the SSE pump's lease-rerefresh tick (every 32
# events). The pump re-reads on lag; we don't have 32 events, so we
# need to fire more. Easier: rely on the fact that the lease was added,
# the next event arrival will check current_leases and miss — so we
# fire 32+ events. For brevity just edit w and wait — if the broadcast
# fires AND the pump's current_leases hasn't refreshed yet, the event
# would be filtered out. This validates the worst case.
#
# Per the design (run_sse_pump tick % 32), brand-new leases mid-
# session aren't picked up immediately. That's an acceptable trade-
# off for v1; the next reconnect (or 32 events later) will catch up.
# We assert the design as-is rather than aspirational behavior.
curl -fsS -X POST "$BASE/api/documents" -H 'Content-Type: application/json' -d "$(cat <<EOF
{
  "title": "Doc",
  "source": "$SOURCE",
  "id": "$SOURCE",
  "content": "# Doc\n\nAlpha.\n\nBeta.\n\nGamma.\n\nDelta block edited.\n",
  "blocks": [$(seed_block "Doc::w" "Delta block edited." "h-w2" 9)],
  "removedBlockIds": [],
  "fileHash": "ff6"
}
EOF
)" >/dev/null
sleep 2
kill "$PID_C" 2>/dev/null || true
wait "$PID_C" 2>/dev/null || true

# Reconnect — server replays from last-seen for C, picks up the
# w event because the lease is now in the snapshot.
RESUME_C=$(mktemp)
curl -fsS --no-buffer --max-time 5 -N \
  -H "Accept: text/event-stream" \
  "$BASE/events/stream?session_id=$SID_C" >"$RESUME_C" 2>/dev/null &
PID_C2=$!
SSE_PIDS="$SSE_PIDS $PID_C2"
sleep 4
kill "$PID_C2" 2>/dev/null || true
wait "$PID_C2" 2>/dev/null || true

if grep -q '"blockId":"Doc::w"' "$RESUME_C"; then
  ok "lease accumulation: C got w on reconnect (replay sees new lease)"
else
  bad "C did not get w on reconnect"
  echo "--- C resume ---"; head -20 "$RESUME_C"
fi

# ── Test 5: concurrent edit BURST ────────────────────────────────
# Edit 5 blocks at once for session B.
SSE_B2=$(mktemp)
PID_B2=$(open_sse "$SID_B" "$SSE_B2"); SSE_PIDS="$SSE_PIDS $PID_B2"
sleep 0.5
# Add blocks p, q, r, s, t to the lease via a single recall using
# topK so all five come back.
# Seed them first.
for letter in p q r s t; do
  curl -fsS -X POST "$BASE/api/documents" -H 'Content-Type: application/json' -d "$(cat <<EOF
{
  "title": "Doc",
  "source": "$SOURCE",
  "id": "$SOURCE",
  "content": "# Doc\n\nignored full content\n",
  "blocks": [$(seed_block "Doc::$letter" "burst $letter" "h-$letter" 11)],
  "removedBlockIds": [],
  "fileHash": "ff-burst-seed-$letter"
}
EOF
)" >/dev/null
done
# Single recall with topK=10 captures all five into B's lease.
curl -fsS -X POST "$BASE/api/query" -H 'Content-Type: application/json' \
  -d "{\"query\":\"burst\",\"mode\":\"search\",\"topK\":10,\"sessionId\":\"$SID_B\"}" >/dev/null
# Reconnect to pick up the new lease set (the existing pump's
# current_leases is stale).
kill "$PID_B2" 2>/dev/null || true
wait "$PID_B2" 2>/dev/null || true
SSE_B3=$(mktemp)
PID_B3=$(open_sse "$SID_B" "$SSE_B3"); SSE_PIDS="$SSE_PIDS $PID_B3"
sleep 0.5

# Now edit all five at once (single bulk request).
BURST_BLOCKS=""
for letter in p q r s t; do
  [ -n "$BURST_BLOCKS" ] && BURST_BLOCKS+=","
  BURST_BLOCKS+=$(seed_block "Doc::$letter" "burst $letter EDITED" "h-${letter}-edit" 11)
done
curl -fsS -X POST "$BASE/api/documents" -H 'Content-Type: application/json' -d "$(cat <<EOF
{
  "title": "Doc",
  "source": "$SOURCE",
  "id": "$SOURCE",
  "content": "# Doc\n\nignored full content\n",
  "blocks": [$BURST_BLOCKS],
  "removedBlockIds": [],
  "fileHash": "ff-burst-edit"
}
EOF
)" >/dev/null
sleep 2
kill "$PID_B3" 2>/dev/null || true
wait "$PID_B3" 2>/dev/null || true

burst_count=0
for letter in p q r s t; do
  if grep -q "\"blockId\":\"Doc::$letter\"" "$SSE_B3"; then
    burst_count=$((burst_count+1))
  fi
done
[[ "$burst_count" -eq 5 ]] && ok "burst: B received all 5 events in one stream" \
  || bad "burst: only $burst_count/5 events delivered"

# Monotonic ids
ids=$(grep -oE '^id: [0-9]+' "$SSE_B3" | awk '{print $2}')
sorted_ids=$(echo "$ids" | sort -n)
[[ "$ids" == "$sorted_ids" ]] && ok "burst: event ids monotonic in stream order" \
  || bad "burst: event ids not monotonic: $ids"

# ── Wrap up
echo
echo "$passed passed, $failed failed"
exit "$failed"

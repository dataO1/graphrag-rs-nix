#!/usr/bin/env bash
set -eu
SERVER=/home/data01/Projects/graphrag-rs-nix/result/bin/graphrag-server
ROOT=/tmp/graphrag-test/notes
COLL="coalescer_$$"
LOG=/tmp/graphrag-test/coalescer.log

cleanup() {
  rc=$?
  [ -n "${SERVER_PID:-}" ] && { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
  curl -fsS -X DELETE "http://127.0.0.1:6333/collections/$COLL" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT

# Boot server with debounce=5s (short for the test)
EMBEDDING_BACKEND=hash EMBEDDING_DIM=384 \
QDRANT_URL=http://127.0.0.1:6334 COLLECTION_NAME="$COLL" \
RUST_LOG=info,actix_web=warn,actix_server=warn \
INGEST_ALLOWED_ROOTS="$ROOT" \
APPEND_DEBOUNCE_SECS=5 \
"$SERVER" >"$LOG" 2>&1 &
SERVER_PID=$!

# Wait for /health
for i in $(seq 1 60); do
  curl -fs --max-time 2 http://127.0.0.1:8080/health >/dev/null && break
  sleep 0.5
done

echo "=== boot log ==="
grep -E "(auto-append loop|ingest:|backend=)" "$LOG" | head

echo
echo "=== fire 3 ingests in quick succession ==="
T0=$(date +%s)
for f in smoke-1.md smoke-2.md sub/nested.md ; do
  echo "  ingest $f at $(($(date +%s)-T0))s"
  curl -fsS -X POST http://127.0.0.1:8080/api/documents \
    -H 'Content-Type: application/json' \
    -d "{\"path\":\"$ROOT/$f\"}" >/dev/null
done

echo
echo "=== watch the log for the auto-append (expect ~5s after last ingest) ==="
# Match both success ("auto-append: <msg>") and failure ("auto-append
# failed; ...") — both prove the coalescer woke + fired
# do_append_graph. The test stubs out a chat backend so failure is
# expected here; the timing is what matters.
for i in $(seq 1 15); do
  sleep 1
  if grep -qE "auto-append (failed|:)" "$LOG"; then
    DT=$(($(date +%s)-T0))
    echo "  T+${DT}s : COALESCER FIRED (expected ~5s)"
    grep -E "auto-append" "$LOG" | tail -3
    if [ "$DT" -lt 4 ] || [ "$DT" -gt 7 ]; then
      echo "  WARN: timing outside expected [4..7]s window"
      exit 2
    fi
    exit 0
  fi
done
echo "  FAIL: no auto-append in 15s after burst"
tail -25 "$LOG"
exit 1

#!/usr/bin/env bash
# End-to-end smoke test for path-based POST /api/documents.
#
# Spins up a fresh graphrag-server in the background pointed at:
#   - hash embeddings (no NPU/Ollama dep)
#   - the live qdrant on 127.0.0.1:6334 with a unique collection
#   - INGEST_ALLOWED_ROOTS = /tmp/graphrag-test/notes
#   - INGEST_PREPROCESSOR_URL unset (so .bin gets `unsupported`)
#
# Then exercises every body shape of POST /api/documents and asserts
# the response status / counts. Exits non-zero on any failure.
set -euo pipefail

SERVER=/home/data01/Projects/graphrag-rs-nix/result/bin/graphrag-server
ROOT=/tmp/graphrag-test/notes
LOG=/tmp/graphrag-test/server.log
URL="http://127.0.0.1:8080"

[ -x "$SERVER" ] || { echo "missing $SERVER — run nix build first"; exit 1; }
mkdir -p "$ROOT"

# Replace the placeholder binary with real binary bytes (printf so the
# byte sequence is well-defined; the file must be reproducibly non-UTF-8
# so the allow-list path classifies it as unsupported).
printf '\x00\x01\x02\x03\xff\xfe\xfd\xfc' > "$ROOT/smoke-binary.bin"

COLLECTION="ingest_smoke_$$"
echo "qdrant collection: $COLLECTION"

cleanup() {
  rc=$?
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  curl -fsS -X DELETE "http://127.0.0.1:6333/collections/$COLLECTION" >/dev/null 2>&1 || true
  if [ "$rc" -ne 0 ]; then
    echo "==== SMOKE FAILED — server log tail ===="
    tail -60 "$LOG" || true
  fi
  exit "$rc"
}
trap cleanup EXIT

EMBEDDING_BACKEND=hash \
EMBEDDING_DIM=384 \
QDRANT_URL=http://127.0.0.1:6334 \
COLLECTION_NAME="$COLLECTION" \
RUST_LOG=warn,graphrag_server=info \
INGEST_ALLOWED_ROOTS="$ROOT" \
INGEST_MAX_FILE_BYTES=10485760 \
"$SERVER" >"$LOG" 2>&1 &
SERVER_PID=$!

for i in $(seq 1 60); do
  if curl -fs --max-time 2 "$URL/health" >/dev/null; then break; fi
  sleep 0.5
done
curl -fs --max-time 2 "$URL/health" >/dev/null || { echo "server never came up"; exit 1; }

assert_eq() { # name expected actual
  if [ "$2" != "$3" ]; then
    echo "FAIL [$1] expected=$2 actual=$3"; exit 1;
  fi
  echo "OK   [$1] $3"
}

echo "==== T1: legacy {title, content} body still works ===="
R=$(curl -fsS -X POST "$URL/api/documents" -H 'Content-Type: application/json' \
    -d '{"title":"legacy-1","content":"hello legacy world"}')
echo "$R" | jq .
SUCCESS=$(echo "$R" | jq -r '.success')
assert_eq "legacy.success" "true" "$SUCCESS"

echo "==== T2: single {path} ingests one file ===="
R=$(curl -fsS -X POST "$URL/api/documents" -H 'Content-Type: application/json' \
    -d "{\"path\":\"$ROOT/smoke-1.md\"}")
echo "$R" | jq .
SUCCESS=$(echo "$R" | jq -r '.success')
DOCID=$(echo "$R" | jq -r '.documentId // empty')
assert_eq "path.success" "true" "$SUCCESS"
[ -n "$DOCID" ] || { echo "FAIL [path] empty documentId"; exit 1; }
echo "OK   [path] documentId=$DOCID"

echo "==== T3: re-ingest same path → content_hash dedup ===="
R=$(curl -fsS -X POST "$URL/api/documents" -H 'Content-Type: application/json' \
    -d "{\"path\":\"$ROOT/smoke-1.md\"}")
echo "$R" | jq .
MSG=$(echo "$R" | jq -r '.message // empty')
case "$MSG" in
  *"already indexed"*) echo "OK   [dedup] message: $MSG" ;;
  *) echo "FAIL [dedup] expected 'already indexed' in '$MSG'"; exit 1 ;;
esac

echo "==== T4: pathsGlob expands and ingests multiple files ===="
R=$(curl -fsS -X POST "$URL/api/documents" -H 'Content-Type: application/json' \
    -d "{\"pathsGlob\":\"*.md\",\"globRoot\":\"$ROOT\"}")
echo "$R" | jq .
ING=$(echo "$R" | jq -r '.ingestedCount // 0')
SK=$(echo "$R"  | jq -r '.skippedCount  // 0')
[ "$ING" -ge 1 ] || { echo "FAIL [glob] ingestedCount=$ING < 1"; exit 1; }
[ "$SK"  -ge 1 ] || { echo "FAIL [glob] skippedCount=$SK < 1"; exit 1; }
echo "OK   [glob] ingested=$ING skipped=$SK"

echo "==== T5: binary file is unsupported (no preprocessor) ===="
R=$(curl -fsS -X POST "$URL/api/documents" -H 'Content-Type: application/json' \
    -d "{\"paths\":[\"$ROOT/smoke-binary.bin\"]}")
echo "$R" | jq .
ST=$(echo "$R" | jq -r '.results[0].status')
assert_eq "binary.status" "unsupported" "$ST"

echo "==== T6: out-of-sandbox path is rejected ===="
R=$(curl -fsS -X POST "$URL/api/documents" -H 'Content-Type: application/json' \
    -d '{"paths":["/tmp/graphrag-test/escape-attempt.md"]}')
echo "$R" | jq .
ST=$(echo "$R" | jq -r '.results[0].status')
assert_eq "escape.status" "rejected" "$ST"

echo "==== T7: non-existent path is rejected ===="
R=$(curl -fsS -X POST "$URL/api/documents" -H 'Content-Type: application/json' \
    -d "{\"paths\":[\"$ROOT/does-not-exist.md\"]}")
echo "$R" | jq .
ST=$(echo "$R" | jq -r '.results[0].status')
assert_eq "missing.status" "rejected" "$ST"

echo "==== T8: ambiguous body (content + path) → 400 ===="
HTTP=$(curl -s -o /tmp/graphrag-test/t8.json -w '%{http_code}' \
  -X POST "$URL/api/documents" -H 'Content-Type: application/json' \
  -d "{\"content\":\"x\",\"path\":\"$ROOT/smoke-1.md\"}")
cat /tmp/graphrag-test/t8.json | jq .
assert_eq "ambiguous.status_code" "400" "$HTTP"

echo "==== T9: empty body → 400 ===="
HTTP=$(curl -s -o /tmp/graphrag-test/t9.json -w '%{http_code}' \
  -X POST "$URL/api/documents" -H 'Content-Type: application/json' -d '{}')
cat /tmp/graphrag-test/t9.json | jq .
assert_eq "empty.status_code" "400" "$HTTP"

echo "==== T10: list_documents reflects ingests ===="
R=$(curl -fsS "$URL/api/documents")
COUNT=$(echo "$R" | jq -r '.total')
echo "list total=$COUNT"
[ "$COUNT" -ge 3 ] || { echo "FAIL [list] expected >=3, got $COUNT"; exit 1; }
echo "OK   [list] total=$COUNT"

echo "==== T11: glob with absolute pattern (no globRoot) ===="
mkdir -p "$ROOT/sub"
echo "# nested file" > "$ROOT/sub/nested.md"
R=$(curl -fsS -X POST "$URL/api/documents" -H 'Content-Type: application/json' \
    -d "{\"pathsGlob\":\"$ROOT/sub/*.md\"}")
echo "$R" | jq .
ING=$(echo "$R" | jq -r '.ingestedCount // 0')
[ "$ING" -ge 1 ] || { echo "FAIL [abs-glob] ingestedCount=$ING < 1"; exit 1; }
echo "OK   [abs-glob] ingested=$ING"

echo "==== T12: glob outside allowed root is rejected ===="
HTTP=$(curl -s -o /tmp/graphrag-test/t12.json -w '%{http_code}' \
  -X POST "$URL/api/documents" -H 'Content-Type: application/json' \
  -d '{"pathsGlob":"*.md","globRoot":"/etc"}')
cat /tmp/graphrag-test/t12.json | jq .
assert_eq "outside-glob.status_code" "400" "$HTTP"

echo
echo "ALL SMOKE TESTS PASSED."

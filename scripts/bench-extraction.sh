#!/usr/bin/env bash
# Benchmark recall-extraction throughput against the running graphrag-rs
# service. Picks N already-extracted chunks at random from qdrant,
# clears their `entities_extracted_at` flag (re-marking them as
# unextracted), then triggers `POST /api/graph/append` synchronously
# and measures how long it takes the server to drain. Restores the
# flag on whatever was missed so we don't leak unextracted state.
#
# Compares apples-to-apples across upstream model swaps: the work is
# always "extract entities + relationships from N production chunks
# from your live vault." Run twice — once before/after a Nix module
# change (e.g. swap the chat model, bump APPEND_BATCH_SIZE, change
# llm.max) — to see how the change moved end-to-end throughput.
#
# Requires `jq` and `curl`. Defaults match the home-manager-deployed
# graphrag-rs on neo-16:
#   GRAPHRAG_URL  = http://127.0.0.1:17180
#   QDRANT_URL    = http://127.0.0.1:6333
#   COLLECTION    = graphrag
#
# Usage:
#   bench-extraction.sh [N]              # N = chunk count, default 128
#   N=64 bench-extraction.sh             # alternate way to set N
#
# Caveats:
# - Uses the LIVE qdrant collection — runs against your real graph,
#   not a sandbox. The chunks you re-extract get re-extracted; the
#   resulting entity set can change slightly from one run to the
#   next due to LLM nondeterminism. The graph isn't corrupted, but
#   relationship counts may drift by a few across runs.
# - Holds the writer mutex while extraction runs; concurrent recalls
#   continue (Layer 4 ArcSwap snapshot is wait-free), but a parallel
#   POST /api/graph/append from another caller will queue.

set -euo pipefail

N="${1:-${N:-128}}"
GRAPHRAG_URL="${GRAPHRAG_URL:-http://127.0.0.1:17180}"
QDRANT_URL="${QDRANT_URL:-http://127.0.0.1:6333}"
COLLECTION="${COLLECTION:-graphrag}"

command -v jq >/dev/null || { echo "bench: jq required" >&2; exit 1; }

echo "[bench] target: $GRAPHRAG_URL  qdrant: $QDRANT_URL/collections/$COLLECTION"
echo "[bench] sample size: $N chunks"

# 1. Pick N already-extracted chunks. We filter on
#    `entities_extracted_at` set (i.e. extracted at least once) so we
#    benchmark on real production chunks instead of accidentally
#    grabbing the unextracted backlog. `with_payload=false` keeps the
#    response small.
echo "[bench] scrolling qdrant for $N extracted chunks..."
ids_json=$(curl -sS -X POST \
  "$QDRANT_URL/collections/$COLLECTION/points/scroll" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --argjson n "$N" '{
    limit: $n,
    with_payload: false,
    with_vector: false,
    filter: { must: [ { key: "entities_extracted_at", range: { gte: 0 } } ] }
  }')" | jq -c '[.result.points[].id]')

picked=$(echo "$ids_json" | jq 'length')
if [ "$picked" -eq 0 ]; then
  echo "[bench] no extracted chunks found — has /api/graph/append run yet?" >&2
  exit 1
fi
echo "[bench] selected $picked chunks"

# 2. Clear `entities_extracted_at` on those points so the auto-append
#    loop / manual POST treats them as fresh. `payload/delete` removes
#    the field; the point itself is preserved.
echo "[bench] clearing entities_extracted_at flag..."
del_resp=$(curl -sS -X POST \
  "$QDRANT_URL/collections/$COLLECTION/points/payload/delete?wait=true" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --argjson ids "$ids_json" '{
    keys: ["entities_extracted_at"],
    points: $ids
  }')")
del_status=$(echo "$del_resp" | jq -r '.status // "error"')
if [ "$del_status" != "ok" ]; then
  echo "[bench] qdrant payload delete failed:" >&2
  echo "$del_resp" | jq . >&2
  exit 1
fi

# 3. Drive extraction synchronously. POST /api/graph/append walks the
#    unextracted set in pages of APPEND_BATCH_SIZE and returns when
#    the cycle finishes. We time the call wall-clock.
echo "[bench] firing POST /api/graph/append (synchronous, will block until extraction completes)..."
start=$(date +%s.%N)
resp=$(curl -sS -X POST "$GRAPHRAG_URL/api/graph/append" -H 'Content-Type: application/json' -d '{}')
end=$(date +%s.%N)
elapsed=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.2f", e - s }')

# 4. Pull the headline counters from the response. Field names match
#    BuildGraphResponse / ExtendSummary on the server.
chunks_processed=$(echo "$resp" | jq -r '.chunksProcessed // .documentCount // 0')
new_entities=$(echo "$resp" | jq -r '.newEntities // 0')
new_relationships=$(echo "$resp" | jq -r '.newRelationships // 0')
mentions_merged=$(echo "$resp" | jq -r '.mentionsMerged // 0')

# Throughput: chunks per second, rounded to 2 decimals. Doesn't measure
# tokens (the server doesn't expose total output tokens on this path);
# pair with `journalctl --user -u graphrag-rs -f` and the vLLM journal
# if you want token-level rates.
if [ "$chunks_processed" -gt 0 ]; then
  rate=$(awk -v c="$chunks_processed" -v t="$elapsed" 'BEGIN { printf "%.2f", c / t }')
else
  rate="0.00"
fi

echo
echo "[bench] ====== results ======"
echo "[bench] requested chunks:    $N"
echo "[bench] picked chunks:       $picked"
echo "[bench] chunks_processed:    $chunks_processed"
echo "[bench] new_entities:        $new_entities"
echo "[bench] new_relationships:   $new_relationships"
echo "[bench] mentions_merged:     $mentions_merged"
echo "[bench] wall time (s):       $elapsed"
echo "[bench] throughput (ch/s):   $rate"
echo "[bench] ====================="

# Helpful pointers — print the response on a debug envvar so the user
# can audit the full server reply without making it the default.
if [ "${BENCH_DEBUG:-0}" = "1" ]; then
  echo "[bench] full response:"
  echo "$resp" | jq .
fi

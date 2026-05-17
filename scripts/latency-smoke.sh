#!/usr/bin/env bash
# Recall-latency smoke against the running graphrag-rs service.
# Runs three phases against a small built-in query set and prints a
# markdown table of per-phase {min, median, max} wall_ms plus the last
# `retrieve_phase=summary` line per phase pulled from journalctl (the
# Card 13/14/15 instrumentation).
#
#   Phase 1: N cold hipporag recalls (serial)            — end-to-end p50
#   Phase 2: N search-mode recalls (no LLM synthesis)    — fast vector path
#   Phase 3: N concurrent hipporag recalls (parallel)    — Spark 2 contention
#
# Use this to validate a deploy: run it before/after a graphrag-rs
# flake-lock bump + home-manager switch to see how the change moved
# recall latency. The PPR-direct-solver migration (origin/openai-compat
# e5d6a74) is the reason this exists: ppr_run_ms 22518 -> 9-10ms ought
# to be reproducible across future deploys, and a regression to >100ms
# would flag a config or matrix-construction bug worth investigating.
#
# Defaults match the home-manager-deployed graphrag-rs on neo-16:
#   GRAPHRAG_URL = http://127.0.0.1:17180
#   N            = 10
#   SERVICE_UNIT = graphrag-rs.service  (user-scoped)
#
# Usage:
#   latency-smoke.sh [N]                    # N per phase, default 10
#   N=20 latency-smoke.sh                   # alternate way to set N
#   QUERIES="q1|q2|q3" latency-smoke.sh     # pipe-separated override
#
# Requires: curl, awk, date (ns precision), journalctl.
# Output: markdown table on stdout; optionally redirect to a results file.

set -euo pipefail

N="${1:-${N:-10}}"
GRAPHRAG_URL="${GRAPHRAG_URL:-http://127.0.0.1:17180}"
SERVICE_UNIT="${SERVICE_UNIT:-graphrag-rs.service}"

DEFAULT_QUERIES="what is the PPR direct solver?|how does HippoRAG retrieve?|what is the CSC col_ptr bug?|what is PRPACK fidelity?|how does faer LU work?|what is the synthesis LLM?|what is Spark 1 Qwen3.6?|what is NPU OVMS embedding?|how is reranker disabled in HippoRAG?|what is the recall concurrency budget?|what is dotfiles flake.lock?|what is OVMS NPU pull?|what is graphrag-rs-nix?|what is neo-16 host?|what is home-manager switch?|what is direnv?|what is qdrant?|what is mneme?|what is HippoRAG paper?|what is sparse LU factorization?"

QUERIES="${QUERIES:-${DEFAULT_QUERIES}}"

# Split queries on '|' into an array; take first N.
IFS='|' read -ra Q_ALL <<< "${QUERIES}"
if (( ${#Q_ALL[@]} < N )); then
    echo "ERROR: have ${#Q_ALL[@]} queries but N=$N; provide more via QUERIES env" >&2
    exit 1
fi
Q=("${Q_ALL[@]:0:$N}")

# ── Helpers ─────────────────────────────────────────────────────────────────
ms_now() { date +%s%N | awk '{print int($1 / 1000000)}'; }

# Single recall call; prints wall_ms server_ms (tab-separated) to stdout.
recall_one() {
    local mode="$1" query="$2" start_ms end_ms server_ms
    start_ms=$(ms_now)
    local resp
    resp=$(curl -sf -m 120 -X POST "${GRAPHRAG_URL}/api/query" \
        -H 'content-type: application/json' \
        -d "{\"query\":\"${query//\"/\\\"}\",\"mode\":\"${mode}\"}" 2>&1) || {
        echo "$(ms_now)\tERROR" ; return ;
    }
    end_ms=$(ms_now)
    server_ms=$(echo "$resp" | grep -oE '"processingTimeMs":[0-9]+' | grep -oE '[0-9]+' | head -1)
    printf '%d\t%s\n' "$((end_ms - start_ms))" "${server_ms:-N/A}"
}

# Stats over a column of integers on stdin: min, p50, max.
stats() {
    awk 'BEGIN { OFS="\t" }
        { a[NR]=$1 }
        END {
            if (NR == 0) { print "N/A","N/A","N/A"; exit }
            n = asort(a)
            mid = (n % 2 == 1) ? a[(n+1)/2] : int((a[n/2] + a[n/2+1]) / 2)
            print a[1], mid, a[n]
        }'
}

# Pull the most recent `retrieve_phase=summary` line from the journal.
last_summary() {
    journalctl --user -u "$SERVICE_UNIT" -n 200 --no-pager 2>/dev/null \
        | grep -F 'retrieve_phase="summary"' | tail -1
}

# ── Preflight ───────────────────────────────────────────────────────────────
if ! curl -sf -m 5 "${GRAPHRAG_URL}/health" >/dev/null 2>&1; then
    echo "ERROR: ${GRAPHRAG_URL}/health unreachable; is graphrag-rs.service up?" >&2
    exit 1
fi

bin_path=$(systemctl --user show "$SERVICE_UNIT" -p MainPID --value 2>/dev/null \
    | xargs -I {} sh -c 'cat /proc/{}/cmdline 2>/dev/null | tr "\0" " "')

echo "## graphrag-rs latency smoke — $(date -Iseconds)"
echo
echo "**Service**: \`${SERVICE_UNIT}\` @ \`${GRAPHRAG_URL}\`  "
echo "**Binary**: \`$(echo "$bin_path" | awk '{print $1}')\`  "
echo "**N per phase**: $N"
echo

# ── Phase 1: cold hipporag (serial) ─────────────────────────────────────────
echo "### Phase 1 — $N cold hipporag recalls (serial)"
echo
P1_RESULTS=$(for q in "${Q[@]}"; do recall_one hipporag "$q"; done)
read -r P1_MIN P1_MED P1_MAX <<< "$(echo "$P1_RESULTS" | awk '{print $1}' | stats)"
P1_SUMMARY=$(last_summary)
echo "| metric | min | median | max |"
echo "|---|---|---|---|"
echo "| wall_ms | $P1_MIN | $P1_MED | $P1_MAX |"
echo
echo "Last journal summary:"
echo
echo "\`\`\`"
echo "$P1_SUMMARY"
echo "\`\`\`"
echo

# ── Phase 2: search-mode (serial) ───────────────────────────────────────────
echo "### Phase 2 — $N search-mode recalls (no LLM synthesis)"
echo
P2_RESULTS=$(for q in "${Q[@]}"; do recall_one search "$q"; done)
read -r P2_MIN P2_MED P2_MAX <<< "$(echo "$P2_RESULTS" | awk '{print $1}' | stats)"
echo "| metric | min | median | max |"
echo "|---|---|---|---|"
echo "| wall_ms | $P2_MIN | $P2_MED | $P2_MAX |"
echo

# ── Phase 3: concurrent hipporag ────────────────────────────────────────────
echo "### Phase 3 — $N concurrent hipporag recalls (parallel)"
echo
P3_START=$(ms_now)
P3_TMP=$(mktemp)
for q in "${Q[@]}"; do (recall_one hipporag "$q" >> "$P3_TMP") & done
wait
P3_END=$(ms_now)
P3_BATCH=$((P3_END - P3_START))
read -r P3_MIN P3_MED P3_MAX <<< "$(awk '{print $1}' "$P3_TMP" | stats)"
rm -f "$P3_TMP"
echo "| metric | min | median | max | batch_total |"
echo "|---|---|---|---|---|"
echo "| wall_ms | $P3_MIN | $P3_MED | $P3_MAX | $P3_BATCH |"
echo
echo "Parallelism: $(awk "BEGIN { printf \"%.2f\", ($P1_MED * $N) / $P3_BATCH }")× vs serial-equivalent."
echo

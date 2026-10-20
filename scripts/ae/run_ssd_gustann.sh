#!/bin/bash

set -o pipefail

HOME_DIR=$(readlink -f "$(dirname "$0")/../..")
# shellcheck source=scripts/ae/ae-setup.sh
source "$HOME_DIR/scripts/ae/ae-setup.sh" || exit 1
init_root_experiment "$@" || exit 1
trap finish_experiment EXIT

NUM_SSDS=$(awk 'NF && $1 !~ /^#/ { count++ } END { print count + 0 }' "$SSD_LIST")
(( NUM_SSDS > 0 )) || { echo "ERROR: Empty SSD list: $SSD_LIST" >&2; exit 1; }

sift100m_setup
require_search_inputs raw || exit 1
INDEX_FILE=${INDEX_PREFIX}_disk.index
PQ_FILE=${INDEX_PREFIX}_pq

# The raw striping layout changes with the SSD count, so rewrite every round.
[[ -f $INDEX_FILE ]] || { echo "ERROR: Index file not found: $INDEX_FILE" >&2; exit 1; }
gpu_run "$HOME_DIR/build/spdk/spdk_write" "$INDEX_FILE" "$SSD_LIST" || exit 1

echo "[REPORT] SIFT100M GustANN SSD $NUM_SSDS TOP 10 EF 30"
run_case gpu_run "$HOME_DIR/build/bin/search_disk_hybrid" \
    --query "$QUERY_FILE" --index "$INDEX_FILE" --ground_truth "$GT_FILE" \
    --pq_data "$PQ_FILE" --nav_graph "$NAV_GRAPH" --ssd_list_file "$SSD_LIST" \
    -B 1120 -T 2 -C 20 --topk 10 --ef_search 30 -R 500

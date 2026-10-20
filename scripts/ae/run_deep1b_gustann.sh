#!/bin/bash

set -o pipefail

HOME_DIR=$(readlink -f "$(dirname "$0")/../..")
source "$HOME_DIR"/scripts/ae/ae-setup.sh || exit 1
init_root_experiment "$@" || exit 1
trap finish_experiment EXIT

deep1b_setup;
require_search_inputs raw || exit 1

INDEX_FILE=${INDEX_PREFIX}_disk.index
PQ_FILE=${INDEX_PREFIX}_pq
EXEC=search_disk_hybrid_float

"$HOME_DIR"/scripts/ae/write_spdk_ae.sh "$INDEX_FILE" "$SSD_LIST" || exit 1

# TOP-1
for ef in 15 30 45 60 75 90 105 120 135 150; do
    echo "[REPORT]" TOP 1 EF $ef
    run_case gpu_run "$HOME_DIR"/build/bin/$EXEC --query "$QUERY_FILE" --index "$INDEX_FILE"  --ground_truth "$GT_FILE" \
                              --pq_data "$PQ_FILE" --nav_graph "$NAV_GRAPH" --ssd_list_file "$SSD_LIST" \
                              -B $((1120)) -T 2 -C 20 --topk 1 --ef_search $ef -R 500;
done

# TOP-10
for ef in 35 50 70 90 110 130 150 170 185 200; do
    echo "[REPORT]" TOP 10 EF $ef
    run_case gpu_run "$HOME_DIR"/build/bin/$EXEC --query "$QUERY_FILE" --index "$INDEX_FILE"  --ground_truth "$GT_FILE" \
                              --pq_data "$PQ_FILE" --nav_graph "$NAV_GRAPH" --ssd_list_file "$SSD_LIST" \
                              -B $((1120)) -T 2 -C 20 --topk 10 --ef_search $ef -R 500;
done

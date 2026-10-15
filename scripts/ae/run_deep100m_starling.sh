#!/bin/bash

set -o pipefail

HOME_DIR=$(readlink -f "$(dirname "$0")/../..")
source "$HOME_DIR"/scripts/ae/ae-setup.sh || exit 1
trap finish_experiment EXIT
#EXEC=search_disk_hybrid

deep100m_setup
require_search_inputs bin || exit 1
copy_index_to_target || exit 1
cp -auL -- "$NAV_GRAPH" "$TARGET_DIR/" || exit 1
mkdir -p "$TARGET_DIR/starling" || exit 1
cp -auL -- "$INDEX_DIR/starling/gp_part_tmp.index"* "$TARGET_DIR/starling/" || exit 1

# SIFT100M
RESULT_PATH=$TMP_DIR

INDEX_FILE=$TARGET_PREFIX
DISK_FILE=$TARGET_DIR/starling/gp_part_tmp.index
NAV_GRAPH=$TARGET_DIR/nav/nav_index

echo "[REPORT] TOP 1"
run_case "${STARLING_DIR}"/build/tests/search_disk_index --data_type float --dist_fn l2 --index_path_prefix  "$INDEX_FILE" --result_path "$RESULT_PATH"/deep100m-1-starling --query_file "$QUERY_BIN_FILE" --num_nodes_to_cache 1000000 -T 112 -W 4 --mem_L 32 --mem_index_path "$NAV_GRAPH" --use_page_search 1 --use_ratio 0.3 --disk_file_path "$DISK_FILE" --use_sq 0  -K 1 -L 8 15 20 25 30 35 40 45 50 60 70 80 8 15 20 25 30 35 40 45 50 60 70 80

echo "[REPORT] TOP 10"
run_case "${STARLING_DIR}"/build/tests/search_disk_index --data_type float --dist_fn l2 --index_path_prefix  "$INDEX_FILE" --result_path "$RESULT_PATH"/deep100m-10-starling --query_file "$QUERY_BIN_FILE" --num_nodes_to_cache 1000000 -T 112 -W 4 --mem_L 32 --mem_index_path "$NAV_GRAPH" --use_page_search 1 --use_ratio 0.3 --disk_file_path "$DISK_FILE" --use_sq 0  -K 10 -L 25 30 35 40 45 50 55 60 70 80 90 100 120 140 25 30 35 40 45 50 55 60 70 80 90 100 120 140

for i in "$RESULT_PATH"/deep100m-*-starling_*_idx_uint32.bin; do
    [[ -f $i ]] || { echo "ERROR: No result files found" >&2; EXPERIMENT_FAILED=1; continue; }
    printf '[REPORT] %s' "$i"
    run_case "$HOME_DIR"/build/bin/check_recall "$i" "$GT_FILE"
done



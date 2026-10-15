#!/bin/bash

set -o pipefail

HOME_DIR=$(readlink -f "$(dirname "$0")/../..")
source "$HOME_DIR"/scripts/ae/ae-setup.sh || exit 1
trap finish_experiment EXIT

deep1b_setup
require_search_inputs bin || exit 1
copy_index_to_target || exit 1

RESULT_PATH=$TMP_DIR
INDEX_FILE=$TARGET_PREFIX

echo "[REPORT] TOP 1"
run_case "${DISKANN_DIR}"/build/apps/search_disk_index --data_type float --dist_fn l2 --index_path_prefix  "$INDEX_FILE" --result_path "$RESULT_PATH"/deep1b-1-diskann --query_file "$QUERY_BIN_FILE" -T 112 --num_nodes_to_cache 1000000\
              -K 1 -L 15 30 45 60 75 90 105 120 135 150 15 30 45 60 75 90 105 120 135 150 -W 4

echo "[REPORT] TOP 10"
run_case "${DISKANN_DIR}"/build/apps/search_disk_index --data_type float --dist_fn l2 --index_path_prefix  "$INDEX_FILE" --result_path "$RESULT_PATH"/deep1b-10-diskann --query_file "$QUERY_BIN_FILE" -T 112 --num_nodes_to_cache 1000000\
              -K 10 -L 35 50 70 90 110 130 150 170 185 200 35 50 70 90 110 130 150 170 185 200 -W 4

for i in "$RESULT_PATH"/deep1b-*-diskann_*_idx_uint32.bin; do
    [[ -f $i ]] || { echo "ERROR: No result files found" >&2; EXPERIMENT_FAILED=1; continue; }
    printf '[REPORT] %s' "$i"
    run_case "$HOME_DIR"/build/bin/check_recall "$i" "$GT_FILE"
done



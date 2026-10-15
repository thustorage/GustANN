#!/bin/bash

set -o pipefail

HOME_DIR=$(readlink -f "$(dirname "$0")/../..")
DISKANN_DIR=$HOME_DIR/deps/DiskANN
source "$HOME_DIR"/scripts/ae/ae-setup.sh || exit 1
trap finish_experiment EXIT

sift1b_setup
require_search_inputs bin || exit 1
copy_index_to_target || exit 1

RESULT_PATH=$HOME_DIR/tmp
INDEX_FILE=$TARGET_PREFIX

echo "[REPORT] TOP 1"
run_case "${DISKANN_DIR}"/build/apps/search_disk_index --data_type uint8 --dist_fn l2 --index_path_prefix  "$INDEX_FILE" --result_path "$RESULT_PATH"/sift1b-1-diskann --query_file "$QUERY_BIN_FILE" -T 112 --num_nodes_to_cache 1000000\
              -K 1 -L 12 20 30 40 50 60 70 80 90 100 120 12 12 20 30 40 50 60 70 80 90 100 120 -W 4

echo "[REPORT] TOP 10"
run_case "${DISKANN_DIR}"/build/apps/search_disk_index --data_type uint8 --dist_fn l2 --index_path_prefix  "$INDEX_FILE" --result_path "$RESULT_PATH"/sift1b-10-diskann --query_file "$QUERY_BIN_FILE" -T 112 --num_nodes_to_cache 1000000\
               -K 10 -L 20 30 40 50 60 70 80 90 110 130 150 20 30 40 50 60 70 80 90 110 130 150 -W 4

echo "[REPORT] TOP 10 MOCK"
run_case "${DISKANN_DIR}"/build/apps/search_disk_index --data_type uint8 --dist_fn l2 --index_path_prefix  "$INDEX_FILE" --result_path "$RESULT_PATH"/sift1b-10-diskann_mock --query_file "$QUERY_BIN_FILE_MOCK" -T 112 --num_nodes_to_cache 1000000\
              -K 10 -L 20 30 40 50 60 70 80 90 110 130 150 20 30 40 50 60 70 80 90 110 130 150 -W 4


for i in "$RESULT_PATH"/sift1b-*-diskann_*_idx_uint32.bin; do
    [[ -f $i ]] || { echo "ERROR: No result files found" >&2; EXPERIMENT_FAILED=1; continue; }
    if [[ ${i##*/} == *_mock_* ]]; then
        echo "[REPORT] ${i} recall skipped (mock queries have no matching ground truth)"
        continue
    fi
    printf '[REPORT] %s' "$i"
    run_case "$HOME_DIR"/build/bin/check_recall "$i" "$GT_FILE"
done



#!/bin/bash

set -o pipefail

HOME_DIR=$(readlink -f "$(dirname "$0")/../..")
source "$HOME_DIR"/scripts/ae/ae-setup.sh || exit 1
trap finish_experiment EXIT

# DEEP100M
deep100m_setup;
require_search_inputs bin || exit 1
copy_index_to_target || exit 1

INDEX_FILE=$TARGET_PREFIX
RESULT_PATH=$TMP_DIR

echo Exp: DEEP100M k=1 DiskANN

echo "[REPORT] TOP 1"
run_case "${DISKANN_DIR}"/build/apps/search_disk_index --data_type float --dist_fn l2 \
              --index_path_prefix "$INDEX_FILE" --result_path "$RESULT_PATH"/deep100m-1-diskann \
              --query_file "$QUERY_BIN_FILE" -T 112 --num_nodes_to_cache 1000000 \
              -K 1 -L 8 15 20 25 30 35 40 45 50 60 70 80 8 15 20 25 30 35 40 45 50 60 70 80  -W 4

echo Exp: DEEP100M k=10 DiskANN

echo "[REPORT] TOP 10"
run_case "${DISKANN_DIR}"/build/apps/search_disk_index --data_type float --dist_fn l2 \
              --index_path_prefix  "$INDEX_FILE" --result_path "$RESULT_PATH"/deep100m-10-diskann \
              --query_file "$QUERY_BIN_FILE" -T 112 --num_nodes_to_cache 1000000\
              -K 10 -L 25 30 35 40 45 50 55 60 70 80 90 100 120 140 25 30 35 40 45 50 55 60 70 80 90 100 120 140 -W 4


for i in "$RESULT_PATH"/deep100m-*-diskann_*_idx_uint32.bin; do
    [[ -f $i ]] || { echo "ERROR: No result files found" >&2; EXPERIMENT_FAILED=1; continue; }
    printf '[REPORT] %s' "$i"
    run_case "$HOME_DIR"/build/bin/check_recall "$i" "$GT_FILE"
done



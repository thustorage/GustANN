#!/bin/bash

set -o pipefail

HOME_DIR=$(readlink -f "$(dirname "$0")/../..")
DISKANN_DIR=$HOME_DIR/deps/DiskANN
source "$HOME_DIR"/scripts/ae/ae-setup.sh || exit 1
trap finish_experiment EXIT

deep100m_setup;
require_search_inputs bin || exit 1
copy_index_to_target || exit 1
cp -auL -- "$NAV_GRAPH" "$TARGET_DIR/" || exit 1
NAV_GRAPH=$TARGET_DIR/nav

# DEEP100M

REP_DIR=${TEMP_INDEX_TARGET_DIR}/rep
REP_INDEX_FILE=$REP_DIR/index_R128_L200_disk.index
REP_PQ_FILE=$REP_DIR/index_R128_L200_pq
REP_QUERY_FILE=$REP_DIR/query.fvecs
REP_QUERY_BIN=$REP_DIR/query.fbin
REP_NAV=$REP_DIR/nav
REP_PREFIX=$REP_DIR/index_R128_L200

RESULT_PATH=$TMP_DIR


# REP=1
echo "[REPORT] Rep 1"
run_case "${DISKANN_DIR}"/build/apps/search_disk_index \
              --data_type float --dist_fn l2 --index_path_prefix "$TARGET_PREFIX" \
              --result_path "$RESULT_PATH"/deep100m-10-diskann-rep-1 --query_file "$QUERY_BIN_FILE" -T 112 \
              --num_nodes_to_cache 1000000 \
              -K 10 -L 45 45 45 -W 4

for rep in 2 3 4 5 6 7 8 9; do
    rm -rf "$REP_DIR" || exit 1
    mkdir -p "$REP_DIR" || exit 1
    mkdir -p "$REP_NAV" || exit 1
    "$HOME_DIR"/build/bin/trans_vec "${TARGET_PREFIX}"_disk.index "${TARGET_PREFIX}"_pq_pivots.bin $rep "$REP_INDEX_FILE" "${REP_PQ_FILE}"_pivots.bin "$NAV_GRAPH"/nav_index.data "$REP_NAV"/nav_index.data || exit 1
    ln -s "$NAV_GRAPH"/nav_index "$REP_NAV"/nav_index || exit 1
    ln -s "$NAV_GRAPH"/map.txt "$REP_NAV"/map.txt || exit 1
    ln -s "${TARGET_PREFIX}"_pq_compressed.bin "${REP_PQ_FILE}"_compressed.bin || exit 1
    python3 "$HOME_DIR"/scripts/ae/change_query.py "$QUERY_FILE" $rep "$REP_QUERY_FILE" || exit 1
    "${DISKANN_DIR}"/build/apps/utils/fvecs_to_bin float "$REP_QUERY_FILE" "$REP_QUERY_BIN" || exit 1


    echo "[REPORT] Rep" $rep
    run_case "${DISKANN_DIR}"/build/apps/search_disk_index \
              --data_type float --dist_fn l2 --index_path_prefix "$REP_PREFIX" \
              --result_path "$RESULT_PATH"/deep100m-10-diskann-rep-${rep} --query_file "$REP_QUERY_BIN" -T 112 \
              --num_nodes_to_cache 1000000 \
              -K 10 -L 45 45 45 45 45 -W 4

done

for i in "$RESULT_PATH"/deep100m-*-diskann-rep*_*_idx_uint32.bin; do
    [[ -f $i ]] || { echo "ERROR: No result files found" >&2; EXPERIMENT_FAILED=1; continue; }
    printf '[REPORT] %s' "$i"
    run_case "$HOME_DIR"/build/bin/check_recall "$i" "$GT_FILE"
done

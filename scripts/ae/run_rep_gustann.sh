#!/bin/bash

set -o pipefail

HOME_DIR=$(readlink -f "$(dirname "$0")/../..")
source "$HOME_DIR"/scripts/ae/ae-setup.sh || exit 1
init_root_experiment "$@" || exit 1

DAEMON_PID=
function stop_monitor() {
    if [[ -n $DAEMON_PID ]]; then
        kill "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
        DAEMON_PID=
    fi
}
trap 'status=$?; stop_monitor; finish_experiment "$status"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# please modify the place for these files (similar to scripts/setup.sh)
deep100m_setup;
require_search_inputs raw || exit 1

EXEC=search_disk_hybrid_float

INDEX_FILE=${INDEX_PREFIX}_disk.index
PQ_FILE=${INDEX_PREFIX}_pq

REP_DIR=${TEMP_INDEX_DIR}/rep/
REP_INDEX_FILE=$REP_DIR/index_R128_L200_disk.index
REP_PQ_FILE=$REP_DIR/index_R128_L200_pq
REP_QUERY_FILE=$REP_DIR/query.fvecs
REP_NAV=$REP_DIR/nav

LOG_DIR=$TMP_DIR
mkdir -p "$LOG_DIR" || exit 1

# REP=1

"$HOME_DIR"/scripts/ae/write_spdk_ae.sh "$INDEX_FILE" "$SSD_LIST" || exit 1
DATE=$(date +"%m%d")
LOG=${LOG_DIR}/rep-deep-1-$DATE.log
nvidia-smi dmon -s t -i "$CUDA_VISIBLE_DEVICES" >"$LOG" &
DAEMON_PID=$!
echo "[REPORT] Rep 1"
run_case gpu_run "$HOME_DIR"/build/bin/$EXEC --query "$QUERY_FILE" --index "$INDEX_FILE"  --ground_truth "$GT_FILE" \
                          --pq_data "$PQ_FILE" --nav_graph "$NAV_GRAPH" --ssd_list_file "$SSD_LIST" \
                          -B 1120 -T 2 -C 20 --topk 10 --ef_search 45 -R 500
kill "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=
echo "=== PCIe LOG ==="
cat "$LOG"
echo ================

for rep in 2 3 4 5 6 7 8 9; do
    rm -rf "$REP_DIR" || exit 1
    mkdir -p "$REP_DIR" || exit 1
    mkdir -p "$REP_NAV" || exit 1
    "$HOME_DIR"/build/bin/trans_vec "$INDEX_FILE" "${PQ_FILE}"_pivots.bin $rep "$REP_INDEX_FILE" "${REP_PQ_FILE}"_pivots.bin "$NAV_GRAPH"/nav_index.data "$REP_NAV"/nav_index.data || exit 1
    ln -s "$NAV_GRAPH"/nav_index "$REP_NAV"/nav_index || exit 1
    ln -s "$NAV_GRAPH"/map.txt "$REP_NAV"/map.txt || exit 1
    ln -s "${PQ_FILE}"_compressed.bin "${REP_PQ_FILE}"_compressed.bin || exit 1
    python3 "$HOME_DIR"/scripts/ae/change_query.py "$QUERY_FILE" $rep "$REP_QUERY_FILE" || exit 1
    "$HOME_DIR"/scripts/ae/write_spdk_ae.sh "$REP_INDEX_FILE" "$SSD_LIST" || exit 1

    LOG=${LOG_DIR}/rep-deep-$rep-$DATE.log

    nvidia-smi dmon -s t -i "$CUDA_VISIBLE_DEVICES" >"$LOG" &
    DAEMON_PID=$!

    echo "[REPORT] Rep" $rep
    run_case gpu_run "$HOME_DIR"/build/bin/$EXEC --query "$REP_QUERY_FILE" --index "$REP_INDEX_FILE"  --ground_truth "$GT_FILE" \
                              --pq_data "$REP_PQ_FILE" --nav_graph "$REP_NAV" --ssd_list_file "$SSD_LIST" \
                              -B 1120 -T 2 -C 20 --topk 10 --ef_search 45 -R 500


    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
    DAEMON_PID=

    echo "=== PCIe LOG ==="
    cat "$LOG"
    echo ================
done

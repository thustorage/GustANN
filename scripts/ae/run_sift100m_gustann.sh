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
sift100m_setup;
require_search_inputs raw || exit 1

INDEX_FILE=${INDEX_PREFIX}_disk.index
PQ_FILE=${INDEX_PREFIX}_pq
EXEC=search_disk_hybrid
LOG_DIR=$TMP_DIR

"$HOME_DIR"/scripts/ae/write_spdk_ae.sh "$INDEX_FILE" "$SSD_LIST" || exit 1

echo Exp: SIFT100M k=1 GustANN

# TOP-1
for ef in 8 15 20 25 30 35 40 45 50 55 60; do
#for ef in 8 60; do
    echo "[REPORT]" TOP 1 EF $ef
    run_case gpu_run "$HOME_DIR"/build/bin/$EXEC --query "$QUERY_FILE" --index "$INDEX_FILE" --ground_truth "$GT_FILE" \
                              --pq_data "$PQ_FILE" --nav_graph "$NAV_GRAPH"  --ssd_list_file "$SSD_LIST" \
                              -B $((1120)) -T 2 -C 20 --topk 1 --ef_search $ef -R 500
done

echo Exp: SIFT100M k=10 GustANN
# TOP-10
for ef in 18 25 30 35 40 45 50 55 60 70 80 90 100; do
#for ef in 18 100; do
    echo "[REPORT]" TOP 10 EF $ef
    run_case gpu_run "$HOME_DIR"/build/bin/$EXEC --query "$QUERY_FILE" --index "$INDEX_FILE"  --ground_truth "$GT_FILE" \
                              --pq_data "$PQ_FILE" --nav_graph "$NAV_GRAPH" --ssd_list_file "$SSD_LIST" \
                              -B $((1120)) -T 2 -C 20 --topk 10 --ef_search $ef -R 500;
done

# PCIe measurement

DATE=$(date +"%m%d")
LOG=${LOG_DIR}/sift100m-gustann-$DATE.log
nvidia-smi dmon -s t -i "$CUDA_VISIBLE_DEVICES" >"$LOG" &
DAEMON_PID=$!
run_case gpu_run "$HOME_DIR"/build/bin/$EXEC --query "$QUERY_FILE" --index "$INDEX_FILE"  --ground_truth "$GT_FILE" \
                          --pq_data "$PQ_FILE" --nav_graph "$NAV_GRAPH" --ssd_list_file "$SSD_LIST" \
                          -B 1120 -T 2 -C 20 --topk 10 --ef_search 30 -R 500
kill "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=
echo "=== PCIe LOG ==="
cat "$LOG"
echo ================

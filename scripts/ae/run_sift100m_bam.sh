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

# SIFT1B
sift100m_setup
require_search_inputs raw || exit 1

INDEX_FILE=${INDEX_PREFIX}_disk.index
PQ_FILE=${INDEX_PREFIX}_pq

EXEC=search_disk

NUM_CTRLS=$(awk 'NF { count++ } END { print count + 0 }' "$SSD_LIST") || exit 1
LOG_DIR=$TMP_DIR

gpu_run "$HOME_DIR"/build/bin/$EXEC --num_ctrls "$NUM_CTRLS" --query "$QUERY_FILE" --index "$INDEX_FILE" --ground_truth "$GT_FILE" --cache_page 60000 --pq_data "$PQ_FILE" --nav_graph "$NAV_GRAPH" --copy_only --copy_data || exit 1


# TOP-10
for ef in 18 25 30 35 40 45 50 55 60 70 80 90; do
    echo "[REPORT]" TOP 10 EF $ef
    run_case gpu_run "$HOME_DIR"/build/bin/$EXEC --num_ctrls "$NUM_CTRLS" --query "$QUERY_FILE" --index "$INDEX_FILE" \
                              --ground_truth "$GT_FILE" --topk 10 --ef_search $ef \
                              --cache_page 60000 --pq_data "$PQ_FILE" --nav_graph "$NAV_GRAPH" -R 50;
done

# PCIe

DATE=$(date +"%m%d")
LOG=${LOG_DIR}/sift100m-bam-$DATE.log
nvidia-smi dmon -s t -i "$CUDA_VISIBLE_DEVICES" >"$LOG" &
DAEMON_PID=$!
run_case gpu_run "$HOME_DIR"/build/bin/$EXEC --num_ctrls "$NUM_CTRLS" --query "$QUERY_FILE" --index "$INDEX_FILE" \
                          --ground_truth "$GT_FILE" --topk 10 --ef_search 30 \
                          --cache_page 60000 --pq_data "$PQ_FILE" --nav_graph "$NAV_GRAPH" -R 50;
kill "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=
echo "=== PCIe LOG ==="
cat "$LOG"
echo ================

#!/bin/bash

set -o pipefail
shopt -s nullglob

HOME_DIR=$(readlink -f "$(dirname "$0")/../..")
# shellcheck source=scripts/ae/ae-setup.sh
source "$HOME_DIR/scripts/ae/ae-setup.sh" || exit 1
trap finish_experiment EXIT

if (( $# != 1 )) || [[ ! ${1:-} =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: $0 <ssd-count>" >&2
    exit 1
fi
NUM_SSDS=$1
sift100m_setup
require_search_inputs bin || exit 1
copy_index_to_target || exit 1

RESULT_DIR=$TMP_DIR/ssd
mkdir -p "$RESULT_DIR" || exit 1
RESULT_PREFIX=$RESULT_DIR/sift100m-${NUM_SSDS}-diskann

echo "[REPORT] SIFT100M DiskANN SSD $NUM_SSDS TOP 10 L 30"
run_case "$DISKANN_DIR/build/apps/search_disk_index" \
    --data_type uint8 --dist_fn l2 --index_path_prefix "$TARGET_PREFIX" \
    --result_path "$RESULT_PREFIX" --query_file "$QUERY_BIN_FILE" \
    -T 112 --num_nodes_to_cache 1000000 -K 10 -L 30 30 -W 4

results=("${RESULT_PREFIX}"*_idx_uint32.bin)
(( ${#results[@]} > 0 )) || { echo "ERROR: No results found for $RESULT_PREFIX" >&2; exit 1; }
for result in "${results[@]}"; do
    printf '[REPORT] SSD %s %s ' "$NUM_SSDS" "$result"
    run_case "$HOME_DIR/build/bin/check_recall" "$result" "$GT_FILE"
done

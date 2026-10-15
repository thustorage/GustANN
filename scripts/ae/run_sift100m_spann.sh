#!/bin/bash

set -o pipefail

HOME_DIR=$(readlink -f "$(dirname "$0")/../..")
source "$HOME_DIR"/scripts/ae/ae-setup.sh || exit 1
trap finish_experiment EXIT

sift100m_setup
require_search_inputs bin || exit 1
prepare_target_dir "$SPANN_TARGET_DIR" || exit 1
cp -auL -- "$SPANN_INDEX_DIR/." "$SPANN_TARGET_DIR/" || exit 1
CONFIG_FILE=$TMP_DIR/sift100m-spann.ini

function run() {
    echo "[REPORT] K $1 EF $2"
    sed -e "s|CHANGE_L|$2|g" \
        -e "s|CHANGE_K|$1|g" \
        -e "s|CHANGE_VECTOR_PATH|$VECTOR_FILE|g" \
        -e "s|CHANGE_QUERY_PATH|$QUERY_BIN_FILE|g" \
        -e "s|CHANGE_WARMUP_PATH|$QUERY_BIN_FILE|g" \
        -e "s|CHANGE_TRUTH_PATH|$GT_FILE|g" \
        -e "s|CHANGE_INDEX_DIRECTORY|$SPANN_TARGET_DIR|g" \
        "$HOME_DIR/scripts/ae/sift100m_template_spann.ini" > "$CONFIG_FILE" || return 1
    run_case "$SPANN_DIR/Release/ssdserving" "$CONFIG_FILE"

}

for ef in 15 30 50 60 80 100 120 140 160 180 200 250; do
    run 1 $ef || exit 1
done

for ef in 25 40 50 60 80 100 125 150 200 250 300 350; do
    run 10 $ef || exit 1
done

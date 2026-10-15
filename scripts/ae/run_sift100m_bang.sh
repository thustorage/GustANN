#!/bin/bash

set -o pipefail

HOME_DIR=$(readlink -f "$(dirname "$0")/../..")
source "$HOME_DIR"/scripts/ae/ae-setup.sh || exit 1
trap finish_experiment EXIT

sift100m_setup
require_search_inputs bin || exit 1

INDEX_FILE=${BANG_INDEX_PREFIX}

echo "[REPORT] K 1"
run_case "$BANG_DIR"/build/bang_search "$INDEX_FILE" "$QUERY_BIN_FILE" "$GT_FILE" 10000 1 uint8 l2 12 20 30 40 50 60 70 80 90 100 120
echo "[REPORT] K 10"
run_case "$BANG_DIR"/build/bang_search "$INDEX_FILE" "$QUERY_BIN_FILE" "$GT_FILE" 10000 10 uint8 l2 20 30 40 50 60 70 80 90 110 130 145 160 180

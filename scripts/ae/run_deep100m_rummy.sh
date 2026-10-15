#!/bin/bash

set -o pipefail


HOME_DIR=$(readlink -f "$(dirname "$0")/../..")
source "$HOME_DIR"/scripts/ae/ae-setup.sh || exit 1
trap finish_experiment EXIT

function run() {
    local attempt status
    for ((attempt = 1; attempt <= 3; attempt++)); do
        if "$RUMMY_DIR/build/eval/overall_billion" deep 2048 "$1" "$2"; then
            return 0
        else
            status=$?
            echo "ERROR: Rummy K=$1 EF=$2 failed (attempt $attempt/3, exit $status)" >&2
        fi
    done
    EXPERIMENT_FAILED=1
}

# TOP-1
for ef in 2 3 4 5 6 8 10 12 14 16 18 20 22 24; do
    echo "[REPORT]" TOP 1 EF $ef
    run 1 $ef
done

# TOP-10
for ef in 2 4 6 8 10 12 14 16 18 20 22 24; do
    echo "[REPORT]" TOP 10 EF $ef
    run 10 $ef
done

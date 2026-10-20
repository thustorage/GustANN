#!/bin/bash

set -o pipefail
# shellcheck source=scripts/ae/setup/common.sh
source "$(dirname "$0")/common.sh" || exit 1
require_root "$@"
(( $# <= 3 )) || die "Usage: $0 [ssd-list-file] [state-file] [chunk-kib]"
read_ssd_list "${1:-$HOME_DIR/ssd_list.txt}"
RAID_STATE_FILE=${2:-$HOME_DIR/.cache/ae-raid.state}
RAID_CHUNK_KIB=${3:-$RAID_CHUNK_KIB}
validate_raid_chunk
[[ ! -e $RAID_STATE_FILE ]] || die "RAID state already exists; run cleanup_raid.sh $RAID_STATE_FILE first"

function cleanup_failed_setup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ $RAID_CLEANUP_READY == true ]]; then
        if (destroy_raid); then
            rm -f -- "$RAID_STATE_FILE" || status=1
        else
            echo "ERROR: Failed setup left RAID state in $RAID_STATE_FILE; run cleanup_raid.sh" >&2
            status=1
        fi
    fi
    exit "$status"
}

trap cleanup_failed_setup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
setup_aio
setup_raid
# A successful setup leaves the array available to independently run experiments.
trap - EXIT INT TERM
echo "RAID state: $RAID_STATE_FILE"

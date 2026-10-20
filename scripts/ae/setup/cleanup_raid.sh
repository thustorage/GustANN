#!/bin/bash

set -o pipefail
# shellcheck source=scripts/ae/setup/common.sh
source "$(dirname "$0")/common.sh" || exit 1
require_root "$@"
(( $# <= 1 )) || die "Usage: $0 [state-file]"
RAID_STATE_FILE=${1:-$HOME_DIR/.cache/ae-raid.state}
load_raid_state
# destroy_raid verifies the owner, UUID and members before unmount/stop/wipe.
destroy_raid || die "RAID cleanup failed; state retained in $RAID_STATE_FILE"
rm -f -- "$RAID_STATE_FILE" || die "Cannot remove RAID state: $RAID_STATE_FILE"

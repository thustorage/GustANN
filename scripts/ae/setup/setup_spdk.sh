#!/bin/bash

set -o pipefail
# shellcheck source=scripts/ae/setup/common.sh
source "$(dirname "$0")/common.sh" || exit 1
require_root "$@"
(( $# <= 1 )) || die "Usage: $0 [ssd-list-file]"
read_ssd_list "${1:-$HOME_DIR/ssd_list.txt}"
setup_spdk

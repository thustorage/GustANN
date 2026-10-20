#!/bin/bash

set -o pipefail
# shellcheck source=scripts/ae/setup/common.sh
source "$(dirname "$0")/common.sh" || exit 1
require_root "$@"
(( $# == 0 )) || die "Usage: $0"
setup_aio

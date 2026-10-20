#!/bin/bash

HOME_DIR=$(readlink -f "$(dirname "$0")/../..")

(( EUID == 0 )) || { echo "ERROR: Run the GustANN experiment script with sudo" >&2; exit 1; }
(( $# == 2 )) || { echo "Usage: $0 <index-file> <ssd-list>" >&2; exit 1; }
[[ -f $1 && -s $2 ]] || { echo "ERROR: Missing index or SSD list" >&2; exit 1; }
"$HOME_DIR/build/spdk/spdk_write" "$1" "$2"

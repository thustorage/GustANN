#!/bin/bash

# Please specify which GPU to use (for multi-GPU machines)
export CUDA_VISIBLE_DEVICES=3

SSD_LIST=${AE_SSD_LIST:-$HOME_DIR/ssd_list.txt}
STARLING_DIR=$HOME_DIR/baselines/starling
BANG_DIR=$HOME_DIR/baselines/BANG-Billion-Scale-ANN/BANG_Base
DISKANN_DIR=$HOME_DIR/deps/DiskANN
RUMMY_DIR=$HOME_DIR/baselines/Rummy
SPANN_DIR=$HOME_DIR/baselines/SPTAG

TMP_DIR=${AE_TMP_DIR:-$HOME_DIR/tmp}
SOURCE_ROOT=/mnt/raid/jhd
TARGET_ROOT=/mnt/gustann-ae-ssd
TEMP_INDEX_DIR=$SOURCE_ROOT/tmp
TEMP_INDEX_TARGET_DIR=$TARGET_ROOT/tmp
mkdir -p "$TMP_DIR" || return 1

# Each search is independent. Remember failures without aborting later cases.
EXPERIMENT_FAILED=0
function run_case() {
    local status
    if "$@"; then
        return 0
    else
        status=$?
        echo "ERROR: Experiment command failed (exit $status): $*" >&2
        EXPERIMENT_FAILED=1
    fi
}

function finish_experiment() {
    local status=${1:-$?}
    (( status != 0 || EXPERIMENT_FAILED == 0 )) || status=1
    trap - EXIT
    exit "$status"
}

function init_root_experiment() {
    (( EUID == 0 )) || { echo "ERROR: Run this experiment with sudo: sudo $0 $*" >&2; return 1; }
    while (( $# > 0 )); do
        case $1 in
            --tmp-dir|--ssd-list)
                (( $# >= 2 )) || { echo "ERROR: Missing value for $1" >&2; return 1; }
                if [[ $1 == --tmp-dir ]]; then TMP_DIR=$2; else SSD_LIST=$2; fi
                shift 2
                ;;
            --*)
                echo "ERROR: Unknown experiment option: $1" >&2; return 1
                ;;
            *)
                # Compatibility with run_ssd_gustann.sh [ssd-list-file].
                (( $# == 1 )) || { echo "ERROR: Unexpected experiment arguments: $*" >&2; return 1; }
                SSD_LIST=$1
                shift
                ;;
        esac
    done
    mkdir -p "$TMP_DIR" || return 1
    # Keep the shared log directory usable by subsequent unprivileged baselines.
    if [[ -n ${SUDO_UID:-} && -n ${SUDO_GID:-} ]]; then
        chown "$SUDO_UID:$SUDO_GID" "$TMP_DIR" || return 1
    fi
}

function gpu_run() {
    env CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES" \
        LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" "$@"
}

function require_files() {
    local file
    for file in "$@"; do
        if [[ ! -f $file ]]; then
            echo "ERROR: Required file not found: $file" >&2
            return 1
        fi
    done
}

function require_search_inputs() {
    local format=$1
    if [[ $format == raw ]]; then
        require_files "$QUERY_FILE" "$GT_FILE" "${INDEX_PREFIX}_disk.index" \
            "${INDEX_PREFIX}_pq_pivots.bin" "${INDEX_PREFIX}_pq_compressed.bin" \
            "$NAV_GRAPH/nav_index" "$NAV_GRAPH/nav_index.data" "$NAV_GRAPH/map.txt"
    else
        require_files "$QUERY_BIN_FILE" "$GT_FILE"
    fi
}

function prepare_target_dir() {
    if ! mountpoint -q "$TARGET_ROOT"; then
        echo "ERROR: SSD RAID is not mounted at $TARGET_ROOT" >&2
        return 1
    fi
    mkdir -p "$1" "$TMP_DIR"
}

function copy_index_to_target() (
    # PREFIX identifies a family of files, not a file or a directory itself.
    shopt -s nullglob
    local files=("${INDEX_PREFIX}"*)
    require_files "${INDEX_PREFIX}_disk.index" "${INDEX_PREFIX}_pq_pivots.bin" \
        "${INDEX_PREFIX}_pq_compressed.bin" || return 1
    if (( ${#files[@]} == 0 )); then
        echo "ERROR: No index files found for prefix $INDEX_PREFIX" >&2
        return 1
    fi
    prepare_target_dir "$TARGET_DIR" || return 1
    # Dereference links so index data lives on the evaluation SSDs. Preserve
    # timestamps and skip unchanged files already copied by another baseline.
    cp -auL -- "${files[@]}" "$TARGET_DIR/"
)

function sift100m_setup() {
    VECTOR_FILE=$SOURCE_ROOT/data/sift/100M.bbin
    QUERY_FILE=$SOURCE_ROOT/data/sift/bigann_query.bvecs
    QUERY_BIN_FILE=$SOURCE_ROOT/data/sift/bigann_query.bbin
    GT_FILE=$SOURCE_ROOT/data/sift/gnd/idx_100M.ivecs
    INDEX_DIR=$SOURCE_ROOT/index/sift100m
    INDEX_PREFIX=${INDEX_DIR}/index_R128_L200
    TARGET_DIR=$TARGET_ROOT/sift100m
    TARGET_PREFIX=${TARGET_DIR}/index_R128_L200
    NAV_GRAPH=${INDEX_DIR}/nav

    BANG_INDEX_PREFIX=${INDEX_DIR}/bang/index_R64_L100
    SPANN_INDEX_DIR=$SOURCE_ROOT/index/sift100m_spann
    SPANN_TARGET_DIR=$TARGET_ROOT/sift100m_spann
}

function deep100m_setup() {
    VECTOR_FILE=$SOURCE_ROOT/data/deep/100M.fbin
    QUERY_FILE=$SOURCE_ROOT/data/deep/deep1B_queries.fvecs
    QUERY_BIN_FILE=$SOURCE_ROOT/data/deep/queries.fbin
    GT_FILE=$SOURCE_ROOT/data/deep/deep100M_groundtruth.ivecs
    INDEX_DIR=$SOURCE_ROOT/index/deep100m
    INDEX_PREFIX=${INDEX_DIR}/index_R128_L200
    TARGET_DIR=$TARGET_ROOT/deep100m
    TARGET_PREFIX=${TARGET_DIR}/index_R128_L200
    NAV_GRAPH=${INDEX_DIR}/nav

    BANG_INDEX_PREFIX=${INDEX_DIR}/bang/index_R64_L100
    SPANN_INDEX_DIR=$SOURCE_ROOT/index/deep100m-spann
    SPANN_TARGET_DIR=$TARGET_ROOT/deep100m-spann
}

function sift1b_setup() {
    QUERY_FILE=$SOURCE_ROOT/data/sift/bigann_query.bvecs
    QUERY_BIN_FILE=$SOURCE_ROOT/data/sift/bigann_query.bbin
    QUERY_FILE_MOCK=$SOURCE_ROOT/data/sift/bigann_query_arg.bvecs
    QUERY_BIN_FILE_MOCK=$SOURCE_ROOT/data/sift/bigann_query_arg.bbin
    GT_FILE=$SOURCE_ROOT/data/sift/gnd/idx_1000M.ivecs
    INDEX_DIR=$SOURCE_ROOT/index/sift1b-ref-128
    INDEX_PREFIX=${INDEX_DIR}/index
    TARGET_DIR=$TARGET_ROOT/sift1b-ref-128
    TARGET_PREFIX=${TARGET_DIR}/index
    NAV_GRAPH=$SOURCE_ROOT/index/sift100m/nav
}

function deep1b_setup() {
    QUERY_FILE=$SOURCE_ROOT/data/deep/deep1B_queries.fvecs
    QUERY_BIN_FILE=$SOURCE_ROOT/data/deep/queries.fbin
    GT_FILE=$SOURCE_ROOT/data/deep/gt_1B.ivecs
    INDEX_DIR=$SOURCE_ROOT/index/deep1b-ref-128
    INDEX_PREFIX=${INDEX_DIR}/index
    TARGET_DIR=$TARGET_ROOT/deep1b-ref-128
    TARGET_PREFIX=${TARGET_DIR}/index
    NAV_GRAPH=${INDEX_DIR}/nav
}

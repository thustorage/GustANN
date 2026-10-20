#!/bin/bash

set -o pipefail
shopt -s nullglob

DATE=$(date +%Y%m%d-%H%M%S) || exit 1
LOG_PREFIX=${LOG_PREFIX:-test}-$DATE
RAID_CHUNK_KIB=${RAID_CHUNK_KIB:-1024}

HOME_DIR=$(readlink -f "$(dirname "$0")/../..")
LOG_DIR=$HOME_DIR/log/$LOG_PREFIX
mkdir -p "$LOG_DIR" || exit 1

echo "Log: $LOG_DIR"

AE_SCRIPT=$HOME_DIR/scripts/ae
# shellcheck source=scripts/ae/ae-setup.sh
source "$AE_SCRIPT/ae-setup.sh" || exit 1
AE_TMP_DIR=$LOG_DIR/tmp
TMP_DIR=$AE_TMP_DIR
export AE_TMP_DIR
FAILED_EXPERIMENTS=()
printf 'experiment\texit_status\n' > "$LOG_DIR/status.tsv" || exit 1

function run() {
    local dataset=$1 algorithm=$2
    shift 2
    run_logged "${dataset}_${algorithm}" "run_${dataset}_${algorithm}.sh" "$@"
}

function run_logged() {
    local label=$1 script=$2 status codes=()
    shift 2
    local command=("$AE_SCRIPT/$script")
    case $script in
        *_gustann.sh|*_bam.sh)
            command=(run_as_root "$AE_SCRIPT/$script" --tmp-dir "$TMP_DIR" --ssd-list "$SSD_LIST")
            ;;
    esac
    "${command[@]}" "$@" 2>&1 | tee "$LOG_DIR/log_${label}.log"
    codes=("${PIPESTATUS[@]}")
    (( codes[1] == 0 )) || die "Cannot write experiment log: $label"
    status=${codes[0]}
    printf '%s\t%s\n' "$label" "$status" >> "$LOG_DIR/status.tsv" || die "Cannot write status summary"
    if (( status != 0 )); then
        FAILED_EXPERIMENTS+=("$label")
        echo "ERROR: Experiment $label failed (exit $status); continuing" >&2
    fi
    return 0
}

# shellcheck source=scripts/ae/setup/common.sh
source "$AE_SCRIPT/setup/common.sh" || exit 1

function run_as_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        sudo "$@"
    fi
}

(( $# == 0 )) || die "Usage: $0 (runs all experiments)"

# Read once, then pass the same validated list to independent setup scripts.
read_ssd_list "$SSD_LIST"
validate_raid_chunk
mkdir -p "$TMP_DIR" || die "Cannot create temporary directory: $TMP_DIR"
AE_SSD_LIST=$TMP_DIR/ssd_list_all.txt
printf '%s\n' "${SSDS[@]}" > "$AE_SSD_LIST" || die "Cannot write active SSD list"
SSD_LIST=$AE_SSD_LIST
export AE_SSD_LIST
RAID_STATE_FILE=$TMP_DIR/raid.state

function setup_spdk() {
    run_as_root "$AE_SCRIPT/setup/setup_spdk.sh" "$SSD_LIST" || die "SPDK setup failed"
}

function setup_bam() {
    run_as_root "$AE_SCRIPT/setup/setup_bam.sh" "$SSD_LIST" || die "BaM setup failed"
}

function setup_raid() {
    run_as_root "$AE_SCRIPT/setup/setup_raid.sh" "$SSD_LIST" "$RAID_STATE_FILE" "$RAID_CHUNK_KIB" ||
        die "RAID setup failed"
}

function teardown_raid() {
    run_as_root "$AE_SCRIPT/setup/cleanup_raid.sh" "$RAID_STATE_FILE" || die "RAID cleanup failed"
}

function cleanup_on_exit() {
    local status=$?
    trap - EXIT INT TERM
    if [[ -f $RAID_STATE_FILE ]]; then
        if ! run_as_root "$AE_SCRIPT/setup/cleanup_raid.sh" "$RAID_STATE_FILE"; then
            echo "ERROR: RAID cleanup failed; state retained in $RAID_STATE_FILE" >&2
            (( status != 0 )) || status=1
        fi
    fi
    exit "$status"
}

function run_ssd_scaling() {
    local all_ssds=("${SSDS[@]}") count active_list

    echo "SSD scaling: SIFT100M, K=10, ef_search/L=30, SSDs=1..${#all_ssds[@]}"
    for ((count = 1; count <= ${#all_ssds[@]}; count++)); do
        SSDS=("${all_ssds[@]:0:count}")
        active_list=$TMP_DIR/ssd_list_${count}.txt
        printf '%s\n' "${SSDS[@]}" > "$active_list" || die "Cannot write active SSD list"
        SSD_LIST=$active_list
        setup_spdk
        run_logged "ssd_gustann_${count}" run_ssd_gustann.sh
    done

    for ((count = 1; count <= ${#all_ssds[@]}; count++)); do
        SSDS=("${all_ssds[@]:0:count}")
        active_list=$TMP_DIR/ssd_list_${count}.txt
        SSD_LIST=$active_list
        setup_raid
        run_logged "ssd_diskann_${count}" run_ssd_diskann.sh "$count"
        teardown_raid
    done
    SSDS=("${all_ssds[@]}")
    SSD_LIST=$AE_SSD_LIST
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_as_root "$AE_SCRIPT/setup/setup_aio.sh" || die "AIO setup failed"

echo Evaluation of GustANN
setup_spdk

run sift100m gustann
run deep100m gustann
run sift1b gustann
run deep1b gustann
run rep gustann

echo Evaluation of BaM-ANN
setup_bam

run sift100m bam

echo Evaluation of DiskANN
setup_raid
run sift100m diskann
run deep100m diskann
run sift1b diskann
run deep1b diskann
run rep diskann

echo Evaluation of Starling
run sift100m starling
run deep100m starling

echo Evaluation of SPANN
run sift100m spann
run deep100m spann

echo Evaluation of BANG
run sift100m bang
run deep100m bang

echo Evaluation of RUMMY
run deep100m rummy

teardown_raid
run_ssd_scaling

echo "Experiment statuses: $LOG_DIR/status.tsv"
if (( ${#FAILED_EXPERIMENTS[@]} > 0 )); then
    printf 'Failed experiments: %s\n' "${FAILED_EXPERIMENTS[*]}" >&2
    exit 1
fi
echo "All experiments completed successfully"

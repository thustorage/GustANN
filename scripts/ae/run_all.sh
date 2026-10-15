#!/bin/bash

set -o pipefail
shopt -s nullglob

DATE=$(date +%Y%m%d-%H%M%S) || exit 1
LOG_PREFIX=${LOG_PREFIX:-test}-$DATE
RAID_CHUNK_KIB=${RAID_CHUNK_KIB:-1024}
RAID_MOUNT_DIR=/mnt/gustann-ae-ssd
RAID_CLEANUP_READY=false
RAID_UUID=

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
    bash "$AE_SCRIPT/$script" "$@" 2>&1 | tee "$LOG_DIR/log_${label}.log"
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

function die() {
    echo "ERROR: $*" >&2
    exit 1
}

(( $# == 0 )) || die "Usage: $0 (runs all experiments)"

# Read once so all configurations use the same validated PCI devices.
[[ -r $SSD_LIST ]] || die "Cannot read SSD list: $SSD_LIST"
SSDS=()
while read -r pci extra || [[ -n $pci ]]; do
    [[ -z $pci || $pci == \#* ]] && continue
    [[ $pci =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ && -z $extra ]] ||
        die "Invalid PCI address in $SSD_LIST: $pci $extra"
    pci=${pci,,}
    [[ -d /sys/bus/pci/devices/$pci ]] || die "PCI device not found: $pci"
    [[ $(cat "/sys/bus/pci/devices/$pci/class") == 0x010802 ]] ||
        die "Not an NVMe controller: $pci"
    [[ " ${SSDS[*]} " != *" $pci "* ]] || die "Duplicate SSD: $pci"
    SSDS+=("$pci")
done < "$SSD_LIST"
(( ${#SSDS[@]} >= 1 )) || die "No SSDs found in $SSD_LIST"
[[ $RAID_CHUNK_KIB =~ ^[1-9][0-9]*$ ]] || die "Invalid RAID_CHUNK_KIB: $RAID_CHUNK_KIB"
(( RAID_CHUNK_KIB >= 4 && (RAID_CHUNK_KIB & (RAID_CHUNK_KIB - 1)) == 0 )) ||
    die "RAID_CHUNK_KIB must be a power of two and at least 4 KiB"

mkdir -p "$TMP_DIR" || die "Cannot create temporary directory: $TMP_DIR"
AE_SSD_LIST=$TMP_DIR/ssd_list_all.txt
printf '%s\n' "${SSDS[@]}" > "$AE_SSD_LIST" || die "Cannot write active SSD list"
SSD_LIST=$AE_SSD_LIST
export AE_SSD_LIST

# Resolve visible namespaces by PCI address, including NVMe multipath systems.
function ssd_namespaces() {
    local pci=$1 ctrl block nqn
    for ctrl in /sys/class/nvme/nvme*; do
        [[ -f $ctrl/address && $(cat "$ctrl/address") == "$pci" ]] || continue
        nqn=$(cat "$ctrl/subsysnqn") || return 1
        for block in /sys/block/nvme*; do
            [[ -f $block/hidden && $(cat "$block/hidden") == 1 ]] && continue
            [[ -f $block/device/subsysnqn ]] || continue
            if [[ $(cat "$block/device/subsysnqn") == "$nqn" ]]; then
                printf '/dev/%s\n' "${block##*/}"
            fi
        done
    done
}

function unknown_state() {
    echo 'Unknown states , please contact the authors!' >&2
    exit 1
}

function check_raid_owner() {
    local metadata=$1 name
    name=$(md_value MD_NAME <<< "$metadata")
    name=${name##*:}
    [[ $name =~ ^gustann-ae(-[1-9][0-9]*)?$ ]] || unknown_state
}

function check_ssd_state() {
    local dev=$1 nodes node fstype detected metadata
    # Include partitions and assembled arrays, even when they are not mounted.
    # Probe signatures directly rather than relying only on cached lsblk data.
    nodes=$(sudo lsblk -nrpo NAME,FSTYPE "$dev") || unknown_state
    while read -r node fstype; do
        [[ -n $node ]] || continue
        [[ $fstype != ext4 ]] || unknown_state
        if detected=$(sudo blkid -p -s TYPE -o value "$node" 2>/dev/null); then
            fstype=$detected
            [[ $fstype != ext4 ]] || unknown_state
        else
            # blkid returns 2 when there is no recognizable signature.
            [[ $? == 2 ]] || unknown_state
        fi
        if metadata=$(sudo mdadm --examine --export "$node" 2>/dev/null); then
            check_raid_owner "$metadata"
        elif [[ $fstype == linux_raid_member ]]; then
            unknown_state
        fi
        if [[ -d /sys/class/block/${node##*/}/md ]]; then
            metadata=$(sudo mdadm --detail --export "$node") || unknown_state
            check_raid_owner "$metadata"
        fi
    done <<< "$nodes"
}

function unbind_ssds() {
    local pci dev holder namespaces mounts
    # Check the whole list before unbinding anything. Never detach live arrays
    # or mounted filesystems (including those on partitions).
    for pci in "${SSDS[@]}"; do
        namespaces=$(ssd_namespaces "$pci") || die "Cannot discover namespaces for $pci"
        while read -r dev; do
            [[ -n $dev ]] || continue
            check_ssd_state "$dev"
            mounts=$(lsblk -nr -o MOUNTPOINTS "$dev") || die "Cannot inspect $dev"
            [[ -z $mounts ]] ||
                die "$dev is mounted; unmount it before switching SSD drivers"
            for holder in /sys/class/block/"${dev##*/}"*/holders/*; do
                die "$dev is in use by ${holder##*/}; release it before switching SSD drivers"
            done
        done <<< "$namespaces"
    done
    for pci in "${SSDS[@]}"; do
        echo "Unbind $pci"
        if [[ -e /sys/bus/pci/devices/$pci/driver/unbind ]]; then
            printf '%s\n' "$pci" | sudo tee "/sys/bus/pci/devices/$pci/driver/unbind" >/dev/null || die "Cannot unbind $pci"
        fi
        printf '\n' | sudo tee "/sys/bus/pci/devices/$pci/driver_override" >/dev/null || die "Cannot clear driver override for $pci"
    done
}

function bind_ssd() {
    local pci=$1 driver=$2
    printf '%s\n' "$driver" | sudo tee "/sys/bus/pci/devices/$pci/driver_override" >/dev/null || die "Cannot set driver override for $pci"
    printf '%s\n' "$pci" | sudo tee /sys/bus/pci/drivers_probe >/dev/null || die "Cannot probe $driver for $pci"
    printf '\n' | sudo tee "/sys/bus/pci/devices/$pci/driver_override" >/dev/null || die "Cannot clear driver override for $pci"
    [[ $(readlink -f "/sys/bus/pci/devices/$pci/driver") == "/sys/bus/pci/drivers/$driver" ]] ||
        die "Failed to bind $pci to $driver"
}

function setup_aio() {
    local minimum=1048576 current
    current=$(sysctl -n fs.aio-max-nr) || die "Cannot read fs.aio-max-nr"
    [[ $current =~ ^[0-9]+$ ]] || die "Invalid fs.aio-max-nr: $current"
    if (( current < minimum )); then
        sudo sysctl -w "fs.aio-max-nr=$minimum" || die "Cannot raise fs.aio-max-nr"
        current=$(sysctl -n fs.aio-max-nr) || die "Cannot verify fs.aio-max-nr"
        [[ $current =~ ^[0-9]+$ ]] || die "Invalid fs.aio-max-nr: $current"
        (( current >= minimum )) || die "fs.aio-max-nr is below $minimum after setup"
    fi
}

function setup_spdk() {
    local pci driver
    unbind_ssds
    sudo env PCI_ALLOWED="${SSDS[*]}" "$HOME_DIR/deps/spdk/scripts/setup.sh" || die "SPDK setup failed"
    for pci in "${SSDS[@]}"; do
        driver=$(basename "$(readlink -f "/sys/bus/pci/devices/$pci/driver")")
        [[ $driver == vfio-pci || $driver == uio_pci_generic || $driver == igb_uio ]] ||
            die "SPDK did not bind $pci to a userspace driver"
    done
}

function setup_bam() {
    local pci device driver
    local module_dir=$HOME_DIR/deps/bam/build/module
    [[ -f $module_dir/Makefile && -f $module_dir/libnvm.ko ]] ||
        die "BaM module is not built in $module_dir"
    # make load probes every unbound NVMe controller. Refuse to capture any
    # outside our list, or to share libnvm device numbering with another user.
    for device in /sys/bus/pci/devices/*; do
        [[ $(cat "$device/class") == 0x010802 ]] || continue
        pci=${device##*/}
        [[ " ${SSDS[*]} " != *" $pci "* ]] || continue
        driver=$(readlink -f "$device/driver")
        [[ -e $device/driver && $driver != "/sys/bus/pci/drivers/libnvm helper" ]] ||
            die "NVMe controller outside $SSD_LIST is unbound or using BaM: $pci"
    done
    unbind_ssds
    if [[ -d /sys/module/libnvm ]]; then
        sudo rmmod libnvm || die "Cannot reset BaM controller numbering"
    fi
    (cd "$module_dir" && sudo make load) || die "BaM module setup failed"
    for pci in "${SSDS[@]}"; do
        bind_ssd "$pci" "libnvm helper"
    done
    sudo udevadm settle --timeout=10 || die "BaM device nodes did not settle"
}

function md_value() {
    local key=$1
    awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2) }'
}

function check_raid() {
    local md=$1 members=() slave
    [[ $(cat "$md/md/level") == raid0 &&
       $(cat "$md/md/raid_disks") == "${#RAID_SSDS[@]}" &&
       $(cat "$md/md/chunk_size") == "$((RAID_CHUNK_KIB * 1024))" ]] ||
        die "RAID parameters do not match: ${md##*/}"
    for slave in "$md"/slaves/*; do
        members+=("/dev/${slave##*/}")
    done
    [[ $(printf '%s\n' "${members[@]}" | sort) == $(printf '%s\n' "${RAID_SSDS[@]}" | sort) ]] ||
        die "RAID members do not match $SSD_LIST: ${md##*/}"
}

function mount_raid() {
    local created=$1 source fstype entries mounts mounted=false
    # Reject an occupied mountpoint before formatting or hiding its contents.
    if source=$(findmnt -rn --mountpoint "$RAID_MOUNT_DIR" -o SOURCE); then
        [[ $(readlink -f "$source") == $(readlink -f "$RAID_DEV") ]] || unknown_state
        mounted=true
    else
        [[ $? == 1 ]] || unknown_state
        if [[ -d $RAID_MOUNT_DIR ]]; then
            entries=$(sudo find "$RAID_MOUNT_DIR" -mindepth 1 -maxdepth 1 -print -quit) || unknown_state
            [[ -z $entries ]] || unknown_state
        elif [[ -e $RAID_MOUNT_DIR ]]; then
            unknown_state
        fi
    fi

    if [[ $created == true ]]; then
        mounts=$(lsblk -dnro MOUNTPOINTS "$RAID_DEV") || unknown_state
        [[ -z $mounts ]] || unknown_state
        # The md device can retain the previous array's ext4 signature.  The
        # array was validated and is unmounted here, so force mkfs to stay
        # non-interactive instead of asking "Proceed anyway?".
        sudo mkfs.ext4 -F "$RAID_DEV" || die "Cannot format $RAID_DEV"
    elif fstype=$(sudo blkid -p -s TYPE -o value "$RAID_DEV" 2>/dev/null); then
        [[ $fstype == ext4 ]] || unknown_state
    else
        [[ $? == 2 && $mounted == false ]] || unknown_state
        # Resume an array that was created but has no filesystem yet.
        mounts=$(lsblk -dnro MOUNTPOINTS "$RAID_DEV") || unknown_state
        [[ -z $mounts ]] || unknown_state
        sudo mkfs.ext4 -F "$RAID_DEV" || die "Cannot format $RAID_DEV"
    fi

    sudo mkdir -p "$RAID_MOUNT_DIR" || die "Cannot create RAID mount directory"
    if [[ $mounted == false ]]; then
        sudo mount -t ext4 "$RAID_DEV" "$RAID_MOUNT_DIR" || die "Cannot mount $RAID_DEV"
    fi
    sudo chmod 777 "$RAID_MOUNT_DIR" || die "Cannot set RAID mount permissions"
    export RAID_MOUNT_DIR
    echo "RAID mounted: $RAID_DEV -> $RAID_MOUNT_DIR (ext4)"
}

function arm_raid_cleanup() {
    local metadata
    metadata=$(sudo mdadm --detail --export "$RAID_DEV") || unknown_state
    check_raid_owner "$metadata"
    RAID_UUID=$(md_value MD_UUID <<< "$metadata")
    [[ -n $RAID_UUID ]] || unknown_state
    RAID_CLEANUP_READY=true
}

function destroy_raid() {
    local metadata source dev mounts
    # Recheck identity and members before stopping or erasing any array.
    metadata=$(sudo mdadm --detail --export "$RAID_DEV") || unknown_state
    check_raid_owner "$metadata"
    [[ $(md_value MD_UUID <<< "$metadata") == "$RAID_UUID" ]] || unknown_state
    check_raid "/sys/block/$(basename "$(readlink -f "$RAID_DEV")")"
    for dev in "${RAID_SSDS[@]}"; do
        metadata=$(sudo mdadm --examine --export "$dev") || unknown_state
        check_raid_owner "$metadata"
        [[ $(md_value MD_UUID <<< "$metadata") == "$RAID_UUID" ]] || unknown_state
    done

    if source=$(findmnt -rn --mountpoint "$RAID_MOUNT_DIR" -o SOURCE); then
        [[ $(readlink -f "$source") == $(readlink -f "$RAID_DEV") ]] || unknown_state
        sudo umount "$RAID_MOUNT_DIR" || return 1
    else
        [[ $? == 1 ]] || unknown_state
    fi
    mounts=$(lsblk -dnro MOUNTPOINTS "$RAID_DEV") || return 1
    [[ -z $mounts ]] || unknown_state
    sudo mdadm --stop "$RAID_DEV" || return 1
    sudo mdadm --zero-superblock "${RAID_SSDS[@]}" || return 1
    echo "RAID destroyed: $RAID_DEV (member RAID metadata removed)"
}

function cleanup_on_exit() {
    local status=$?
    trap - EXIT INT TERM
    if [[ $RAID_CLEANUP_READY == true ]]; then
        # A failed unmount/stop must never be followed by a metadata wipe.
        # The subshell lets validation exit without losing the original status.
        if (destroy_raid); then
            RAID_CLEANUP_READY=false
        else
            echo "ERROR: RAID cleanup failed: $RAID_DEV" >&2
            (( status != 0 )) || status=1
        fi
    fi
    exit "$status"
}

function setup_raid() {
    local pci attempt namespaces=() found dev holder md metadata uuid="" device_uuid
    local metadata_count=0 name suffix=0 used_names="" details created=false create_options=()
    command -v mdadm >/dev/null || die "mdadm is required"
    unbind_ssds
    sudo modprobe nvme || die "Cannot load NVMe driver"
    for pci in "${SSDS[@]}"; do
        bind_ssd "$pci" nvme
    done

    RAID_SSDS=()
    for pci in "${SSDS[@]}"; do
        # drivers_probe returns before namespace discovery necessarily finishes.
        for ((attempt = 0; attempt < 100; attempt++)); do
            sudo udevadm settle --timeout=10 || die "udev did not settle"
            found=$(ssd_namespaces "$pci") || die "Cannot discover namespaces for $pci"
            namespaces=()
            [[ -z $found ]] || mapfile -t namespaces <<< "$found"
            (( ${#namespaces[@]} > 0 )) && break
            sleep 0.1
        done
        (( ${#namespaces[@]} == 1 )) || die "Expected one namespace on $pci; found ${#namespaces[@]}"
        dev=${namespaces[0]}
        [[ -b $dev ]] || die "Block device not found: $dev"
        [[ " ${RAID_SSDS[*]} " != *" $dev "* ]] || die "Shared namespace: $dev"
        check_ssd_state "$dev"
        RAID_SSDS+=("$dev")
        echo "RAID member: $pci -> $dev"
    done

    # udev may already have assembled an existing array. Only reuse an exact
    # match; never stop, recreate, or add members to an unrelated array.
    for dev in "${RAID_SSDS[@]}"; do
        for holder in /sys/class/block/"${dev##*/}"/holders/*; do
            md=/sys/block/${holder##*/}
            [[ -d $md/md ]] || die "$dev is in use by ${holder##*/}"
            check_raid "$md"
            export RAID_DEV=/dev/${md##*/}
            arm_raid_cleanup
            echo "Reuse RAID: $RAID_DEV"
            mount_raid false
            return
        done
    done

    for dev in "${RAID_SSDS[@]}"; do
        [[ -z $(lsblk -nr -o MOUNTPOINTS "$dev") ]] || die "$dev is mounted"
        [[ $(lsblk -nr -o TYPE "$dev") == disk ]] || die "$dev has partitions or dependent devices"
        if metadata=$(sudo mdadm --examine --export "$dev" 2>/dev/null); then
            check_raid_owner "$metadata"
            device_uuid=$(md_value MD_UUID <<< "$metadata")
            [[ -n $device_uuid && $(md_value MD_LEVEL <<< "$metadata") == raid0 &&
               $(md_value MD_DEVICES <<< "$metadata") == "${#RAID_SSDS[@]}" ]] ||
                die "Existing RAID metadata does not match on $dev"
            [[ -z $uuid || $uuid == "$device_uuid" ]] || die "SSDs contain different RAID arrays"
            uuid=$device_uuid
            metadata_count=$((metadata_count + 1))
        fi
    done
    (( metadata_count == 0 || metadata_count == ${#RAID_SSDS[@]} )) ||
        die "Only some SSDs contain RAID metadata; refusing to overwrite it"

    # Check both device aliases and superblock names, since /dev/md/<name>
    # may be absent even when the name is already used by an active array.
    for md in /sys/block/md*; do
        [[ -d $md/md ]] || continue
        details=$(sudo mdadm --detail --export "/dev/${md##*/}") || die "Cannot inspect ${md##*/}"
        name=$(md_value MD_NAME <<< "$details")
        used_names+=" ${name##*:} "
    done
    name=gustann-ae
    while [[ -e /dev/md/$name || -L /dev/md/$name || $used_names == *" $name "* ]]; do
        suffix=$((suffix + 1))
        name=gustann-ae-$suffix
    done
    RAID_DEV=/dev/md/$name
    if [[ -n $uuid ]]; then
        sudo mdadm --assemble "$RAID_DEV" --uuid="$uuid" "${RAID_SSDS[@]}" || die "RAID assembly failed"
    else
        # mdadm requires --force to create the single-device RAID0 baseline.
        if (( ${#RAID_SSDS[@]} == 1 )); then
            create_options+=(--force)
        fi
        sudo mdadm --create "$RAID_DEV" --name="$name" --metadata=1.2 \
            --level=0 --chunk="$RAID_CHUNK_KIB" --raid-devices="${#RAID_SSDS[@]}" \
            "${create_options[@]}" "${RAID_SSDS[@]}" || die "RAID creation failed"
        created=true
    fi
    export RAID_DEV
    arm_raid_cleanup
    sudo udevadm settle --timeout=10 || die "udev did not settle"
    check_raid "/sys/block/$(basename "$(readlink -f "$RAID_DEV")")"
    mount_raid "$created"
}

function run_ssd_scaling() {
    local all_ssds=("${SSDS[@]}") count active_list

    echo "SSD scaling: SIFT100M, K=10, ef_search/L=30, SSDs=1..${#all_ssds[@]}"
    for ((count = 1; count <= ${#all_ssds[@]}; count++)); do
        SSDS=("${all_ssds[@]:0:count}")
        active_list=$TMP_DIR/ssd_list_${count}.txt
        printf '%s\n' "${SSDS[@]}" > "$active_list" || die "Cannot write active SSD list"
        setup_spdk
        run_logged "ssd_gustann_${count}" run_ssd_gustann.sh "$active_list"
    done

    for ((count = 1; count <= ${#all_ssds[@]}; count++)); do
        SSDS=("${all_ssds[@]:0:count}")
        setup_raid
        run_logged "ssd_diskann_${count}" run_ssd_diskann.sh "$count"
        teardown_raid
    done
    SSDS=("${all_ssds[@]}")
}

function teardown_raid() {
    destroy_raid || die "RAID cleanup failed"
    RAID_CLEANUP_READY=false
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sudo -v || die "sudo authorization failed"
setup_aio

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

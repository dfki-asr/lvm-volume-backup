#!/usr/bin/env bash

set -eo pipefail

export LC_ALL=C
unset CDPATH

THIS_DIR=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

error() {
    echo >&2 "Error: $*"
}

fatal() {
    error "$@"
    echo >&2 "Exiting ..."
    exit 1
}

message() {
    echo >&2 "$*"
}

dbg() {
    echo >&2 "Debug: $*"
}

log() {
    logger -t lvm_backup "$*"
    echo >&2 "* $*"
}

enable_file_logging() {
    if [[ -z "$LOG_FILE" ]]; then
        fatal "The LOG_FILE variable must not be empty."
    fi

    exec > >(tee -ia "$LOG_FILE")
    exec 2> >(tee -ia "$LOG_FILE" >&2)

    ## Close STDOUT file descriptor
    #exec 1<&-
    ## Close STDERR FD
    #exec 2<&-

    ## Open STDOUT as $LOG_FILE file for read and write.
    #exec 1>>"$LOG_FILE" 2>&1

    echo
    echo "$(date): ${BASH_SOURCE[0]}: start logging"

    on_error() {
        local errmsg err_lineno err_command err_code
        err_lineno="${1}"
        err_command="${2}"
        err_code="${3:-0}"

        ## Workaround for read EOF combo tripping traps
        if ! ((err_code)); then
            return "${err_code}"
        fi

        errmsg=$(awk 'NR>L-4 && NR<L+4 { printf "%-5d%3s%s\n",NR,(NR==L?">>>":""),$0 }' L="$err_lineno" "$0")
        log "Error occurred in '$err_command' command
$errmsg"
        if ((BASH_SUBSHELL != 0)); then
            # Exit from subshell
            exit "${err_code}"
        else
            # Exit from top level script
            exit "${err_code}"
        fi
    }

    trap 'on_error ${LINENO} "${BASH_COMMAND}" "${?}"' ERR

    on_exit() {
        cleanup
        log "${BASH_SOURCE[0]}: exiting"
        # Close STDOUT file descriptor
        exec 1<&-
        # Close STDERR FD
        exec 2<&-
    }

    trap 'on_exit' EXIT
}
### END LOGGING

rtrim() {
    echo -n "${1%"${1##*[![:space:]]}"}"
}

trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"   # remove leading whitespace characters
    var="${var%"${var##*[![:space:]]}"}"   # remove trailing whitespace characters
    echo -n "$var"
}

lvm2_attr_info() {
    local lv_attr=$1 attr
    attr="${lv_attr:0:1}"
    # type bit
    echo -n "Volume type: "
    case "${attr}" in
        C) echo "cache";;
        m) echo "mirrored";;
        M) echo "mirrored without initial sync";;
        o) echo "origin";;
        O) echo "origin with merging snapshot";;
        r) echo "raid";;
        R) echo "raid without initial sync";;
        s) echo "snapshot";;
        S) echo "merging snapshot";;
        p) echo "pvmove";;
        v) echo "virtual";;
        i) echo "mirror or raid image";;
        I) echo "mirror or raid image out-of-sync";;
        l) echo "mirror log device";;
        c) echo "volume under conversion";;
        V) echo "thin";;
        t) echo "thin pool";;
        T) echo "thin pool data";;
        d) echo "vdo pool";;
        D) echo "vdo pool data";;
        e) echo "raid or pool m(e)tadata or pool metadata spare";;
        -) echo "normal";;
        *) echo "Unknown 1st attribute: $attr";;
    esac
    # perm bit
    attr="${lv_attr:1:1}"
    echo -n "Permissions: "
    case "$attr" in
        w) echo "writeable";;
        r) echo "read-only";;
        R) echo "read-only activation of non-read-only volume";;
        *) echo "Unknown 2nd attribute: $attr";;
    esac
    # alloc bit
    attr="${lv_attr:2:1}"
    echo -n "Allocation policy: "
    case "$attr" in
        a) echo "anywhere";;
        A) echo "anywhere, locked";;
        c) echo "contiguous";;
        C) echo "contiguous, locked";;
        i) echo "inherited";;
        I) echo "inherited, locked";;
        l) echo "cling";;
        L) echo "cling, locked";;
        n) echo "normal";;
        N) echo "normal, locked";;
        -) ;;
        *) echo "Unknown 3rd attribute: $attr";;
    esac
    # fixed bit
    attr="${lv_attr:3:1}"
    case "$attr" in
        m) echo "Fixed minor";;
        -) ;;
        *) echo "Unknown 4th attribute: $attr";;
    esac
    # state bit
    attr="${lv_attr:4:1}";
    echo -n "State: "
    case "$attr" in
        a) echo "active";;
        h) echo "historical";;
        s) echo "suspended";;
        I) echo "invalid snapshot";;
        S) echo "invalid suspended snapshot";;
        m) echo "snapshot merge failed";;
        M) echo "suspended snapshot merge  failed";;
        d) echo "mapped device present without tables";;
        i) echo "mapped device present with inactive table";;
        c) echo "thin-pool check needed";;
        C) echo "suspended thin-pool check needed";;
        X) echo "unknown";;
        *) echo "Unknown 5th attribute: $attr";;
    esac
    # open bit
    attr="${lv_attr:5:1}"
    echo -n "Device: ";
    case "$attr" in
        o) echo "open";;
        X) echo "unknown";;
        -) echo "-";;
        *) echo "Unknown 6th attribute: $attr";;
    esac
    # target bit
    attr="${lv_attr:6:1}"
    echo -n "Target type: ";
    case "$attr" in
        C) echo "cache";;
        m) echo "mirror";;
        r) echo "raid";;
        s) echo "snapshot";;
        t) echo "thin";;
        u) echo "unknown";;
        v) echo "virtual";;
        -) echo "normal";;
        *) echo "Unknown 7th attribute: $attr";;
    esac
    # zero bit
    attr="${lv_attr:7:1}"
    case "$attr" in
        z) echo "Newly-allocated data blocks are overwritten with blocks of zeroes before use";;
        -) ;;
        *) echo "Unknown 8th attribute: $attr";;
    esac
    # health bit
    attr="${lv_attr:8:1}"
    echo -n "Volume health: ";
    case "$attr" in
        p) echo "partial";;
        X) echo "unknown";;
        r) echo "refresh needed";;
        m) echo "mismatches exist";;
        w) echo "writemostly";;
        R) echo "remove after reshape";;
        F) echo "failed";;
        D) echo "out of data space";;
        M) echo "metadata read-only";;
        E) echo "dm-writecache reports an error";;
        -) echo "ok";;
        *) echo "Unknown 9th attribute: $attr";;
    esac
    # skip bit
    attr="${lv_attr:9:1}"
    case "$attr" in
        k) echo "skip activation";;
        -) ;;
        *) echo "Unknown 10th attribute: $attr";;
    esac
}

lvm2_attr_is_active() {
    local lv_attr=$1
    case "${lv_attr:4:1}" in
        a) return 0;;
        *) return 1;;
    esac
}

lvm2_attr_is_cow() {
    local lv_attr=$1
    case "${lv_attr:0:1}" in
        s|S) return 0;;
        *) return 1;;
    esac
}

lvm2_attr_is_locked() {
    local lv_attr=$1
    case "${lv_attr:2:1}" in
        -|[a-z]) return 1;;
        *) return 0;;
    esac
}

lvm2_attr_is_pvmove() {
    local lv_attr=$1
    case "${lv_attr:0:1}" in
        p) return 0;;
        *) return 1;;
    esac
}

lvm2_attr_is_cache_type_or_writecache() {
    local lv_attr=$1
    case "${lv_attr:0:1}" in
        C) return 0;;
        *) return 1;;
    esac
}

lvm2_attr_is_any_cache() {
    local lv_attr=$1
    case "${lv_attr:6:1}" in
        C) return 0;;
        *) return 1;;
    esac
}

lvm2_attr_is_mirror_type_or_pvmove() {
    local lv_attr=$1
    case "${lv_attr:6:1}" in
        m) return 0;;
        *) return 1;;
    esac
}

lvm2_attr_is_mirror() {
    local lv_attr=$1
    case "${lv_attr:0:1}" in
        [Mm]) return 0;;
        *) return 1;;
    esac
}

lvm2_attr_is_merging_origin() {
    local lv_attr=$1
    case "${lv_attr:0:1}" in
        O) return 0;;
        *) return 1;;
    esac
}

lvm2_attr_is_thin_volume() {
    local lv_attr=$1
    case "${lv_attr:0:1}" in
        [OSV]) return 0;;
        *) return 1;;
    esac
}


lvm2_attr_is_thin_type() {
    # Does not report thin pool metadata !
    local lv_attr=$1
    case "${lv_attr:0:1}" in
        [tTOSV]) return 0;;
        *) return 1;;
    esac
}

lvm2_attr_is_metadata() {
    local lv_attr=$1
    case "${lv_attr:0:1}" in
        e) return 0;;
        *) return 1;;
    esac
}


lvm2_attr_is_raid_type() {
    local lv_attr=$1
    case "${lv_attr:6:1}" in
        r) return 0;;
        *) return 1;;
    esac
}

lvm2_attr_is_raid() {
    local lv_attr=$1
    case "${lv_attr:0:1}" in
        [Rr]) return 0;;
        *) return 1;;
    esac
}

lvm2_lv_path() {
    local result
    result=$(/sbin/lvs --noheadings --separator='|' --o lv_path --select "lv_name = \"$1\" && vg_name = \"$2\"")
    trim "$result"
}

DEFAULT_LV_SNAPSHOT_SUFFIX="_xsnap"
LV_SNAPSHOT_SUFFIX="$DEFAULT_LV_SNAPSHOT_SUFFIX"

lvm2_for_each_logical_volume() {
    local proc_func=$1 LVS_OUTPUT LINE_NUM LVS_LINE IFS
    local LVM2_LV_NAME LVM2_VG_NAME LVM2_LV_PATH LVM2_LV_SIZE LVM2_LV_ATTR LVM2_SEGTYPE LVM2_ORIGIN
    if [[ -z "$proc_func" ]]; then
        error "Callback function name is required"
        return 1
    fi
    LVS_OUTPUT=$(/sbin/lvs  --noheadings --separator='|' --units b --o lv_name,vg_name,lv_path,lv_size,lv_attr,origin,segtype)
    LINE_NUM=0

    while IFS='' read -r LVS_LINE; do
        : $((LINE_NUM++))
        #echo "Accessing line $LINE_NUM: ${LVS_LINE}";

        LVS_LINE=$(trim "$LVS_LINE")
        IFS='|' read -r LVM2_LV_NAME LVM2_VG_NAME LVM2_LV_PATH LVM2_LV_SIZE LVM2_LV_ATTR LVM2_ORIGIN LVM2_SEGTYPE <<<"$LVS_LINE"
        "$proc_func" "$LVM2_LV_NAME" "$LVM2_VG_NAME" "$LVM2_LV_PATH" "$LVM2_LV_SIZE" "$LVM2_LV_ATTR" "$LVM2_ORIGIN" "$LVM2_SEGTYPE"
    done <<< "$LVS_OUTPUT"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        fatal "You must run this command as root"
    fi
}

list_volumes() {
    lvm2_for_each_logical_volume print_lvm_volume_info
}

print_lvm_volume_info() {
    echo "Logical volume: '$LVM2_LV_NAME', volume group: '$LVM2_VG_NAME'"
    lvm2_attr_info "$LVM2_LV_ATTR"
    echo
}


MOUNT_DIR=
MOUNT_DIR_MOUNTED=
KPARTX_PARTS_ADDED=

volume_cleanup() {
    log "Volume cleanup"
    if [[ -n "$MOUNT_DIR" && "$MOUNT_DIR_MOUNTED" = "true" ]]; then
        log "Unmounting $MOUNT_DIR"
        umount "$MOUNT_DIR" || true;
        rmdir "$MOUNT_DIR" || true;
        MOUNT_DIR_MOUNTED=false
        MOUNT_DIR=
    fi
    if [[ "$KPARTX_PARTS_ADDED" = "true" ]]; then
        log "Remove kpartx volumes"
        kpartx -vd "$VOLUME_PATH" || true;
        KPARTX_PARTS_ADDED=false
    fi
}

CREATED_SNAPSHOT_PATHS=()
CREATED_SNAPSHOT_VG_NAMES=()
CREATED_SNAPSHOT_ORIG_LV_NAMES=()

cleanup() {
    local snapshot_path
    log "Cleanup"
    volume_cleanup
    log "Remove created snapshots"
    for snapshot_path in "${CREATED_SNAPSHOT_PATHS[@]}"; do
        log "Remove snapshot $snapshot_path"
        (set -xe;
            if ! lvremove -y "$snapshot_path"; then
                # Try to remove kpartx mapping
                kpartx -vd "$snapshot_path" || true;
                lvremove -y "$snapshot_path" || true;
            fi
        )
    done
    CREATED_SNAPSHOT_PATHS=()
    CREATED_SNAPSHOT_VG_NAMES=()
    CREATED_SNAPSHOT_ORIG_LV_NAMES=()
    log "End backup of LVM volumes"
}

cleanup_old_snapshots() {
    # Cleanup of old snapshots
    if lvm2_attr_is_cow "$LVM2_LV_ATTR" || [[ -n "$LVM2_ORIGIN" ]]; then
        message "* Check snapshot $LVM2_LV_NAME / $LVM2_VG_NAME"
        if [[ "$LVM2_LV_NAME" == *"$LV_SNAPSHOT_SUFFIX" ]]; then
            log "Remove old snapshot $LVM2_LV_PATH"
            (set -xe;
                if ! lvremove -y "$LVM2_LV_PATH"; then
                    # Try to remove kpartx mapping
                    kpartx -vd "$LVM2_LV_PATH" || true;
                    lvremove -y "$LVM2_LV_PATH";
                fi
            )
        fi
    fi
}

create_new_snapshots() {
    local CREATE_SNAPSHOT=true ERR ivol

    for ivol in "${IGNORE_VOLUMES[@]}"; do
        if [[ "$ivol" = "$LVM2_VG_NAME/$LVM2_LV_NAME" ]]; then
            log "Ignore volume $ivol"
            return 0
        fi
    done

    if lvm2_attr_is_cow "$LVM2_LV_ATTR"; then
        CREATE_SNAPSHOT=false
        ERR=snapshots
    elif lvm2_attr_is_locked "$LVM2_LV_ATTR"; then
        CREATE_SNAPSHOT=false
        ERR="locked volumes"
    elif lvm2_attr_is_pvmove "$LVM2_LV_ATTR"; then
        CREATE_SNAPSHOT=false
        ERR="pvmoved volumes"
    elif lvm2_attr_is_merging_origin "$LVM2_LV_ATTR"; then
        CREATE_SNAPSHOT=false
        ERR="an origin that has a merging snapshot"
    elif lvm2_attr_is_any_cache "$LVM2_LV_ATTR"; then
        # Actually, this is too strict, because snapshots can be taken from caches
        CREATE_SNAPSHOT=false
        ERR="cache"
    elif lvm2_attr_is_thin_type "$LVM2_LV_ATTR" && ! lvm2_attr_is_thin_volume "$LVM2_LV_ATTR"; then
        CREATE_SNAPSHOT=false
        ERR="thin pool type volumes"
    elif lvm2_attr_is_mirror_type_or_pvmove "$LVM2_LV_ATTR"; then
        CREATE_SNAPSHOT=false
        ERR="mirror subvolumes or mirrors"
    elif lvm2_attr_is_raid_type "$LVM2_LV_ATTR" && ! lvm2_attr_is_raid "$LVM2_LV_ATTR"; then
        CREATE_SNAPSHOT=false
        ERR="raid subvolumes";
    fi

    if [[ "$CREATE_SNAPSHOT" = "false" ]]; then
        message "* Can't create snapshot from volume $LVM2_VG_NAME/$LVM2_LV_NAME: Snapshots of $ERR are not supported."
    else
        message "* Create snapshot from volume $LVM2_VG_NAME/$LVM2_LV_NAME:"
        lvm2_attr_info "$LVM2_LV_ATTR"

        LV_SNAPSHOT_NAME=${LVM2_LV_NAME}${LV_SNAPSHOT_SUFFIX}
        if lvm2_attr_is_thin_type "$LVM2_LV_ATTR"; then
            log "Create snapshot $LVM2_VG_NAME/$LV_SNAPSHOT_NAME"
            (set -xe;
                lvcreate -s -n "$LV_SNAPSHOT_NAME" -kn "$LVM2_LV_PATH";
            )
        else
            log "Create snapshot $LVM2_VG_NAME/$LV_SNAPSHOT_NAME"
            (set -xe;
                lvcreate -l50%FREE -s -n "$LV_SNAPSHOT_NAME" -kn "$LVM2_LV_PATH";
            )
        fi

        #log "Activate snapshot $LVM2_VG_NAME/$LV_SNAPSHOT_NAME"
        #(set -xe;
        #    lvchange -ay -K "$LVM2_VG_NAME/$LV_SNAPSHOT_NAME";
        #)

        CREATED_SNAPSHOT_PATHS+=( "$(lvm2_lv_path "$LV_SNAPSHOT_NAME" "$LVM2_VG_NAME")" )
        CREATED_SNAPSHOT_VG_NAMES+=( "$LVM2_VG_NAME" )
        CREATED_SNAPSHOT_ORIG_LV_NAMES+=( "$LVM2_LV_NAME" )
    fi
    echo;
}

print_help() {
    echo "Backup LVM volumes"
    echo
    echo "$0 [options]"
    echo "options:"
    echo "  -l, --list-volumes           Print list of LVM volumes"
    echo "  -i, --ignore-volume=         Ignore volume specified in format VOLUME_GROUP/VOLUME_NAME"
    echo "      --ignore-mount-error     Ignore errors when mounting volumes and continue with other volumes"
    echo "  -s, --snapshot-suffix=       Snapshot suffix used for backup snapshots (default: $DEFAULT_LV_SNAPSHOT_SUFFIX)"
    echo "  -w, --part-rw                Add partitions in read/write mode"
    echo "      --overwrite              Overwrite backup files"
    echo "  -p, --dest-prefix=           Destination file prefix (add / for directory)"
    echo "  -d, --debug                  Enable debug mode"
    echo "      --log-file=              Log all output and errors to the specified log file"
    echo "      --                       End of options"
}

# Main program

# Check required commands
for CMD in lvs lvcreate kpartx mount tar awk; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        fatal "$CMD command is missing"
    fi
done

IGNORE_VOLUMES=()
DEST_FILE_PREFIX=
KPARTX_RW=
DEBUG=
LOG_FILE=
OVERWRITE=
IGNORE_MOUNT_ERROR=

while [[ "$1" == "-"* ]]; do
    case "$1" in
    -l | --list-volumes)
        check_root
        list_volumes
        exit 0
        ;;
    -i | --ignore-volume)
        VOL="$2"
        IFS='/' read -ra VOL_GRP_NAME <<< "$VOL"
        if [[ ${#VOL_GRP_NAME[@]} -ne 2 ]]; then
            fatal "Volume name '$VOL' must be in format VOLUME_GROUP/VOLUME_NAME"
        fi
        IGNORE_VOLUMES+=("$VOL")
        shift 2
        ;;
    --ignore-volume=*)
        VOL="${1#*=}"
        IFS='/' read -ra VOL_GRP_NAME <<< "$VOL"
        if [[ ${#VOL_GRP_NAME[@]} -ne 2 ]]; then
            fatal "Volume name '$VOL' must be in format VOLUME_GROUP/VOLUME_NAME"
        fi
        IGNORE_VOLUMES+=("$VOL")
        shift
        ;;
    -s | --snapshot-suffix)
        LV_SNAPSHOT_SUFFIX="$2"
        shift 2
        ;;
    --snapshot-suffix=*)
        LV_SNAPSHOT_SUFFIX="${1#*=}"
        shift
        ;;
    -p|--dest-prefix)
        DEST_FILE_PREFIX="$2"
        shift 2
        ;;
    --dest-prefix=*)
        DEST_FILE_PREFIX="${1#*=}"
        shift
        ;;
    -w|--part-rw)
        KPARTX_RW=true
        shift
        ;;
    --overwrite)
        OVERWRITE=true
        shift
        ;;
    --ignore-mount-error)
        IGNORE_MOUNT_ERROR=true
        shift
        ;;
    -d|--debug)
        DEBUG=true
        shift
        ;;
    --log-file)
        LOG_FILE="$2"
        shift 2
        ;;
    --log-file=*)
        LOG_FILE="${1#*=}"
        shift
        ;;
    --help)
        print_help
        exit
        ;;
    --)
        shift
        break
        ;;
    -*)
        fatal "Invalid option $1"
        ;;
    *)
        break
        ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    fatal "You must run this tool as root"
    # exec sudo -E "$0" "$@"
fi

if [[ -n "$LOG_FILE" ]]; then
    message "* Log file: $LOG_FILE"
    enable_file_logging
else
    trap cleanup EXIT
fi

log "Start backup of LVM volumes"

if [[ "$DEBUG" == "true" ]]; then
    set -x
fi

message "* Cleanup old snapshots"
lvm2_for_each_logical_volume cleanup_old_snapshots

message "* Create new snapshots"
lvm2_for_each_logical_volume create_new_snapshots

NUM_BACKUP_VOLUMES=${#CREATED_SNAPSHOT_PATHS[@]}
for ((VOL_INDEX=0; VOL_INDEX<NUM_BACKUP_VOLUMES; ++VOL_INDEX)); do
    VOLUME_PATH=${CREATED_SNAPSHOT_PATHS[VOL_INDEX]}
    VG_NAME=${CREATED_SNAPSHOT_VG_NAMES[VOL_INDEX]}
    ORIG_LV_NAME=${CREATED_SNAPSHOT_ORIG_LV_NAMES[VOL_INDEX]}

    log "Process snapshot volume path $VOLUME_PATH from volume $VG_NAME/$ORIG_LV_NAME"

    if [[ -z "$DEST_FILE_PREFIX" ]]; then
        DEST_FILE_PREFIX=./
    fi

    if [[ "$DEST_FILE_PREFIX" = */ && ! -d "$DEST_FILE_PREFIX" ]]; then
        mkdir -p "$DEST_FILE_PREFIX"
    elif [[ -d "$DEST_FILE_PREFIX" && "$DEST_FILE_PREFIX" != */ ]]; then
        DEST_FILE_PREFIX=$DEST_FILE_PREFIX/
    fi

    log "Volume path: $VOLUME_PATH"
    log "Destination file prefix: $DEST_FILE_PREFIX"

    if ! KPARTX_OUT=$(kpartx -l "$VOLUME_PATH" | awk '{ print $1 }'); then
        log "Failed: kpartx -l $VOLUME_PATH"
        ls -la "$VOLUME_PATH" || true;
        stat "$VOLUME_PATH" || true;
        fatal "kpartx failed"
    fi

    dbg "KPARTX_OUT: $KPARTX_OUT"

    # http://mywiki.wooledge.org/BashFAQ/005#Loading_lines_from_a_file_or_stream
    KPARTX_PARTS=()
    while IFS= read -r; do
        if [[ -n "$REPLY" && "$REPLY" != [[:space:]]* ]]; then
            KPARTX_PARTS+=("$REPLY")
        fi
    done <<<"$KPARTX_OUT"
    if [[ -n "$REPLY" && "$REPLY" != [[:space:]]* ]]; then
        KPARTX_PARTS+=("$REPLY")
    fi

    #KPARTX_PARTS=()
    #while IFS='' read -r line; do KPARTX_PARTS+=("$line"); done <<<"$KPARTX_OUT"

    if [[ "${#KPARTX_PARTS[@]}" -ne 0 ]]; then
        if [[ "$KPARTX_RW" = "true" ]]; then
            kpartx -av "$VOLUME_PATH"
        else
            kpartx -avr "$VOLUME_PATH"
        fi

        KPARTX_PARTS_ADDED=true

        MOUNT_DIR=$(mktemp -d /tmp/volume-backup.XXXXXXXXXX) || fatal "Could not create mount directory"

        for PART_NAME in "${KPARTX_PARTS[@]}"; do
            dbg "PART_NAME: $PART_NAME"
            PART_DEV=/dev/mapper/$PART_NAME

            #if [[ "$KPARTX_RW" = "true" ]]; then
            #    fsck "$PART_DEV"
            #fi

            if mount -o ro -t auto "$PART_DEV" "$MOUNT_DIR"; then
                MOUNT_DIR_MOUNTED=true

                message "* Contents of the partition $PART_NAME:"
                ls -lA "$MOUNT_DIR"

                DEST_FILE=${DEST_FILE_PREFIX}${VG_NAME}-${ORIG_LV_NAME}-${PART_NAME}.tar.bz2

                log "Backup to file $DEST_FILE"

                if [[ -e "$DEST_FILE" ]]; then
                    dbg "OVERWRITE: $OVERWRITE"
                    if [[ "$OVERWRITE" = "true" ]]; then
                        log "Delete old backup file $DEST_FILE"
                        rm -f "$DEST_FILE"
                    else
                        fatal "File $DEST_FILE already exists"
                    fi
                fi

                tar --exclude "./lost+found" -C "$MOUNT_DIR" -cvf "$DEST_FILE" .

                umount "$MOUNT_DIR"
                MOUNT_DIR_MOUNTED=false
            else
                ERRMSG="Could not mount partition device $PART_DEV to directory $MOUNT_DIR"
                dbg "IGNORE_MOUNT_ERROR: $IGNORE_MOUNT_ERROR"
                if [[ "$IGNORE_MOUNT_ERROR" = "true" ]]; then
                    error "$ERRMSG"
                else
                    fatal "$ERRMSG"
                fi
            fi

        done

    else
        KPARTX_PARTS_ADDED=

        log "No partitions to mount in $VOLUME_PATH"
        log "Trying to mount a full volume as disk"

        #kpartx -l "$VOLUME_PATH"; #DBG
        #ls -lah "$VOLUME_PATH"; #DBG
        #export VOLUME_PATH MOUNT_DIR
        #message "Interactive"
        #bash -i

        MOUNT_DIR=$(mktemp -d /tmp/volume-backup.XXXXXXXXXX) || fatal "Could not create mount directory"

        if mount -o ro -t auto "$VOLUME_PATH" "$MOUNT_DIR"; then
            MOUNT_DIR_MOUNTED=true

            message "* Contents of the volume $VOLUME_PATH:"
            ls -lA "$MOUNT_DIR"

            DEST_FILE=${DEST_FILE_PREFIX}${VG_NAME}-${ORIG_LV_NAME}.tar.bz2

            log "Backup to file $DEST_FILE"

            if [[ -e "$DEST_FILE" ]]; then
                if [[ "$OVERWRITE" = "true" ]]; then
                    log "Delete old backup file $DEST_FILE"
                    rm -f "$DEST_FILE"
                else
                    fatal "File $DEST_FILE already exists"
                fi
            fi

            tar --exclude "./lost+found" -C "$MOUNT_DIR" -cvf "$DEST_FILE" .

            umount "$MOUNT_DIR"
            MOUNT_DIR_MOUNTED=false
        else
            ERRMSG="Could not mount partition device $VOLUME_PATH to directory $MOUNT_DIR"
            dbg "IGNORE_MOUNT_ERROR: $IGNORE_MOUNT_ERROR"
            if [[ "$IGNORE_MOUNT_ERROR" = "true" ]]; then
                error "$ERRMSG"
            else
                fatal "$ERRMSG"
            fi
        fi
    fi

done

#echo
#echo "Created snapshot paths: ${CREATED_SNAPSHOT_PATHS[*]}"
message "Backup finished"

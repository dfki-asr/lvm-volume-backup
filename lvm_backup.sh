#!/usr/bin/env bash

set -eo pipefail

export LC_ALL=C
unset CDPATH

THIS_DIR=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

log_no_echo() {
    logger -t lvm_backup "$*"
}

log() {
    log_no_echo "$*"
    echo >&2 "* $*"
}

error() {
    echo >&2 "Error: $*"
    log_no_echo "Error: $*"
}

warning() {
    echo >&2 "Warning: $*"
    log_no_echo "Warning: $*"
}

fatal() {
    echo >&2 "Fatal error: $*"
    log_no_echo "Fatal error: $*"
    echo >&2 "Exiting ..."
    exit 1
}

message() {
    echo >&2 "$*"
}

dbg() {
    echo >&2 "Debug: $*"
}

case "$(uname)" in
    MINGW*)
        _ps() {
            ps -a | awk 'NR>1 { print $1, $2; }'
        }
        ;;
    *)
        _ps() {
            ps -o pid,ppid -ax
        }
        ;;
esac

_get_children_pids() {
    local pid=$1
    local all_pids=$2
    local children
    for child in $(awk "{ if ( \$2 == $pid ) { print \$1 } }" <<<"$all_pids"); do
        children="$(_get_children_pids "$child" "$all_pids") $child $children"
    done
    echo "$children"
}

get_children_pids() {
    local pid=$1 all_pids
    all_pids=$(_ps)
    _get_children_pids "$pid" "$all_pids"
}

enable_file_logging() {
    if [[ -z "$OPT_LOG_FILE" ]]; then
        fatal "The OPT_LOG_FILE variable must not be empty."
    fi

    exec > >(tee -ia "$OPT_LOG_FILE")
    exec 2> >(tee -ia "$OPT_LOG_FILE" >&2)

    ## Close STDOUT file descriptor
    #exec 1<&-
    ## Close STDERR FD
    #exec 2<&-

    ## Open STDOUT as $OPT_LOG_FILE file for read and write.
    #exec 1>>"$OPT_LOG_FILE" 2>&1

    echo
    echo "$(date): ${BASH_SOURCE[0]}: start logging"

    on_error() {
        local errmsg err_lineno err_command err_code
        err_lineno="${1}"
        err_command="${2}"
        err_code="${3:-0}"

        if ! ((err_code)); then
            return "${err_code}"
        fi

        ## https://unix.stackexchange.com/questions/39623/trap-err-and-echoing-the-error-line
        ## Workaround for read EOF combo tripping traps
        errmsg=$(awk 'NR>L-4 && NR<L+4 { printf "%-5d%3s%s\n",NR,(NR==L?">>>":""),$0 }' L="$err_lineno" "$0")
        log "Error $err_code occurred in '$err_command' command
$errmsg"
        if ((BASH_SUBSHELL != 0)); then
            # Exit from subshell
            exit "${err_code}"
        else
            # Exit from top level script
            exit "${err_code}"
        fi
    }

    trap 'on_error "${LINENO}" "${BASH_COMMAND}" "${?}"' ERR

    on_exit() {
        local errmsg err_lineno err_funcname err_command err_code
        err_lineno="${1}"
        err_funcname="${2}"
        err_command="${3}"
        err_code="${4:-0}"

        if ((err_code)); then
            errmsg=$(awk 'NR>L-4 && NR<L+4 { printf "%-5d%3s%s\n",NR,(NR==L?">>>":""),$0 }' L="$err_lineno" "$0")
            log "Error $err_code occurred in '$err_command' command (function $err_funcname, line $err_lineno)
$errmsg"
        fi

        cleanup
        log "${BASH_SOURCE[0]}: exiting"
        # Close STDOUT file descriptor
        exec 1<&-
        # Close STDERR FD
        exec 2<&-
    }

    trap 'on_exit "${LINENO}" "${FUNCNAME}" "${BASH_COMMAND}" "${?}"' EXIT INT TERM
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

# $1 string
# $2 prefix
remove_prefix() {
    local s=$1 prefix=$2
    if [[ "$s" == "$prefix"* ]]; then
        printf %s "${s:${#prefix}}"
    else
        printf %s "$s"
    fi
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

DEFAULT_LV_SNAPSHOT_PREFIX="bak_snap_"
OPT_LV_SNAPSHOT_PREFIX="$DEFAULT_LV_SNAPSHOT_PREFIX"


lvm2_for_each_logical_volume() {
    local proc_func=$1 lvs_output line_num lvs_line IFS
    local LVM2_LV_NAME LVM2_VG_NAME LVM2_LV_PATH LVM2_LV_SIZE LVM2_LV_ATTR LVM2_SEGTYPE LVM2_ORIGIN
    if [[ -z "$proc_func" ]]; then
        error "Callback function name is required"
        return 1
    fi
    # Note: lvs may display the same volume multiple times for unclear reasons
    lvs_output=$(/sbin/lvs  --noheadings --separator='|' --units b --o lv_name,vg_name,lv_path,lv_size,lv_attr,origin,segtype | sort -u)
    line_num=0

    while IFS='' read -r lvs_line; do
        : $((line_num++))
        #echo "Accessing line $line_num: ${lvs_line}";

        lvs_line=$(trim "$lvs_line")
        IFS='|' read -r LVM2_LV_NAME LVM2_VG_NAME LVM2_LV_PATH LVM2_LV_SIZE LVM2_LV_ATTR LVM2_ORIGIN LVM2_SEGTYPE <<<"$lvs_line"
        "$proc_func" "$LVM2_LV_NAME" "$LVM2_VG_NAME" "$LVM2_LV_PATH" "$LVM2_LV_SIZE" "$LVM2_LV_ATTR" "$LVM2_ORIGIN" "$LVM2_SEGTYPE"
    done <<< "$lvs_output"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        fatal "You must run this command as root"
    fi
}

list_volumes() {
    lvm2_for_each_logical_volume print_lvm_volume_info
}

# Check if volume should be backed up
# Require defined variables LVM2_VG_NAME, LVM2_LV_NAME, LVM2_LV_ATTR
# Set variables CREATE_SNAPSHOT, SNAPSHOT_ERROR_REASON
_volume_check() {
    local ivol err
    SNAPSHOT_ERROR_REASON=

    if [[ "$LVM2_LV_NAME" == "$OPT_LV_SNAPSHOT_PREFIX"* ]]; then
        CREATE_SNAPSHOT=false
        SNAPSHOT_ERROR_REASON="Snapshots of backup snapshots are not supported, use --cleanup option"
        return 0
    fi

    if (( ${#OPT_BACKUP_VOLUMES[@]} )); then
        CREATE_SNAPSHOT=false
        for ivol in "${OPT_BACKUP_VOLUMES[@]}"; do
            if [[ "$ivol" = "$LVM2_VG_NAME/$LVM2_LV_NAME" ]]; then
                CREATE_SNAPSHOT=true
            fi
        done
        if [[ "$CREATE_SNAPSHOT" = "false" ]]; then
            return 0
        fi
    else
        CREATE_SNAPSHOT=true
    fi

    for ivol in "${OPT_IGNORE_VOLUMES[@]}"; do
        if [[ "$ivol" = "$LVM2_VG_NAME/$LVM2_LV_NAME" ]]; then
            CREATE_SNAPSHOT=false
            return 0
        fi
    done

    if lvm2_attr_is_cow "$LVM2_LV_ATTR"; then
        CREATE_SNAPSHOT=false
        err=snapshots
    elif lvm2_attr_is_locked "$LVM2_LV_ATTR"; then
        CREATE_SNAPSHOT=false
        err="locked volumes"
    elif lvm2_attr_is_pvmove "$LVM2_LV_ATTR"; then
        CREATE_SNAPSHOT=false
        err="pvmoved volumes"
    elif lvm2_attr_is_merging_origin "$LVM2_LV_ATTR"; then
        CREATE_SNAPSHOT=false
        err="an origin that has a merging snapshot"
    elif lvm2_attr_is_any_cache "$LVM2_LV_ATTR"; then
        # Actually, this is too strict, because snapshots can be taken from caches
        CREATE_SNAPSHOT=false
        err="cache"
    elif lvm2_attr_is_thin_type "$LVM2_LV_ATTR" && ! lvm2_attr_is_thin_volume "$LVM2_LV_ATTR"; then
        CREATE_SNAPSHOT=false
        err="thin pool type volumes"
    elif lvm2_attr_is_mirror_type_or_pvmove "$LVM2_LV_ATTR"; then
        CREATE_SNAPSHOT=false
        err="mirror subvolumes or mirrors"
    elif lvm2_attr_is_raid_type "$LVM2_LV_ATTR" && ! lvm2_attr_is_raid "$LVM2_LV_ATTR"; then
        CREATE_SNAPSHOT=false
        err="raid subvolumes"
    fi
    SNAPSHOT_ERROR_REASON="Snapshots of $err are not supported"
}

print_lvm_volume_info() {
    local CREATE_SNAPSHOT SNAPSHOT_ERROR_REASON
    _volume_check

    echo "Logical volume: '$LVM2_LV_NAME', volume group: '$LVM2_VG_NAME'"
    lvm2_attr_info "$LVM2_LV_ATTR"

    if [[ "$CREATE_SNAPSHOT" = "false" ]]; then
        if [[ -n "$SNAPSHOT_ERROR_REASON" ]]; then
            echo "I will not backup the volume $LVM2_VG_NAME/$LVM2_LV_NAME: $SNAPSHOT_ERROR_REASON."
        else
            echo "Volume $LVM2_VG_NAME/$LVM2_LV_NAME is ignored"
        fi
    else
        echo "I will backup the volume $LVM2_VG_NAME/$LVM2_LV_NAME"
    fi
    echo
}

remove_snapshot() {
    local snapshot_path=$1
    log "Remove snapshot $snapshot_path"
    (set -xe;
        if ! lvremove -y "$snapshot_path"; then
            # Try to remove kpartx mapping
            kpartx -vd "$snapshot_path" || true;
            lvremove -y "$snapshot_path" || true;
        fi
    )
}

# CL_ - global cleanup variables
CL_MOUNT_DIR=
CL_KPARTX_VOLUME_PATHS=()

volume_cleanup() {
    if [[ -n "$CL_MOUNT_DIR" ]]; then
        log "Unmounting $CL_MOUNT_DIR"
        umount "$CL_MOUNT_DIR" || true;
        rmdir "$CL_MOUNT_DIR" || true;
        CL_MOUNT_DIR=
    fi
    # https://serverfault.com/questions/477503/check-if-array-is-empty-in-bash/477506
    if (( ${#CL_KPARTX_VOLUME_PATHS[@]} )); then
        log "Remove kpartx volumes"
        local vol_path
        for vol_path in "${CL_KPARTX_VOLUME_PATHS[@]}"; do
            if [[ -e "$vol_path" ]]; then
                kpartx -vd "$vol_path" || true;
            fi
        done
        CL_KPARTX_VOLUME_PATHS=()
    fi
}

CL_LVCREATE_SNAPSHOT_NAME=
CL_LVCREATE_VG_NAME=
CL_SNAPSHOT_PATHS=()

kill-children() {
    local children_pids pid
    children_pids=$(get_children_pids "$$")
    for pid in $children_pids; do
        kill "$pid" 2>/dev/null || true;
    done
}

CL_BACKUP_PID=

cleanup() {
    log "Cleanup"
    if command -v pstree >/dev/null 2>&1; then
        pstree -plans "$$";
    fi
    if [[ -n "$CL_BACKUP_PID" ]]; then
        local children_pids pid
        children_pids=$(get_children_pids "$CL_BACKUP_PID")
        log "My PID $$"
        log "Backup process PID $CL_BACKUP_PID"
        log "Kill children [ $children_pids ]"

        # Send TERM signal to all children
        for pid in $children_pids $CL_BACKUP_PID; do
            kill -INT -- "$pid" 2>/dev/null || true;
            sleep 0.5;
            kill -TERM -- "$pid" 2>/dev/null || true;
        done

        # Wait for all children
        for pid in $children_pids $CL_BACKUP_PID; do
            if kill -0 "$pid" 2>/dev/null; then
                log "Wait for process $pid"
                ps -up "$pid" || true;
                while kill -0 "$pid" 2>/dev/null; do
                    sleep 0.5
                done
            fi
        done
    fi

    volume_cleanup
    if [[ -n "$CL_LVCREATE_SNAPSHOT_NAME" && -n "$CL_LVCREATE_VG_NAME" ]]; then
        local snapshot_path
        snapshot_path=$(lvm2_lv_path "$CL_LVCREATE_SNAPSHOT_NAME" "$CL_LVCREATE_VG_NAME")
        log "lvcreate was terminated, try to remove the created snapshot"
        remove_snapshot "$snapshot_path"
        CL_LVCREATE_SNAPSHOT_NAME=
        CL_LVCREATE_VG_NAME=
    fi
    if (( ${#CL_SNAPSHOT_PATHS[@]} )); then
        local snapshot_path
        log "Remove created snapshots"
        for snapshot_path in "${CL_SNAPSHOT_PATHS[@]}"; do
            remove_snapshot "$snapshot_path"
        done
        CL_SNAPSHOT_PATHS=()
    fi
    log "Cleanup finished"

    #if command -v pstree >/dev/null 2>&1; then
    #    pstree -plans
    #fi
}

cleanup_remnant_snapshots() {
    # Cleanup of remnant snapshots
    if lvm2_attr_is_cow "$LVM2_LV_ATTR" || [[ -n "$LVM2_ORIGIN" ]]; then
        message "* Check snapshot $LVM2_LV_NAME / $LVM2_VG_NAME"
        if [[ "$LVM2_LV_NAME" == "$OPT_LV_SNAPSHOT_PREFIX"* ]]; then
            message "* Snapshot $LVM2_LV_NAME / $LVM2_VG_NAME was identified as a remnant"
            # Try to umount if possible
            if ! command -v findmnt >/dev/null 2>&1; then
                message "! findmnt command is missing, cannot test for mounted directories !"
            else
                local mounted_path findmnt_output
                if findmnt_output=$(findmnt -l -n -o TARGET -S "$LVM2_LV_PATH"); then
                    while IFS= read -r mounted_path; do
                        if [[ "$mounted_path" == /tmp/volume-backup.* ]]; then
                            message "* Found mounted temporary directory $mounted_path"
                            if umount "$mounted_path"; then
                                message "* Unmounted temporary directory $mounted_path"
                                if rmdir "$mounted_path"; then
                                    message "* Deleted temporary directory $mounted_path"
                                else
                                    message "* Could not delete temporary directory $mounted_path"
                                fi
                            else
                                error "* Could not unmount directory $mounted_path"
                            fi
                        fi
                    done <<<"$findmnt_output"
                fi
            fi

            log "Remove remnant snapshot $LVM2_LV_PATH"
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

mount_and_backup() {
    local vol_path=$1 mount_dir=$2 dest_path=$3 exit_code

    if mount -o ro -t auto "$vol_path" "$mount_dir"; then
        CL_MOUNT_DIR=$mount_dir

        message "* Contents of the volume $vol_path:"
        ls -lA "$mount_dir"

        if [[ "$OPT_SYNC_MODE" = "true" ]]; then
            # Rsync mode, dest_path is a directory
            local src_dir dest_dir sync_cmd shell_val

            if [[ "$mount_dir" = */ ]]; then
                src_dir=$mount_dir
            else
                src_dir=${mount_dir}/
            fi
            if [[ "$dest_path" = */ ]]; then
                dest_dir=$dest_path
            else
                dest_dir=${dest_path}/
            fi

            printf -v shell_val "%q" "$src_dir"
            sync_cmd=${OPT_SYNC_CMD//"{src}"/"${shell_val}"}
            printf -v shell_val "%q" "$dest_dir"
            sync_cmd=${sync_cmd//"{dest}"/"${shell_val}"}

            mkdir -p "$dest_dir";
            log "Backup from $src_dir to $dest_dir"
            (set -e;
                eval "set -x; ${sync_cmd}";
            ) &
            CL_BACKUP_PID=$!
            set +e
            wait "$CL_BACKUP_PID"
            exit_code=$?
            set -e
            CL_BACKUP_PID=
            if (( exit_code != 0 )); then
                exit $exit_code
            fi
        else
            local tar_file
            # Tar mode, dest_path is a tar file
            tar_file=${dest_path}.tar.${OPT_COMPR_EXT}

            log "Backup to tar file $tar_file"

            if [[ -e "$tar_file" ]]; then
                if [[ "$OPT_OVERWRITE" = "true" ]]; then
                    log "Delete old backup file $tar_file"
                    rm -f "$tar_file"
                else
                    fatal "File $tar_file already exists"
                fi
            fi

            (set -xe;
                tar --exclude "./lost+found" -C "$mount_dir" -cvf "$tar_file" .;
            )
            CL_BACKUP_PID=$!
            set +e
            wait "$CL_BACKUP_PID"
            exit_code=$?
            set -e
            CL_BACKUP_PID=
            if (( exit_code != 0 )); then
                exit $exit_code
            fi
        fi

        umount "$mount_dir"
        CL_MOUNT_DIR=
    else
        local errmsg
        errmsg="Could not mount partition device $vol_path to directory $mount_dir"
        if [[ "$OPT_IGNORE_MOUNT_ERROR" = "true" ]]; then
            warning "$errmsg"
        else
            fatal "$errmsg"
        fi
    fi
}

backup_snapshot() {
    local volume_path=$1  vg_name=$2 orig_lv_name=$3

    log "Process snapshot volume path $volume_path from volume $vg_name/$orig_lv_name"
    log "Volume path: $volume_path"

    local kpartx_out
    if ! kpartx_out=$(kpartx -l "$volume_path" | awk '{ print $1 }'); then
        log "Failed: kpartx -l $volume_path"
        ls -la "$volume_path" || true;
        stat "$volume_path" || true;
        fatal "kpartx failed"
    fi

    # dbg "kpartx_out: "$'\n'"$kpartx_out"

    # http://mywiki.wooledge.org/BashFAQ/005#Loading_lines_from_a_file_or_stream
    local kpartx_parts=() kpartx_part
    while IFS= read -r kpartx_part; do
        if [[ -n "$kpartx_part" && "$kpartx_part" != [[:space:]]* ]]; then
            kpartx_parts+=("$kpartx_part")
        fi
    done <<<"$kpartx_out"
    if [[ -n "$kpartx_part" && "$kpartx_part" != [[:space:]]* ]]; then
        kpartx_parts+=("$kpartx_part")
    fi

    if [[ "${#kpartx_parts[@]}" -ne 0 ]]; then
        if [[ "$OPT_KPARTX_RW" = "true" ]]; then
            kpartx -av "$volume_path"
        else
            kpartx -avr "$volume_path"
        fi

        CL_KPARTX_VOLUME_PATHS+=("$volume_path")

        local mount_dir counter part_name part_dev dest_path
        mount_dir=$(mktemp -d /tmp/volume-backup.XXXXXXXXXX) || fatal "Could not create mount directory"

        counter=0
        for part_name in "${kpartx_parts[@]}"; do
            part_dev=/dev/mapper/$part_name
            : $(( counter++ ))

            #if [[ "$OPT_KPARTX_RW" = "true" ]]; then
            #    fsck "$part_dev"
            #fi

            dest_path=${OPT_DEST_PATH_PREFIX}${vg_name}-${orig_lv_name}-${counter}

            mount_and_backup "$part_dev" "$mount_dir" "$dest_path"
        done

        rmdir "$mount_dir"

        kpartx -vd "$volume_path"

        # Remove volume path from the cleanup variable
        unset 'CL_KPARTX_VOLUME_PATHS[${#CL_KPARTX_VOLUME_PATHS[@]}-1]'
    else

        log "No partitions to mount in $volume_path"
        log "Trying to mount a full volume as disk"

        local mount_dir dest_path
        mount_dir=$(mktemp -d /tmp/volume-backup.XXXXXXXXXX) || fatal "Could not create mount directory"

        dest_path=${OPT_DEST_PATH_PREFIX}${vg_name}-${orig_lv_name}

        mount_and_backup "$volume_path" "$mount_dir" "$dest_path"

        rmdir "$mount_dir"
    fi
}

create_and_backup_snapshots() {
    local CREATE_SNAPSHOT SNAPSHOT_ERROR_REASON
    _volume_check

    if [[ "$CREATE_SNAPSHOT" = "false" ]]; then
        if [[ -n "$SNAPSHOT_ERROR_REASON" ]]; then
            message "* Can't create snapshot from volume $LVM2_VG_NAME/$LVM2_LV_NAME: $SNAPSHOT_ERROR_REASON."
        else
            log "Volume $LVM2_VG_NAME/$LVM2_LV_NAME is ignored"
        fi
    else
        message "* Create snapshot from volume $LVM2_VG_NAME/$LVM2_LV_NAME:"
        lvm2_attr_info "$LVM2_LV_ATTR"

        local lv_snapshot_name=${OPT_LV_SNAPSHOT_PREFIX}${LVM2_LV_NAME}
        # When lvcreate is terminated, we must remove the snapshot
        # even if it is not yet registered in the CL_SNAPSHOT_PATHS variable
        CL_LVCREATE_SNAPSHOT_NAME=$lv_snapshot_name
        CL_LVCREATE_VG_NAME=$LVM2_VG_NAME
        if lvm2_attr_is_thin_type "$LVM2_LV_ATTR"; then
            log "Create snapshot $LVM2_VG_NAME/$lv_snapshot_name"
            (set -xe;
                lvcreate -s -n "$lv_snapshot_name" -kn "$LVM2_LV_PATH";
            )
        else
            log "Create snapshot $LVM2_VG_NAME/$lv_snapshot_name"
            (set -xe;
                lvcreate -l50%FREE -s -n "$lv_snapshot_name" -kn "$LVM2_LV_PATH";
            )
        fi
        CL_LVCREATE_SNAPSHOT_NAME=
        CL_LVCREATE_VG_NAME=

        #log "Activate snapshot $LVM2_VG_NAME/$lv_snapshot_name"
        #(set -xe;
        #    lvchange -ay -K "$LVM2_VG_NAME/$lv_snapshot_name";
        #)
        local snapshot_path
        snapshot_path=$(lvm2_lv_path "$lv_snapshot_name" "$LVM2_VG_NAME")

        # Save snapshot path in case of fatal error in cleanup variable
        CL_SNAPSHOT_PATHS+=( "$snapshot_path" )

        backup_snapshot "$snapshot_path" "$LVM2_VG_NAME" "$LVM2_LV_NAME"

        remove_snapshot "$snapshot_path"

        # Remove snapshot path from the cleanup variable
        unset 'CL_SNAPSHOT_PATHS[${#CL_SNAPSHOT_PATHS[@]}-1]'
    fi
    echo;
}

DEFAULT_SYNC_CMD="rsync -av --delete --exclude=\"lost+found\" {src} {dest}"

print_help() {
    echo "Backup LVM volumes"
    echo
    echo "$0 [options]"
    echo "options:"
    echo "  -l, --list-volumes           Print list of LVM volumes"
    echo "  -c, --cleanup                Remove remnant snapshots created by this tool but not deleted due to an error."
    echo "                               No backup is performed after the cleanup"
    echo "  -b, --backup-volume=         Backup volume specified in format VOLUME_GROUP/VOLUME_NAME."
    echo "                               If no backup volumes are specified, all found volumes will be backed up"
    echo "  -i, --ignore-volume=         Ignore volume specified in format VOLUME_GROUP/VOLUME_NAME"
    echo "      --ignore-mount-error     Ignore errors when mounting volumes and continue with other volumes"
    echo "  -s, --snapshot-prefix=       Snapshot prefix used for backup snapshots (default: $DEFAULT_LV_SNAPSHOT_PREFIX)"
    echo "  -w, --part-rw                Add partitions in read/write mode"
    echo "      --overwrite              Overwrite backup files"
    echo "  -p, --dest-prefix=           Destination path prefix (add / at the end for directory)"
    echo "      --rsync                  Use rsync instead of tar"
    echo "                               (is equivalent to --sync-cmd='$DEFAULT_SYNC_CMD')"
    echo "      --sync-cmd=              Use custom synchronization command and arguments instead of rsync,"
    echo "                               {src} is replaced by the source directory and {dest} by the destination directory"
    echo "  -d, --debug                  Enable debug mode"
    echo "      --log-file=              Log all output and errors to the specified log file"
    echo "      --                       End of options"
}

# Main program

# Check required commands
for CMD in lvs lvcreate mount tar awk sort; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        fatal "$CMD command is missing"
    fi
done

for CMD in kpartx rsync; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        warning "$CMD command is missing"
    fi
done

OPT_BACKUP_VOLUMES=()
OPT_IGNORE_VOLUMES=()
OPT_CLEANUP=
OPT_DEST_PATH_PREFIX=
OPT_KPARTX_RW=
OPT_DEBUG=
OPT_LOG_FILE=
OPT_OVERWRITE=
OPT_IGNORE_MOUNT_ERROR=
OPT_SYNC_MODE=
OPT_COMPR_EXT=bz2
OPT_SYNC_CMD=${DEFAULT_SYNC_CMD}

while [[ "$1" == "-"* ]]; do
    case "$1" in
    -l | --list-volumes)
        check_root
        list_volumes
        exit 0
        ;;
    -c | --cleanup)
        OPT_CLEANUP=true
        shift
        ;;
    -b | --backup-volume)
        VOL="$2"
        IFS='/' read -ra VOL_GRP_NAME <<< "$VOL"
        if [[ ${#VOL_GRP_NAME[@]} -ne 2 ]]; then
            fatal "Volume name '$VOL' must be in format VOLUME_GROUP/VOLUME_NAME"
        fi
        OPT_BACKUP_VOLUMES+=("$VOL")
        shift 2
        ;;
    --backup-volume=*)
        VOL="${1#*=}"
        IFS='/' read -ra VOL_GRP_NAME <<< "$VOL"
        if [[ ${#VOL_GRP_NAME[@]} -ne 2 ]]; then
            fatal "Volume name '$VOL' must be in format VOLUME_GROUP/VOLUME_NAME"
        fi
        OPT_BACKUP_VOLUMES+=("$VOL")
        shift
        ;;
    -i | --ignore-volume)
        VOL="$2"
        IFS='/' read -ra VOL_GRP_NAME <<< "$VOL"
        if [[ ${#VOL_GRP_NAME[@]} -ne 2 ]]; then
            fatal "Volume name '$VOL' must be in format VOLUME_GROUP/VOLUME_NAME"
        fi
        OPT_IGNORE_VOLUMES+=("$VOL")
        shift 2
        ;;
    --ignore-volume=*)
        VOL="${1#*=}"
        IFS='/' read -ra VOL_GRP_NAME <<< "$VOL"
        if [[ ${#VOL_GRP_NAME[@]} -ne 2 ]]; then
            fatal "Volume name '$VOL' must be in format VOLUME_GROUP/VOLUME_NAME"
        fi
        OPT_IGNORE_VOLUMES+=("$VOL")
        shift
        ;;
    -s | --snapshot-prefix)
        OPT_LV_SNAPSHOT_PREFIX="$2"
        shift 2
        ;;
    --snapshot-prefix=*)
        OPT_LV_SNAPSHOT_PREFIX="${1#*=}"
        shift
        ;;
    -p|--dest-prefix)
        OPT_DEST_PATH_PREFIX="$2"
        shift 2
        ;;
    --dest-prefix=*)
        OPT_DEST_PATH_PREFIX="${1#*=}"
        shift
        ;;
    -w|--part-rw)
        OPT_KPARTX_RW=true
        shift
        ;;
    --overwrite)
        OPT_OVERWRITE=true
        shift
        ;;
    --ignore-mount-error)
        OPT_IGNORE_MOUNT_ERROR=true
        shift
        ;;
    --rsync)
        OPT_SYNC_MODE=true
        OPT_SYNC_CMD=${DEFAULT_SYNC_CMD}
        shift
        ;;
    --sync-cmd)
        OPT_SYNC_CMD="$2"
        OPT_SYNC_MODE=true
        shift 2
        ;;
    --sync-cmd=*)
        OPT_SYNC_CMD="${1#*=}"
        OPT_SYNC_MODE=true
        shift
        ;;
    -d|--debug)
        OPT_DEBUG=true
        shift
        ;;
    --log-file)
        OPT_LOG_FILE="$2"
        shift 2
        ;;
    --log-file=*)
        OPT_LOG_FILE="${1#*=}"
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

if [[ -z "$OPT_LV_SNAPSHOT_PREFIX" ]]; then
    fatal "Snapshot prefix cannot be empty"
fi

check_root

if [[ -n "$OPT_LOG_FILE" ]]; then
    message "* Log file: $OPT_LOG_FILE"
    enable_file_logging
else
    trap cleanup EXIT INT TERM
fi

if [[ "$OPT_DEBUG" == "true" ]]; then
    set -x
fi

if [[ -z "$OPT_DEST_PATH_PREFIX" ]]; then
    OPT_DEST_PATH_PREFIX=./
fi

if [[ "$OPT_DEST_PATH_PREFIX" = */ && ! -d "$OPT_DEST_PATH_PREFIX" ]]; then
    mkdir -p "$OPT_DEST_PATH_PREFIX"
elif [[ -d "$OPT_DEST_PATH_PREFIX" && "$OPT_DEST_PATH_PREFIX" != */ ]]; then
    OPT_DEST_PATH_PREFIX=$OPT_DEST_PATH_PREFIX/
fi

if [[ "$OPT_CLEANUP" = "true" ]]; then
    message "* Cleanup remnant snapshots"
    lvm2_for_each_logical_volume cleanup_remnant_snapshots
    exit 0
fi

if [[ "$OPT_SYNC_MODE" = "true" ]]; then
    message "* Synchronization command: ${OPT_SYNC_CMD}"
fi

log "Start backup of LVM volumes"
log "Destination path prefix: $OPT_DEST_PATH_PREFIX"

message "* Create and backup snapshots"
lvm2_for_each_logical_volume create_and_backup_snapshots

log "End backup of LVM volumes"

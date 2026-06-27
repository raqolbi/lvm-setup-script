#!/usr/bin/env bash
#
# lvm-manager.sh - Interactive LVM management for Ubuntu Server 24.04 LTS
#
# Usage: sudo ./lvm-manager.sh
#

set -Eeuo pipefail

readonly SCRIPT_NAME="lvm-manager"
readonly LOG_FILE="/var/log/lvm-manager.log"
# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Global state (set during operations for summary / cleanup)
SELECTED_DISK=""
SELECTED_PARTITION=""
SELECTED_VG=""
SELECTED_LV=""
SELECTED_FS=""
SELECTED_MOUNT=""
SELECTED_SIZE=""
OPERATION_IN_PROGRESS=false

# ---------------------------------------------------------------------------
# Logging and output
# ---------------------------------------------------------------------------

log() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] $*" >> "${LOG_FILE}" 2>/dev/null || true
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
    log "SUCCESS: $*"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
    log "WARNING: $*"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    log "ERROR: $*"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
    log "INFO: $*"
}

print_header() {
    echo
    echo "========================================"
    echo "$*"
    echo "========================================"
    echo
}

# Execute a command after printing it; abort on failure (set -e).
run_cmd() {
    local cmd_display="$*"
    print_info "Executing: ${cmd_display}"
    log "EXEC: ${cmd_display}"
    "$@"
}

# ---------------------------------------------------------------------------
# Error handling and cleanup
# ---------------------------------------------------------------------------

cleanup() {
    local exit_code=$?
    if [[ "${OPERATION_IN_PROGRESS}" == true && ${exit_code} -ne 0 ]]; then
        print_error "Operation aborted due to an error (exit code ${exit_code})."
        print_warning "Review ${LOG_FILE} and current system state before retrying."
    fi
}

on_err() {
    local line="$1"
    print_error "Command failed at line ${line}."
    exit 1
}

trap cleanup EXIT
trap 'on_err ${LINENO}' ERR

# ---------------------------------------------------------------------------
# Privilege and dependency checks
# ---------------------------------------------------------------------------

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)."
        exit 1
    fi

    if ! touch "${LOG_FILE}" 2>/dev/null; then
        print_error "Cannot write to log file: ${LOG_FILE}"
        exit 1
    fi
    chmod 640 "${LOG_FILE}" 2>/dev/null || true
    log "===== ${SCRIPT_NAME} session started (PID $$) ====="
}

declare -A DEP_PACKAGES=(
    [lsblk]=util-linux
    [blkid]=util-linux
    [parted]=parted
    [partprobe]=parted
    [pvcreate]=lvm2
    [pvs]=lvm2
    [vgcreate]=lvm2
    [vgs]=lvm2
    [vgextend]=lvm2
    [lvcreate]=lvm2
    [lvs]=lvm2
    [lvextend]=lvm2
    [resize2fs]=e2fsprogs
    [xfs_growfs]=xfsprogs
    [mount]=mount
    [findmnt]=util-linux
    [df]=coreutils
)

check_dependencies() {
    local missing=()
    local cmd pkg

    for cmd in "${!DEP_PACKAGES[@]}"; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd} (package: ${DEP_PACKAGES[${cmd}]})")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing required commands:"
        for entry in "${missing[@]}"; do
            echo "  - ${entry}"
        done
        print_info "Install on Ubuntu 24.04: sudo apt-get install lvm2 parted e2fsprogs xfsprogs util-linux"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# User input helpers
# ---------------------------------------------------------------------------

confirm_action() {
    local prompt="$1"
    local answer

    while true; do
        read -r -p "$(echo -e "${YELLOW}${prompt} [yes/no]: ${NC}")" answer
        case "${answer,,}" in
            yes|y) return 0 ;;
            no|n)  return 1 ;;
            *)     print_warning "Please answer 'yes' or 'no'." ;;
        esac
    done
}

confirm_double_action() {
    local prompt="$1"
    confirm_action "${prompt}" || return 1
    confirm_action "CONFIRM AGAIN — ${prompt}" || return 1
}

read_nonempty() {
    local prompt="$1"
    local value=""

    while [[ -z "${value}" ]]; do
        read -r -p "${prompt}: " value
        if [[ -z "${value}" ]]; then
            print_warning "Value cannot be empty."
        fi
    done
    echo "${value}"
}

validate_vg_name() {
    local name="$1"
    [[ "${name}" =~ ^[a-zA-Z0-9_.+-]+$ ]]
}

validate_lv_name() {
    local name="$1"
    [[ "${name}" =~ ^[a-zA-Z0-9_.+-]+$ ]]
}

validate_size() {
    local size="$1"
    [[ "${size}" =~ ^[0-9]+(\.[0-9]+)?[KMGTP]?$|^[0-9]+%FREE$ ]]
}

validate_extend_size() {
    local size="$1"
    [[ "${size}" =~ ^\+[0-9]+(\.[0-9]+)?[KMGTP]?$|^\+[0-9]+%FREE$ ]]
}

validate_mount_point() {
    local mp="$1"
    [[ "${mp}" =~ ^/ ]] && [[ "${mp}" != "/" ]]
}

validate_fs_type() {
    local fs="$1"
    [[ "${fs}" == "ext4" || "${fs}" == "xfs" ]]
}

# ---------------------------------------------------------------------------
# Disk and LVM discovery
# ---------------------------------------------------------------------------

get_root_disk() {
    local src disk

    src="$(findmnt -n -o SOURCE /)"
    disk="$(lsblk -ns -o NAME,TYPE "${src}" 2>/dev/null | awk '$2=="disk"{print "/dev/"$1; exit}')"

    if [[ -z "${disk}" ]]; then
        # Fallback: strip partition suffix from source device
        src="$(readlink -f "${src}")"
        local base
        base="$(basename "${src}")"
        if [[ "${base}" =~ ^(nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
            disk="/dev/${BASH_REMATCH[1]}"
        elif [[ "${base}" =~ ^([a-z]+)[0-9]+$ ]]; then
            disk="/dev/${BASH_REMATCH[1]}"
        fi
    fi

    echo "${disk}"
}

disk_is_pv() {
    local dev="$1"
    pvs --noheadings -o pv_name 2>/dev/null | awk '{print $1}' | grep -qx "${dev}"
}

disk_in_vg() {
    local dev="$1"
    local pv
    for pv in $(pvs --noheadings -o pv_name 2>/dev/null); do
        if [[ "${pv}" == "${dev}"* ]]; then
            return 0
        fi
    done
    return 1
}

disk_is_available() {
    local disk="$1"
    local root_disk type mounted has_parts has_fs

    root_disk="$(get_root_disk)"

    if [[ "${disk}" == "${root_disk}" ]]; then
        return 1
    fi

    type="$(lsblk -dn -o TYPE "${disk}" 2>/dev/null | head -1)"
    if [[ "${type}" != "disk" ]]; then
        return 1
    fi

    if lsblk -n -o MOUNTPOINT "${disk}" 2>/dev/null | grep -q '[^[:space:]]'; then
        return 1
    fi

    if lsblk -n -o TYPE "${disk}" 2>/dev/null | grep -q '^part$'; then
        return 1
    fi

    if blkid "${disk}" &>/dev/null; then
        return 1
    fi

    if disk_is_pv "${disk}"; then
        return 1
    fi

    if disk_in_vg "${disk}"; then
        return 1
    fi

    return 0
}

detect_empty_disks() {
    local -a disks=()
    local dev name

    while IFS= read -r name; do
        dev="/dev/${name}"
        if disk_is_available "${dev}"; then
            disks+=("${dev}")
        fi
    done < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}')

    echo "${disks[@]}"
}

partition_device() {
    local disk="$1"
    local part_num="${2:-1}"

    if [[ "${disk}" =~ nvme ]]; then
        echo "${disk}p${part_num}"
    else
        echo "${disk}${part_num}"
    fi
}

choose_disk() {
    local -a disks=()
    local disk size choice i

    read -r -a disks <<< "$(detect_empty_disks)"

    if [[ ${#disks[@]} -eq 0 ]]; then
        print_warning "No available disk detected."
        return 1
    fi

    if [[ ${#disks[@]} -eq 1 ]]; then
        SELECTED_DISK="${disks[0]}"
        size="$(lsblk -dn -o SIZE "${SELECTED_DISK}")"
        print_info "Automatically selected disk: ${SELECTED_DISK} (${size})"
        return 0
    fi

    print_header "Available Empty Disks"
    for i in "${!disks[@]}"; do
        size="$(lsblk -dn -o SIZE "${disks[$i]}")"
        echo "$((i + 1))) ${disks[$i]}   ${size}"
    done
    echo

    while true; do
        read -r -p "Select disk: " choice
        if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#disks[@]} )); then
            SELECTED_DISK="${disks[$((choice - 1))]}"
            return 0
        fi
        print_warning "Invalid selection. Enter a number between 1 and ${#disks[@]}."
    done
}

choose_from_list() {
    # Usage: choose_from_list "prompt" item1 item2 ...
    # Menu is printed to stderr so stdout can be captured by callers.
    local prompt="$1"
    shift
    local -a items=("$@")
    local choice i

    if [[ ${#items[@]} -eq 0 ]]; then
        return 1
    fi

    for i in "${!items[@]}"; do
        echo "$((i + 1))) ${items[$i]}" >&2
    done
    echo >&2

    while true; do
        read -r -p "${prompt}: " choice
        if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#items[@]} )); then
            echo "${items[$((choice - 1))]}"
            return 0
        fi
        print_warning "Invalid selection."
    done
}

# ---------------------------------------------------------------------------
# Partition and LVM operations
# ---------------------------------------------------------------------------

create_partition() {
    local disk="$1"
    local part

    if ! confirm_double_action "Create GPT partition table on ${disk} (DESTRUCTIVE: mklabel)"; then
        print_info "Partition creation cancelled."
        return 1
    fi

    run_cmd parted -s "${disk}" mklabel gpt
    run_cmd parted -s "${disk}" mkpart primary 0% 100%
    run_cmd parted -s "${disk}" set 1 lvm on

    part="$(partition_device "${disk}")"
    run_cmd partprobe "${disk}"
    sleep 2

    if [[ ! -b "${part}" ]]; then
        print_error "Partition ${part} not found after partprobe."
        return 1
    fi

    SELECTED_PARTITION="${part}"
    print_success "Partition created: ${SELECTED_PARTITION}"
}

create_pv() {
    local dev="$1"

    if pvs "${dev}" &>/dev/null; then
        print_warning "Physical volume already exists on ${dev}."
        return 0
    fi

    if ! confirm_double_action "Create physical volume on ${dev} (pvcreate)"; then
        print_info "PV creation cancelled."
        return 1
    fi

    run_cmd pvcreate -y "${dev}"
    print_success "Physical volume created on ${dev}"
}

create_vg() {
    local vg_name="$1"
    local pv="$2"

    if vgs "${vg_name}" &>/dev/null; then
        print_error "Volume group '${vg_name}' already exists."
        return 1
    fi

    if ! confirm_double_action "Create volume group '${vg_name}' (vgcreate)"; then
        print_info "VG creation cancelled."
        return 1
    fi

    run_cmd vgcreate "${vg_name}" "${pv}"
    SELECTED_VG="${vg_name}"
    print_success "Volume group '${vg_name}' created."
}

create_lv() {
    local vg_name="$1"
    local lv_name="$2"
    local size="$3"

    if lvs "${vg_name}/${lv_name}" &>/dev/null; then
        print_error "Logical volume '${vg_name}/${lv_name}' already exists."
        return 1
    fi

    if ! confirm_double_action "Create logical volume '${lv_name}' (${size}) in '${vg_name}' (lvcreate)"; then
        print_info "LV creation cancelled."
        return 1
    fi

    if [[ "${size}" =~ %FREE$ ]]; then
        run_cmd lvcreate -l "${size}" -n "${lv_name}" "${vg_name}"
    else
        run_cmd lvcreate -L "${size}" -n "${lv_name}" "${vg_name}"
    fi

    SELECTED_LV="${lv_name}"
    SELECTED_SIZE="${size}"
    print_success "Logical volume '${vg_name}/${lv_name}' created."
}

format_fs() {
    local lv_path="$1"
    local fs_type="$2"

    if blkid "${lv_path}" &>/dev/null; then
        local existing_fs
        existing_fs="$(blkid -o value -s TYPE "${lv_path}" 2>/dev/null || true)"
        if [[ -n "${existing_fs}" ]]; then
            print_warning "Filesystem already present on ${lv_path} (${existing_fs}). Skipping format."
            SELECTED_FS="${existing_fs}"
            return 0
        fi
    fi

    if ! confirm_double_action "Format ${lv_path} as ${fs_type} (mkfs — DESTRUCTIVE)"; then
        print_info "Format cancelled."
        return 1
    fi

    case "${fs_type}" in
        ext4) run_cmd mkfs.ext4 -F "${lv_path}" ;;
        xfs)  run_cmd mkfs.xfs -f "${lv_path}" ;;
        *)    print_error "Unsupported filesystem: ${fs_type}"; return 1 ;;
    esac

    SELECTED_FS="${fs_type}"
    print_success "Filesystem ${fs_type} created on ${lv_path}"
}

mount_lv() {
    local lv_path="$1"
    local mount_point="$2"

    if findmnt -n "${mount_point}" &>/dev/null; then
        print_warning "Mount point ${mount_point} is already in use."
        if ! confirm_action "Continue using existing mount at ${mount_point}?"; then
            return 1
        fi
        return 0
    fi

    if [[ ! -d "${mount_point}" ]]; then
        if confirm_action "Create mount point directory ${mount_point}?"; then
            run_cmd mkdir -p "${mount_point}"
        else
            return 1
        fi
    fi

    run_cmd mount "${lv_path}" "${mount_point}"
    SELECTED_MOUNT="${mount_point}"
    print_success "Mounted ${lv_path} at ${mount_point}"
}

update_fstab() {
    local lv_path="$1"
    local mount_point="$2"
    local fs_type="$3"
    local uuid entry

    uuid="$(blkid -s UUID -o value "${lv_path}")"
    if [[ -z "${uuid}" ]]; then
        print_error "Could not determine UUID for ${lv_path}"
        return 1
    fi

    if grep -qE "[[:space:]]${mount_point}[[:space:]]" /etc/fstab; then
        print_warning "/etc/fstab already contains an entry for ${mount_point}. Skipping append."
        return 0
    fi

    if grep -q "UUID=${uuid}" /etc/fstab; then
        print_warning "UUID ${uuid} already present in /etc/fstab. Skipping append."
        return 0
    fi

    entry="UUID=${uuid}  ${mount_point}  ${fs_type}  defaults  0  2"

    echo "  ${entry}"
    if confirm_action "Append the above line to /etc/fstab?"; then
        run_cmd cp -a /etc/fstab "/etc/fstab.lvm-manager.bak.$(date +%Y%m%d%H%M%S)"
        echo "${entry}" >> /etc/fstab
        log "FSTAB: added ${entry}"
        print_success "Entry added to /etc/fstab"
    else
        print_warning "fstab not updated. Add manually if persistence is required."
    fi
}

verify_mount() {
    local mount_point="$1"
    local lv_path="$2"

    if ! findmnt -n "${mount_point}" &>/dev/null; then
        print_error "Mount verification failed: ${mount_point} is not mounted."
        return 1
    fi

    local source
    source="$(findmnt -n -o SOURCE "${mount_point}")"
    if [[ "${source}" != "${lv_path}" ]]; then
        print_warning "Mount source is '${source}', expected '${lv_path}'."
    fi

    run_cmd df -h "${mount_point}"
    print_success "Mount verified: ${mount_point}"
}

extend_vg() {
    local vg_name="$1"
    local pv="$2"

    if ! confirm_action "Extend volume group '${vg_name}' with ${pv}?"; then
        return 1
    fi

    run_cmd vgextend "${vg_name}" "${pv}"
    print_success "Volume group '${vg_name}' extended with ${pv}"
}

extend_lv() {
    local lv_path="$1"
    local extend_size="$2"

    if [[ "${extend_size}" =~ %FREE$ ]]; then
        run_cmd lvextend -l "${extend_size}" "${lv_path}"
    else
        run_cmd lvextend -L "${extend_size}" "${lv_path}"
    fi

    SELECTED_SIZE="$(lvs --noheadings -o lv_size --units g --nosuffix "${lv_path}" 2>/dev/null | tr -d ' ')G"
    print_success "Logical volume extended: ${lv_path}"
}

resize_filesystem() {
    local lv_path="$1"
    local mount_point="$2"
    local fs_type

    fs_type="$(blkid -o value -s TYPE "${lv_path}" 2>/dev/null || true)"

    if [[ -z "${fs_type}" && -n "${mount_point}" ]]; then
        fs_type="$(findmnt -n -o FSTYPE "${mount_point}" 2>/dev/null || true)"
    fi

    case "${fs_type}" in
        ext4)
            run_cmd resize2fs "${lv_path}"
            SELECTED_FS="ext4"
            ;;
        xfs)
            if [[ -z "${mount_point}" ]]; then
                mount_point="$(findmnt -n -o TARGET "${lv_path}" 2>/dev/null || true)"
            fi
            if [[ -z "${mount_point}" ]]; then
                print_error "xfs_growfs requires a mount point for ${lv_path}"
                return 1
            fi
            run_cmd xfs_growfs "${mount_point}"
            SELECTED_FS="xfs"
            ;;
        *)
            print_error "Unsupported or unknown filesystem type: '${fs_type}'"
            return 1
            ;;
    esac

    print_success "Filesystem resized (${fs_type})"
}

# ---------------------------------------------------------------------------
# Menu workflows
# ---------------------------------------------------------------------------

print_operation_summary() {
    print_header "Operation Completed Successfully"
    [[ -n "${SELECTED_VG}" ]]       && echo "VG         : ${SELECTED_VG}"
    [[ -n "${SELECTED_LV}" ]]       && echo "LV         : ${SELECTED_LV}"
    [[ -n "${SELECTED_FS}" ]]       && echo "Filesystem : ${SELECTED_FS}"
    [[ -n "${SELECTED_MOUNT}" ]]    && echo "Mount      : ${SELECTED_MOUNT}"
    [[ -n "${SELECTED_SIZE}" ]]     && echo "Size       : ${SELECTED_SIZE}"
    [[ -n "${SELECTED_DISK}" ]]     && echo "Disk       : ${SELECTED_DISK}"
    [[ -n "${SELECTED_PARTITION}" ]] && echo "Partition  : ${SELECTED_PARTITION}"
    echo "========================================"
    echo
}

reset_operation_state() {
    SELECTED_DISK=""
    SELECTED_PARTITION=""
    SELECTED_VG=""
    SELECTED_LV=""
    SELECTED_FS=""
    SELECTED_MOUNT=""
    SELECTED_SIZE=""
    OPERATION_IN_PROGRESS=false
}

workflow_create_lvm() {
    local vg_name lv_name size fs_type mount_point lv_path

    reset_operation_state
    OPERATION_IN_PROGRESS=true

    print_header "Create New LVM"

    if ! choose_disk; then
        OPERATION_IN_PROGRESS=false
        return 0
    fi

    size="$(lsblk -dn -o SIZE "${SELECTED_DISK}")"
    print_info "Selected disk: ${SELECTED_DISK} (${size})"
    if ! confirm_action "Proceed with LVM setup on ${SELECTED_DISK}?"; then
        OPERATION_IN_PROGRESS=false
        return 0
    fi

    create_partition "${SELECTED_DISK}"
    create_pv "${SELECTED_PARTITION}"

    while true; do
        vg_name="$(read_nonempty "Enter Volume Group name")"
        if validate_vg_name "${vg_name}"; then
            break
        fi
        print_warning "Invalid VG name. Use letters, numbers, underscore, hyphen, dot, plus."
    done
    create_vg "${vg_name}" "${SELECTED_PARTITION}"

    while true; do
        lv_name="$(read_nonempty "Enter Logical Volume name")"
        if validate_lv_name "${lv_name}"; then
            break
        fi
        print_warning "Invalid LV name."
    done

    while true; do
        read -r -p "Enter LV size (e.g. 100G, 50G, 100%FREE): " size
        if validate_size "${size}"; then
            break
        fi
        print_warning "Invalid size. Examples: 100G, 50M, 100%FREE"
    done
    create_lv "${vg_name}" "${lv_name}" "${size}"

    lv_path="/dev/${vg_name}/${lv_name}"

    while true; do
        read -r -p "Filesystem type [ext4/xfs]: " fs_type
        fs_type="${fs_type,,}"
        if validate_fs_type "${fs_type}"; then
            break
        fi
        print_warning "Choose ext4 or xfs."
    done
    format_fs "${lv_path}" "${fs_type}"

    while true; do
        read -r -p "Enter mount point (absolute path, not /): " mount_point
        if validate_mount_point "${mount_point}"; then
            break
        fi
        print_warning "Mount point must be an absolute path and cannot be /."
    done

    mount_lv "${lv_path}" "${mount_point}"
    update_fstab "${lv_path}" "${mount_point}" "${fs_type}"
    verify_mount "${mount_point}" "${lv_path}"

    SELECTED_SIZE="$(lvs --noheadings -o lv_size "${lv_path}" 2>/dev/null | tr -d ' ')"
    OPERATION_IN_PROGRESS=false
    print_operation_summary
}

workflow_extend_lvm() {
    local -a vg_list lv_list
    local vg_name lv_name lv_path extend_size
    local empty_disks disk_choice use_new_disk mount_point

    reset_operation_state
    OPERATION_IN_PROGRESS=true

    print_header "Extend Existing LVM"

    mapfile -t vg_list < <(vgs --noheadings -o vg_name 2>/dev/null | awk '{$1=$1;print}')
    if [[ ${#vg_list[@]} -eq 0 ]]; then
        print_warning "No volume groups found."
        OPERATION_IN_PROGRESS=false
        return 0
    fi

    print_info "Volume Groups:"
    vg_name="$(choose_from_list "Select Volume Group" "${vg_list[@]}")"
    SELECTED_VG="${vg_name}"

    mapfile -t lv_list < <(lvs --noheadings -o lv_name "${vg_name}" 2>/dev/null | awk '{$1=$1;print}')
    if [[ ${#lv_list[@]} -eq 0 ]]; then
        print_warning "No logical volumes in ${vg_name}."
        OPERATION_IN_PROGRESS=false
        return 0
    fi

    print_info "Logical Volumes in ${vg_name}:"
    lv_name="$(choose_from_list "Select Logical Volume" "${lv_list[@]}")"
    SELECTED_LV="${lv_name}"
    lv_path="/dev/${vg_name}/${lv_name}"

    read -r -a empty_disks <<< "$(detect_empty_disks)"
    if [[ ${#empty_disks[@]} -gt 0 ]]; then
        print_info "Empty disk(s) available for VG extension."
        if confirm_action "Use a new disk to extend '${vg_name}'?"; then
            if [[ ${#empty_disks[@]} -eq 1 ]]; then
                SELECTED_DISK="${empty_disks[0]}"
            else
                print_header "Available Empty Disks"
                disk_choice="$(choose_from_list "Select disk" "${empty_disks[@]}")"
                SELECTED_DISK="${disk_choice}"
            fi

            print_info "Using disk: ${SELECTED_DISK}"
            if confirm_action "Add ${SELECTED_DISK} to volume group '${vg_name}'?"; then
                create_partition "${SELECTED_DISK}"
                create_pv "${SELECTED_PARTITION}"
                extend_vg "${vg_name}" "${SELECTED_PARTITION}"
            fi
        fi
    else
        print_info "No empty disks available; extending within existing VG free space."
    fi

    while true; do
        read -r -p "Enter extension size (e.g. +50G, +100G, +100%FREE): " extend_size
        if validate_extend_size "${extend_size}"; then
            break
        fi
        print_warning "Invalid size. Use +50G, +100G, +100%FREE, etc."
    done

    if ! confirm_action "Extend ${lv_path} by ${extend_size}?"; then
        OPERATION_IN_PROGRESS=false
        return 0
    fi

    extend_lv "${lv_path}" "${extend_size}"

    mount_point="$(findmnt -n -o TARGET "${lv_path}" 2>/dev/null || true)"
    resize_filesystem "${lv_path}" "${mount_point}"

    SELECTED_SIZE="$(lvs --noheadings -o lv_size "${lv_path}" 2>/dev/null | tr -d ' ')"
    OPERATION_IN_PROGRESS=false
    print_operation_summary
}

show_info() {
    print_header "LVM Information"

    echo -e "${BLUE}--- lsblk ---${NC}"
    run_cmd lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID

    echo
    echo -e "${BLUE}--- Physical Volumes (pvs) ---${NC}"
    if pvs &>/dev/null; then
        run_cmd pvs -o pv_name,vg_name,pv_size,pv_free
    else
        print_info "No physical volumes."
    fi

    echo
    echo -e "${BLUE}--- Volume Groups (vgs) ---${NC}"
    if vgs &>/dev/null; then
        run_cmd vgs -o vg_name,pv_count,lv_count,vg_size,vg_free
    else
        print_info "No volume groups."
    fi

    echo
    echo -e "${BLUE}--- Logical Volumes (lvs) ---${NC}"
    if lvs &>/dev/null; then
        run_cmd lvs -o lv_name,vg_name,lv_size,lv_path
    else
        print_info "No logical volumes."
    fi

    echo
    echo -e "${BLUE}--- Disk Usage (df -h) ---${NC}"
    run_cmd df -h

    echo
    echo -e "${BLUE}--- Mounts ---${NC}"
    run_cmd mount | grep -E '^/dev/' || print_info "No block-device mounts listed."

    echo
    echo -e "${BLUE}--- Filesystem Types ---${NC}"
    if lsblk -o NAME,FSTYPE -nr 2>/dev/null | awk '$2!=""{print}' | grep -q .; then
        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT | awk 'NR==1 || $3!=""'
    else
        print_info "No filesystems detected on block devices."
    fi

    echo
    echo -e "${BLUE}--- Free Space Summary ---${NC}"
    if vgs --noheadings -o vg_name,vg_free 2>/dev/null | grep -q .; then
        vgs -o vg_name,vg_size,vg_free --units g
    else
        print_info "No VG free space to report."
    fi

    echo
    local root_disk empty_disks
    root_disk="$(get_root_disk)"
    empty_disks="$(detect_empty_disks)"
    print_info "Detected root/OS disk: ${root_disk:-unknown}"
    if [[ -z "${empty_disks}" ]]; then
        print_info "Available empty disks: none"
    else
        print_info "Available empty disks: ${empty_disks}"
    fi
}

print_menu() {
    print_header "LVM Manager"
    echo "1. Create New LVM"
    echo "2. Extend Existing LVM"
    echo "3. Show LVM Information"
    echo "4. Exit"
    echo
}

main() {
    check_root
    check_dependencies

    while true; do
        print_menu
        local choice
        read -r -p "Select option [1-4]: " choice

        case "${choice}" in
            1) workflow_create_lvm ;;
            2) workflow_extend_lvm ;;
            3) show_info ;;
            4)
                print_info "Exiting ${SCRIPT_NAME}."
                log "===== ${SCRIPT_NAME} session ended ====="
                exit 0
                ;;
            *)
                print_warning "Invalid option. Please select 1-4."
                ;;
        esac
    done
}

main "$@"

#!/bin/bash
set -e
set -o pipefail
set -u
export PATH="/usr/local/bin:/usr/local/sbin:$PATH"

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly ESP_NAME="CIDATA"
readonly ESP_SIZE="5g"
readonly LOG_FILE="/tmp/macpro-deploy-$(date +%Y%m%d_%H%M%S).log"

# Global state for cleanup
INTERNAL_DISK=""
APFS_CONTAINER=""
_ESP_CREATED=0
_APFS_RESIZED=0
_APFS_ORIGINAL_SIZE=""
TARGET_DEVICE=""  # For USB deployment

# User selections
DEPLOY_METHOD=""
STORAGE_LAYOUT=""
NETWORK_TYPE=""

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log()   { echo -e "${GREEN}[deploy]${NC} $1" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; }
info()  { echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
die()   { error "$1"; exit 1; }
vlog()  { echo -e "${GREEN}[deploy]${NC} $1" >> "$LOG_FILE"; }

_CLEANUP_DONE=0

# ── Cleanup and Revert Functions ──

revert_changes() {
    echo ""
    error "Reverting deployment changes..."
    local REVERT_ERRORS=0

    if [ "${DEPLOY_METHOD:-}" = "1" ]; then
        # Internal partition method cleanup
        if [ -z "${INTERNAL_DISK:-}" ]; then
            INTERNAL_DISK=$(diskutil list | grep -E 'internal.*physical' | head -1 | grep -oE '/dev/disk[0-9]+' || true)
        fi

        if [ "${_ESP_CREATED:-0}" -eq 1 ] && [ -n "${INTERNAL_DISK:-}" ]; then
            local ESP_REVERT_DEV
            ESP_REVERT_DEV=$(diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "$ESP_NAME" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
            if [ -n "$ESP_REVERT_DEV" ]; then
                log "Removing ESP partition /dev/$ESP_REVERT_DEV..."
                diskutil unmount "/dev/$ESP_REVERT_DEV" 2>/dev/null || true
                diskutil eraseVolume free none "/dev/$ESP_REVERT_DEV" 2>/dev/null || {
                    warn "Could not remove ESP partition /dev/$ESP_REVERT_DEV"
                    REVERT_ERRORS=1
                }
            fi
            _ESP_CREATED=0
        fi

        if [ "${_APFS_RESIZED:-0}" -eq 1 ] && [ -n "${APFS_CONTAINER:-}" ] && [ -n "${_APFS_ORIGINAL_SIZE:-}" ]; then
            log "Restoring APFS container to ${_APFS_ORIGINAL_SIZE}GB..."
            diskutil apfs resizeContainer "$APFS_CONTAINER" "${_APFS_ORIGINAL_SIZE}g" 2>/dev/null || {
                warn "Could not restore APFS container size"
                REVERT_ERRORS=1
            }
            _APFS_RESIZED=0
        fi

        local MACOS_VOLUME="/"
        if [ -n "${APFS_CONTAINER:-}" ]; then
            MACOS_VOLUME=$(diskutil info "$APFS_CONTAINER" 2>/dev/null | grep "Mount Point" | awk '{print $NF}' || echo "/")
        fi
        if [ -d "$MACOS_VOLUME" ] && [ "$MACOS_VOLUME" != "/" ]; then
            bless --mount "$MACOS_VOLUME" --setBoot 2>/dev/null && \
                log "macOS boot device restored" || {
                warn "Could not restore macOS boot device"
                REVERT_ERRORS=1
            }
        else
            bless --mount / --setBoot 2>/dev/null && \
                log "macOS boot device restored (root fallback)" || {
                warn "Could not restore macOS boot device"
                REVERT_ERRORS=1
            }
        fi
    elif [ "${DEPLOY_METHOD:-}" = "2" ] && [ -n "${TARGET_DEVICE:-}" ]; then
        # USB method cleanup - unmount but don't erase USB
        log "Unmounting USB device $TARGET_DEVICE..."
        diskutil unmountDisk "$TARGET_DEVICE" 2>/dev/null || true
    elif [ "${DEPLOY_METHOD:-}" = "4" ]; then
        # VM test cleanup — just power off VM if running
        if command -v VBoxManage >/dev/null 2>&1; then
            VBoxManage controlvm macpro-vmtest poweroff 2>/dev/null || true
        fi
    fi

    if [ "$REVERT_ERRORS" -eq 0 ]; then
        log "Revert complete"
    else
        error "Revert incomplete — some changes may require manual cleanup"
    fi
}

cleanup_on_error() {
    [ "$_CLEANUP_DONE" -eq 1 ] && return
    _CLEANUP_DONE=1
    local EXIT_CODE=$?
    if [ "$EXIT_CODE" -ne 0 ]; then
        revert_changes
        error "Deployment failed (exit code $EXIT_CODE)."
    fi
}

trap cleanup_on_error EXIT
trap 'cleanup_on_error; exit 130' SIGINT
trap 'cleanup_on_error; exit 143' SIGTERM

# ── Menu Functions ──

show_header() {
    clear 2>/dev/null || true
    echo "========================================="
    echo " Mac Pro 2013 Ubuntu Server Deployment"
    echo "========================================="
    echo ""
}

select_deployment_method() {
    show_header
    echo "Select deployment method:"
    echo ""
    echo "  1) Internal partition (autoinstall from ESP)"
    echo "     - Copies Ubuntu installer to CIDATA partition on internal disk"
    echo "     - Requires: monitor or keyboard for boot selection (SIP blocks bless)"
    echo "     - Boots from internal disk, no USB needed after setup"
    echo ""
    echo "  2) USB drive (autoinstall from USB)"
    echo "     - Creates bootable USB with Ubuntu installer"
    echo "     - Requires: USB drive (4GB+), keyboard + monitor for boot selection"
    echo "     - Simpler, no internal disk modification before install"
    echo ""
    echo "  3) Full manual"
    echo "     - Creates bootable USB with standard Ubuntu ISO (no autoinstall)"
    echo "     - Requires: USB drive (4GB+), keyboard + monitor"
    echo "     - You handle all install choices manually"
    echo ""
    echo "  4) VM test (VirtualBox)"
    echo "     - Validates autoinstall flow in a VirtualBox VM on this Mac"
    echo "     - No Mac Pro hardware needed — tests DKMS compilation, driver loading"
    echo "     - Requires: VirtualBox, 4GB+ disk space"
    echo "     - Uses Ethernet (no WiFi HW in VM), single disk (no dual-boot)"
    echo ""

    while true; do
        read -rp "Enter choice [1-4]: " choice
        case "$choice" in
            1|2|3|4)
                DEPLOY_METHOD="$choice"
                break
                ;;
            *)
                echo "Invalid choice. Please enter 1, 2, 3, or 4."
                ;;
        esac
    done
}

select_storage_layout() {
    show_header
    echo "Select storage layout:"
    echo ""
    echo "  1) Dual-boot (preserve macOS)"
    echo "     - Keeps macOS partition intact"
    echo "     - Ubuntu installed in free space alongside macOS"
    echo "     - Can switch between macOS and Ubuntu via GRUB/efibootmgr"
    echo ""
    echo "  2) Full disk (replace macOS)"
    echo "     - Wipes entire disk, Ubuntu only"
    echo "     - Simpler partition layout"
    echo "     - No macOS recovery needed"
    echo ""

    while true; do
        read -rp "Enter choice [1-2]: " choice
        case "$choice" in
            1|2)
                STORAGE_LAYOUT="$choice"
                break
                ;;
            *)
                echo "Invalid choice. Please enter 1 or 2."
                ;;
        esac
    done
}

select_network_type() {
    show_header
    echo "Select network type:"
    echo ""
    echo "  1) WiFi only (Broadcom BCM4360)"
    echo "     - Must compile wl driver in early-commands before network access"
    echo "     - Requires broadcom-sta-dkms packages on installer media"
    echo "     - Slower boot (35+ second driver init)"
    echo ""
    echo "  2) Ethernet available"
    echo "     - Network works immediately via DHCP"
    echo "     - WiFi driver compiled for target system only (late-commands)"
    echo "     - Faster and more reliable during install"
    echo ""

    while true; do
        read -rp "Enter choice [1-2]: " choice
        case "$choice" in
            1|2)
                NETWORK_TYPE="$choice"
                break
                ;;
            *)
                echo "Invalid choice. Please enter 1 or 2."
                ;;
        esac
    done
}

confirm_settings() {
    show_header
    echo "Configuration summary:"
    echo ""

    case "$DEPLOY_METHOD" in
        1) echo "  Deployment method: Internal partition (ESP)" ;;
        2) echo "  Deployment method: USB drive" ;;
        3) echo "  Deployment method: Full manual" ;;
        4) echo "  Deployment method: VM test (VirtualBox)" ;;
    esac

    if [ "$DEPLOY_METHOD" != "3" ] && [ "$DEPLOY_METHOD" != "4" ]; then
        case "$STORAGE_LAYOUT" in
            1) echo "  Storage layout: Dual-boot (preserve macOS)" ;;
            2) echo "  Storage layout: Full disk (replace macOS)" ;;
        esac

        case "$NETWORK_TYPE" in
            1) echo "  Network type: WiFi only (Broadcom BCM4360)" ;;
            2) echo "  Network type: Ethernet available" ;;
        esac
    fi

    echo ""
    read -rp "Proceed with these settings? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log "Deployment cancelled by user"
        exit 0
    fi
}

# ── Helper Functions ──

detect_iso() {
    local iso_path=""

    # Try to find ISO in common locations
    for loc in "$SCRIPT_DIR"/ubuntu-macpro.iso "$SCRIPT_DIR"/prereqs/*.iso "$HOME"/*.iso; do
        if [ -f "$loc" ]; then
            iso_path="$loc"
            break
        fi
    done

    if [ -z "$iso_path" ]; then
        echo "ISO file not found automatically."
        read -rp "Enter path to Ubuntu ISO: " iso_path
    fi

    if [ ! -f "$iso_path" ]; then
        die "ISO not found: $iso_path"
    fi

    # Verify ISO size
    local ISO_SIZE
    ISO_SIZE=$(stat -f%z "$iso_path" 2>/dev/null || echo "0")
    if [ "$ISO_SIZE" -lt 1000000000 ]; then
        die "ISO appears too small ($ISO_SIZE bytes) — may be corrupted"
    fi

    echo "$iso_path"
}

detect_usb_devices() {
    local devices=""
    while IFS= read -r line; do
        if echo "$line" | grep -qE '/dev/disk[0-9]+.*external'; then
            local dev
            dev=$(echo "$line" | grep -oE '/dev/disk[0-9]+' | head -1)
            if [ -n "$dev" ]; then
                local info
                info=$(diskutil info "$dev" 2>/dev/null | grep -E "Device Identifier|Media Name|Total Size" | head -3)
                devices="${devices}${dev}|${info}\n"
            fi
        fi
    done <<< "$(diskutil list 2>/dev/null | grep -E 'external.*physical' || true)"

    echo -e "$devices"
}

select_usb_device() {
    local usb_devices
    usb_devices=$(detect_usb_devices)

    if [ -z "$usb_devices" ] || [ "$usb_devices" = "\n" ]; then
        die "No USB devices detected. Please insert a USB drive and try again."
    fi

    echo "Available USB devices:"
    echo ""

    local i=0
    local device_list=()
    while IFS='|' read -r device info; do
        if [ -n "$device" ]; then
            i=$((i + 1))
            device_list+=("$device")
            echo "  $i) $device"
            echo "     $info"
            echo ""
        fi
    done <<< "$(echo -e "$usb_devices" | grep -v '^$')"

    if [ ${#device_list[@]} -eq 0 ]; then
        die "No USB devices found"
    fi

    while true; do
        read -rp "Select USB device [1-$i]: " choice
        if [ "$choice" -ge 1 ] && [ "$choice" -le "$i" ] 2>/dev/null; then
            TARGET_DEVICE="${device_list[$((choice-1))]}"
            break
        fi
        echo "Invalid choice. Please enter a number between 1 and $i."
    done

    # Get device size
    local device_size
    device_size=$(diskutil info "$TARGET_DEVICE" 2>/dev/null | grep "Total Size" | grep -oE '[0-9]+\.[0-9]+ GB' | head -1 || echo "unknown")
    log "Selected USB device: $TARGET_DEVICE ($device_size)"

    echo ""
    echo "WARNING: All data on $TARGET_DEVICE will be erased!"
    read -rp "Type 'yes' to confirm: " confirm
    if [ "$confirm" != "yes" ]; then
        die "USB device selection cancelled"
    fi
}

# ── Core Deployment Functions ──

preflight_checks() {
    log "Running preflight checks..."

    command -v xorriso >/dev/null 2>&1 || die "xorriso not found. Install with: brew install xorriso"
    command -v sgdisk >/dev/null 2>&1 || die "sgdisk not found. Install with: brew install gptfdisk"
    command -v comm >/dev/null 2>&1 || die "comm not found. Install with: brew install coreutils"
    command -v python3 >/dev/null 2>&1 || die "python3 not found. Install with: brew install python3"

    log "Running on: $(sw_vers -productName) $(sw_vers -productVersion)"

    # Check SIP status
    local SIP_STATUS
    SIP_STATUS=$(csrutil status 2>/dev/null | grep -o 'enabled\|disabled' | head -1 || echo "unknown")
    if [ "$SIP_STATUS" = "enabled" ]; then
        info "SIP is enabled — bless will be attempted but may fail"
    fi

    # Check FileVault
    local FV_STATUS
    FV_STATUS=$(fdesetup status 2>/dev/null | grep -o 'On\|Off' | head -1 || echo "unknown")
    if [ "$FV_STATUS" = "On" ]; then
        warn "FileVault is ON — may interfere with APFS resize"
    fi

    touch "$LOG_FILE" || LOG_FILE="/dev/null"
    log "Deploy log: $LOG_FILE"
}

analyze_disk_layout() {
    log "Analyzing disk layout..."

    local APFS_PARTITION
    local FREE_SPACE

    INTERNAL_DISK=$(diskutil list | grep -E 'internal.*physical' | head -1 | grep -oE '/dev/disk[0-9]+' || true)
    [ -n "$INTERNAL_DISK" ] || die "Cannot identify internal disk"

    log "Internal disk: $INTERNAL_DISK"
    diskutil list "$INTERNAL_DISK"
    echo ""

    # Find APFS container
    APFS_PARTITION=$(diskutil list "$INTERNAL_DISK" | grep -i "APFS" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
    if [ -n "$APFS_PARTITION" ]; then
        APFS_CONTAINER=$(diskutil info "$APFS_PARTITION" 2>/dev/null | grep -i "container" | grep -oE 'disk[0-9]+' | head -1 || true)
    fi
    if [ -z "$APFS_CONTAINER" ]; then
        APFS_CONTAINER=$(diskutil list | grep -i "APFS" | grep -oE 'disk[0-9]+' | head -1 || true)
    fi
    if [ -n "$APFS_CONTAINER" ]; then
        FREE_SPACE=$(diskutil apfs list 2>/dev/null | grep -A5 "Capacity" | grep "Available" | grep -oE '[0-9]+.*B' | head -1 || true)
        log "APFS partition: /dev/${APFS_PARTITION:-unknown}"
        log "APFS container: /dev/$APFS_CONTAINER"
        log "Free space: ${FREE_SPACE:-unknown}"
    fi
    echo ""
}

shrink_apfs_if_needed() {
    if [ "${STORAGE_LAYOUT:-}" != "1" ]; then
        log "Full disk mode selected — skipping APFS resize"
        return 0
    fi

    log "Checking APFS container size..."

    local CURRENT_SIZE
    local APFS_PARTITION
    local APFS_CONTAINER
    local FREE_SPACE
    local _APFS_ORIGINAL_SIZE
    local EXISTING_FREE_GB
    local USED_GB
    local TARGET_MACOS_GB
    local CURRENT_CONTAINER_GB
    local SNAPSHOTS
    local SNAP_UUID

    CURRENT_SIZE=$(diskutil info "$APFS_CONTAINER" 2>/dev/null | grep "Disk Size" | grep -oE '[0-9]+(\.[0-9]+)? GB' || true)
    _APFS_ORIGINAL_SIZE=$(echo "$CURRENT_SIZE" | grep -oE '[0-9]+(\.[0-9]+)?' || true)
    log "Current APFS size: ${CURRENT_SIZE:-unknown}"

    EXISTING_FREE_GB=$(diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "(free" | grep -oE '[0-9]+(\.[0-9]+)? GB' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || true)
    if [ -n "$EXISTING_FREE_GB" ] && echo "$EXISTING_FREE_GB" | awk '{exit !($1 >= 5)}'; then
        log "Free space already ${EXISTING_FREE_GB}GB — skipping APFS resize"
        return 0
    fi

    local MIN_MACOS_GB=50

    log "Purging purgeable APFS space..."
    tmutil thinlocalsnapshots / 999999999999 2>/dev/null || true

    USED_GB=$(diskutil apfs list "$APFS_CONTAINER" 2>/dev/null | grep "Capacity In Use By Volumes" | grep -oE '[0-9]+(\.[0-9]+)? GB' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || true)
    if [ -z "$USED_GB" ]; then
        USED_GB=$(diskutil apfs list "$APFS_CONTAINER" 2>/dev/null | grep "Capacity In Use By Volumes" | grep -oE '[0-9]+ B' | head -1 | awk '{printf "%.1f", $1/1024/1024/1024}' || true)
    fi

    if [ -n "$USED_GB" ]; then
        TARGET_MACOS_GB=$(echo "$USED_GB" | awk -v min="$MIN_MACOS_GB" -v margin=10 '{target=int($1)+margin+1; if(target<min) target=min; print target}')
        log "APFS in use: ${USED_GB}GB → shrinking to ${TARGET_MACOS_GB}GB (10GB margin)"
    else
        TARGET_MACOS_GB=200
        warn "Could not determine APFS usage — defaulting to ${TARGET_MACOS_GB}GB for macOS"
    fi

    CURRENT_CONTAINER_GB=$(diskutil info "$APFS_CONTAINER" 2>/dev/null | grep "Disk Size" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
    if [ -n "$CURRENT_CONTAINER_GB" ] && echo "$CURRENT_CONTAINER_GB $TARGET_MACOS_GB" | awk '{exit !($1 <= $2)}'; then
        log "APFS already at ${CURRENT_CONTAINER_GB}GB — no resize needed"
        return 0
    fi

    # Delete snapshots first
    log "Checking APFS snapshots..."
    SNAPSHOTS=$(diskutil apfs listSnapshots "$APFS_CONTAINER" 2>/dev/null | grep "Snapshot.*UUID" || true)
    if [ -n "$SNAPSHOTS" ]; then
        warn "APFS snapshots found — auto-deleting:"
        echo "$SNAPSHOTS"

        while IFS= read -r line; do
            SNAP_UUID=$(echo "$line" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' || true)
            if [ -n "$SNAP_UUID" ]; then
                log "Deleting snapshot $SNAP_UUID..."
                diskutil apfs deleteSnapshot "$APFS_CONTAINER" -uuid "$SNAP_UUID" || warn "Failed to delete snapshot $SNAP_UUID"
            fi
        done <<< "$SNAPSHOTS"

        tmutil thinlocalsnapshots / 999999999999 2>/dev/null || true
    fi

    diskutil apfs resizeContainer "$APFS_CONTAINER" "${TARGET_MACOS_GB}g" || die "APFS resize failed"
    _APFS_RESIZED=1
    log "APFS container resized to ${TARGET_MACOS_GB}GB"
}

create_esp_partition() {
    log "Creating ESP partition for Ubuntu installer..."

    # Remove leftover CIDATA ESP from a previous failed run
    local EXISTING_ESP
    EXISTING_ESP=$(diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "$ESP_NAME" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
    if [ -n "$EXISTING_ESP" ]; then
        log "Removing existing $ESP_NAME partition /dev/$EXISTING_ESP..."
        diskutil unmount "/dev/$EXISTING_ESP" 2>/dev/null || true
        diskutil eraseVolume free none "/dev/$EXISTING_ESP" 2>/dev/null || warn "Could not remove existing ESP"
        sleep 1
    fi

    local BEFORE_PARTS AFTER_PARTS ESP_DEVICE ESP_MOUNT
    BEFORE_PARTS=$(diskutil list "$INTERNAL_DISK" | grep -oE 'disk[0-9]+s[0-9]+' | sort)
    diskutil addPartition "$INTERNAL_DISK" %C12A7328-F81F-11D2-BA4B-00A0C93EC93B% %noformat% "$ESP_SIZE" || \
        die "Failed to create ESP partition with EFI System Partition type"
    _ESP_CREATED=1
    sleep 2
    AFTER_PARTS=$(diskutil list "$INTERNAL_DISK" | grep -oE 'disk[0-9]+s[0-9]+' | sort)
    ESP_DEVICE=$(comm -13 <(echo "$BEFORE_PARTS") <(echo "$AFTER_PARTS") | head -1)
    [ -n "$ESP_DEVICE" ] || die "Cannot identify newly created ESP partition"

    log "ESP partition candidate: /dev/$ESP_DEVICE"

    # Format as FAT32 with newfs_msdos
    newfs_msdos -F 32 -v "$ESP_NAME" "/dev/$ESP_DEVICE" || die "Failed to format ESP as FAT32"
    sleep 1

    # Mount the freshly formatted ESP
    diskutil mount "/dev/$ESP_DEVICE" 2>/dev/null || true
    ESP_MOUNT="/Volumes/$ESP_NAME"
    if [ ! -d "$ESP_MOUNT" ]; then
        ESP_MOUNT=$(diskutil info "/dev/$ESP_DEVICE" 2>/dev/null | grep "Mount Point" | awk '{$1=$2=""; print substr($0,3)}' | sed 's/^[[:space:]]*//' || true)
    fi
    [ -d "$ESP_MOUNT" ] || die "ESP not mounted after format"

    echo "$ESP_MOUNT"
}

extract_iso_to_esp() {
    local ISO_PATH="$1"
    local ESP_MOUNT="$2"

    log "Extracting ISO contents to ESP..."

    local ESP_AVAIL ISO_TOTAL
    ESP_AVAIL=$(df -m "$ESP_MOUNT" | tail -1 | awk '{print $4}')
    ISO_TOTAL=$(du -sm "$ISO_PATH" 2>/dev/null | cut -f1 || echo "0")
    if [ -n "$ESP_AVAIL" ] && [ "$ESP_AVAIL" -gt 0 ] && [ -n "$ISO_TOTAL" ] && [ "$ISO_TOTAL" -gt 0 ]; then
        local REQUIRED_MIN=$((ISO_TOTAL + ISO_TOTAL / 10))
        if [ "$ESP_AVAIL" -lt "$REQUIRED_MIN" ]; then
            die "ESP too small: ${ESP_AVAIL}MB available, ${REQUIRED_MIN}MB needed"
        fi
        log "Space check: ${ESP_AVAIL}MB available, ${REQUIRED_MIN}MB needed"
    fi

    log "Extracting ISO to ESP via xorriso (this may take a minute)..."
    xorriso -osirrox on -indev "$ISO_PATH" \
        -extract / "$ESP_MOUNT" 2>/dev/null || \
        die "Failed to extract ISO contents"

    rm -rf "$ESP_MOUNT/pool" "$ESP_MOUNT/dists" "$ESP_MOUNT/.disk" "$ESP_MOUNT/boot/grub" 2>/dev/null || true

    # Verify required files
    [ -f "$ESP_MOUNT/EFI/boot/bootx64.efi" ] || [ -f "$ESP_MOUNT/EFI/boot/BOOTX64.EFI" ] || die "BOOTX64.EFI missing"
    [ -f "$ESP_MOUNT/casper/vmlinuz" ] || die "casper/vmlinuz missing"
    [ -f "$ESP_MOUNT/casper/initrd" ] || die "casper/initrd missing"
    if ! ls "$ESP_MOUNT/casper/"*.squashfs 1>/dev/null 2>&1; then
        die "No .squashfs files in casper/"
    fi

    echo "$ESP_MOUNT"
}

generate_autoinstall() {
    local OUTPUT_PATH="$1"
    local STORAGE_TYPE="$2"  # dualboot or fulldisk
    local NETWORK_TYPE="$3"  # wifi or ethernet

    log "Generating autoinstall configuration..."
    log "  Storage: $STORAGE_TYPE, Network: $NETWORK_TYPE"

    # Start with base template
    local TEMPLATE_PATH="$SCRIPT_DIR/autoinstall.yaml"
    if [ ! -f "$TEMPLATE_PATH" ]; then
        die "Template not found: $TEMPLATE_PATH"
    fi

    cp "$TEMPLATE_PATH" "$OUTPUT_PATH"

    # Modify based on selections
    local FULL_DISK_STORAGE NETWORK_CONFIG SIMPLE_EARLY
    if [ "$STORAGE_TYPE" = "fulldisk" ]; then
        # Replace storage section with full-disk config
        FULL_DISK_STORAGE='  storage:
    config:
    - type: disk
      id: root-disk
      path: /dev/sda
      ptable: gpt
      wipe: superblock-recursive
    - type: partition
      id: efi-partition
      device: root-disk
      size: 512M
      flag: boot
      partition_type: c12a7328-f81f-11d2-ba4b-00a0c93ec93b
      grub_device: true
      number: 1
    - type: format
      id: efi-format
      volume: efi-partition
      fstype: fat32
    - type: mount
      id: efi-mount
      device: efi-format
      path: /boot/efi
    - type: partition
      id: boot-partition
      device: root-disk
      size: 1G
      number: 2
    - type: format
      id: boot-format
      volume: boot-partition
      fstype: ext4
    - type: mount
      id: boot-mount
      device: boot-format
      path: /boot
    - type: partition
      id: root-partition
      device: root-disk
      size: -1
      number: 3
    - type: format
      id: root-format
      volume: root-partition
      fstype: ext4
    - type: mount
      id: root-mount
      device: root-format
      path: /'

        # Use sed to replace storage section
        python3 -c "
import re
with open('$OUTPUT_PATH', 'r') as f:
    content = f.read()

pattern = r'  storage:\n    config:.*?\n(?=  [a-z]|\Z)'
content = re.sub(pattern, '''$FULL_DISK_STORAGE''', content, flags=re.DOTALL)

with open('$OUTPUT_PATH', 'w') as f:
    f.write(content)
" || die "Failed to modify storage section"
    fi

    if [ "$NETWORK_TYPE" = "ethernet" ]; then
        # Add network section with ethernet config
        local NETWORK_CONFIG
        NETWORK_CONFIG='  network:
    version: 2
    ethernets:
      primary:
        match:
          name: "en*"
        dhcp4: true
        optional: true
'

        # Insert network section before early-commands
        python3 -c "
with open('$OUTPUT_PATH', 'r') as f:
    content = f.read()

if '  network:' not in content:
    content = content.replace('  early-commands:', '''$NETWORK_CONFIG  early-commands:''')

with open('$OUTPUT_PATH', 'w') as f:
    f.write(content)
" || die "Failed to add network section"

        # For ethernet, replace early-commands with minimal version (no DKMS)
        local SIMPLE_EARLY
        SIMPLE_EARLY='  early-commands:
    - |
      set -x
      LOG="/run/macpro.log"
      WHURL="http://192.168.1.115:8080/webhook"
      wh() { curl -s -X POST "\$WHURL" -H "Content-Type: application/json" -d "\$1" > /dev/null 2>&1 || true; }
      log() { echo "[early] \$1" >> "\$LOG"; }

      echo "=== MAC PRO 2013 AUTOINSTALL (Ethernet mode) ===" > "\$LOG"
      echo "Kernel: \$(uname -r)" >> "\$LOG"
      wh '"'"'{"progress":5,"stage":"prep-init","status":"running","message":"Autoinstall started — Ethernet mode, network ready"}'"'"'

      # Start SSH server for remote debugging (ethernet network already up)
      wh '"'"'{"progress":20,"stage":"prep-ssh","status":"starting","message":"Starting SSH server for remote debugging"}'"'"'
      log "Starting SSH server..."
      dpkg --force-depends -i /cdrom/pool/restricted/o/openssh/openssh-server_*.deb 2>>"\$LOG" || true
      if [ -f /usr/sbin/sshd ]; then
        useradd -m -s /bin/bash ubuntu 2>/dev/null || true
        echo "ubuntu:ubuntu" | chpasswd 2>/dev/null || true
        mkdir -p /home/ubuntu/.ssh 2>/dev/null || true
        : > /home/ubuntu/.ssh/authorized_keys 2>/dev/null || true
        chmod 700 /home/ubuntu/.ssh 2>/dev/null || true
        chmod 600 /home/ubuntu/.ssh/authorized_keys 2>/dev/null || true
        chown -R ubuntu:ubuntu /home/ubuntu/.ssh 2>/dev/null || true
        mkdir -p /run/sshd
        /usr/sbin/sshd -D -e &
        log "SSH server started"
        wh '"'"'{"progress":25,"stage":"prep-ssh","status":"ready","message":"SSH server ready — early-commands complete"}'"'"'
      fi
      set +x'

        python3 -c "
import re
with open('$OUTPUT_PATH', 'r') as f:
    content = f.read()

# Replace early-commands section
pattern = r'  early-commands:.*?\n(?=  [a-z]|\Z)'
content = re.sub(pattern, '''$SIMPLE_EARLY''', content, flags=re.DOTALL)

with open('$OUTPUT_PATH', 'w') as f:
    f.write(content)
" || die "Failed to simplify early-commands"
    fi

    log "Autoinstall configuration generated: $OUTPUT_PATH"
}

generate_dualboot_storage() {
    local TEMPLATE_PATH="$1"
    local OUTPUT_PATH="$2"
    local DISK_DEV="$3"

    log "Generating dual-boot storage config..."

    python3 - "$TEMPLATE_PATH" "$OUTPUT_PATH" "$DISK_DEV" << 'PYEOF' || die "Failed to generate dual-boot storage config"
import sys, subprocess, re, os

template_path = sys.argv[1]
output_path = sys.argv[2]
disk_dev = sys.argv[3]

with open(template_path) as f:
    content = f.read()

# Read GPT partition table using sgdisk
try:
    result = subprocess.run(['sgdisk', '-p', disk_dev], capture_output=True, text=True)
    part_lines = result.stdout.strip().split('\n')
except Exception as e:
    print(f"WARNING: Could not read partition table: {e}", file=sys.stderr)
    with open(output_path, 'w') as f:
        f.write(content)
    sys.exit(0)

# Parse existing partitions
preserved_yaml = ""
max_part_num = 0
part_count = 0

for line in part_lines:
    fields = line.split()
    if len(fields) < 7:
        continue
    try:
        part_num = int(fields[0])
        max_part_num = max(max_part_num, part_num)
    except (ValueError, IndexError):
        continue

    try:
        # Get detailed partition info
        info = subprocess.run(['sgdisk', '-i', str(part_num), disk_dev],
                             capture_output=True, text=True)
        info_text = info.stdout

        part_type_guid = ''
        part_uuid = ''
        first_sector = None
        last_sector = None

        for info_line in info_text.split('\n'):
            if 'Partition type GUID code:' in info_line or 'Partition type code:' in info_line:
                guid_match = re.search(r'([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})', info_line)
                if guid_match:
                    part_type_guid = guid_match.group(1).lower()
            elif 'Partition unique GUID:' in info_line or 'Partition GUID:' in info_line:
                guid_match = re.search(r'([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})', info_line)
                if guid_match:
                    part_uuid = guid_match.group(1).lower()
            elif 'First sector:' in info_line:
                sector_match = re.search(r'(\d+)', info_line.split(':')[-1])
                if sector_match:
                    first_sector = int(sector_match.group(1))
            elif 'Last sector:' in info_line:
                sector_match = re.search(r'(\d+)', info_line.split(':')[-1])
                if sector_match:
                    last_sector = int(sector_match.group(1))

        if first_sector is None or last_sector is None or not part_type_guid or not part_uuid:
            continue

        offset_bytes = first_sector * 512
        size_bytes = (last_sector - first_sector + 1) * 512
        part_path = f"/dev/sda{part_num}"

        if size_bytes < 1048576:
            continue

        preserved_yaml += f"""    - device: root-disk
      size: {size_bytes}
      number: {part_num}
      preserve: true
      grub_device: false
      offset: {offset_bytes}
      partition_type: {part_type_guid}
      path: {part_path}
      uuid: {part_uuid}
      id: preserved-partition-{part_num}
      type: partition
"""
        part_count += 1
    except Exception as e:
        print(f"WARNING: Could not parse partition {part_num}: {e}", file=sys.stderr)
        continue

if not preserved_yaml:
    print("WARNING: No preserved partitions found — copying template as-is", file=sys.stderr)
    with open(output_path, 'w') as f:
        f.write(content)
    sys.exit(0)

next_num = max_part_num + 1

# Build the new storage section
new_storage = f"""  storage:
    config:
    - type: disk
      id: root-disk
      path: /dev/sda
      ptable: gpt
      preserve: true
      wipe: superblock
{preserved_yaml}    - type: partition
      id: efi-partition
      device: root-disk
      size: 512M
      flag: boot
      partition_type: c12a7328-f81f-11d2-ba4b-00a0c93ec93b
      grub_device: true
      number: {next_num}
    - type: format
      id: efi-format
      volume: efi-partition
      fstype: fat32
    - type: mount
      id: efi-mount
      device: efi-format
      path: /boot/efi
    - type: partition
      id: boot-partition
      device: root-disk
      size: 1G
      number: {next_num + 1}
    - type: format
      id: boot-format
      volume: boot-partition
      fstype: ext4
    - type: mount
      id: boot-mount
      device: boot-format
      path: /boot
    - type: partition
      id: root-partition
      device: root-disk
      size: -1
      number: {next_num + 2}
    - type: format
      id: root-format
      volume: root-partition
      fstype: ext4
    - type: mount
      id: root-mount
      device: root-format
      path: /
"""

# Replace the storage section in the template
pattern = r'  storage:\n    config:.*?(?=\n  [a-z]|\Z)'
replacement = new_storage.rstrip()
new_content = re.sub(pattern, replacement, content, count=1, flags=re.DOTALL)

if new_content == content:
    print("WARNING: Storage section not found in template — copying as-is", file=sys.stderr)
    with open(output_path, 'w') as f:
        f.write(content)
else:
    with open(output_path, 'w') as f:
        f.write(new_content)
    print(f"  Preserving {part_count} existing partitions (macOS + installer ESP)")
PYEOF
}

write_grub_config() {
    local ESP_MOUNT="$1"

    log "Writing GRUB configuration..."

    cat > "$ESP_MOUNT/EFI/boot/grub.cfg" << 'GRUBEOF'
set default=0
set timeout=3

menuentry "Ubuntu Server 24.04 Autoinstall (Mac Pro 2013)" {
    set gfxpayload=keep
    linux /casper/vmlinuz autoinstall ds=nocloud nomodeset amdgpu.si.modeset=0 ---
    initrd /casper/initrd
}

menuentry "Ubuntu Server 24.04 (Manual Install)" {
    set gfxpayload=keep
    linux /casper/vmlinuz nomodeset amdgpu.si.modeset=0 ---
    initrd /casper/initrd
}
GRUBEOF

    mkdir -p "$ESP_MOUNT/boot/grub"
    cp "$ESP_MOUNT/EFI/boot/grub.cfg" "$ESP_MOUNT/boot/grub/grub.cfg"
}

verify_esp_contents() {
    local ESP_MOUNT="$1"

    log "Verifying ESP contents..."

    local REQUIRED_FILES=(
        "EFI/boot/bootx64.efi"
        "EFI/boot/grub.cfg"
        "casper/vmlinuz"
        "casper/initrd"
        "autoinstall.yaml"
        "cidata/user-data"
        "cidata/meta-data"
    )

    local ALL_OK=true
    for f in "${REQUIRED_FILES[@]}"; do
        if [ -f "$ESP_MOUNT/$f" ] || [ -f "$ESP_MOUNT/$(echo "$f" | tr '[:lower:]' '[:upper:]')" ]; then
            log "  ✓ $f"
        else
            warn "  ✗ $f (not found)"
            ALL_OK=false
        fi
    done

    if ls "$ESP_MOUNT/macpro-pkgs/"broadcom-sta-dkms_*.deb 1>/dev/null 2>&1; then
        log "  ✓ macpro-pkgs/broadcom-sta-dkms_*.deb"
    else
        warn "  ✗ macpro-pkgs/broadcom-sta-dkms (not found)"
        ALL_OK=false
    fi

    if [ -f "$ESP_MOUNT/macpro-pkgs/dkms-patches/series" ]; then
        local PATCH_COUNT
        PATCH_COUNT=$(ls "$ESP_MOUNT/macpro-pkgs/dkms-patches/"*.patch 2>/dev/null | wc -l | tr -d ' ')
        log "  ✓ macpro-pkgs/dkms-patches/ ($PATCH_COUNT patches)"
    else
        warn "  ✗ macpro-pkgs/dkms-patches/ (missing)"
        ALL_OK=false
    fi

    if [ "$ALL_OK" = "false" ]; then
        die "Critical boot files missing from ESP"
    fi
}

attempt_bless() {
    local ESP_MOUNT="$1"
    local ESP_DEVICE="$2"

    log "Attempting to set boot device..."

    local BLESS_OK=0

    # Method 1: systemsetup
    if command -v systemsetup >/dev/null 2>&1; then
        log "Attempting systemsetup..."
        local SYSTEMSETUP_OUT
        SYSTEMSETUP_OUT=$(systemsetup -setstartupdisk "$ESP_MOUNT" 2>&1) || true
        if ! echo "$SYSTEMSETUP_OUT" | grep -qi "not allowed\|error\|failed"; then
            log "systemsetup succeeded"
            BLESS_OK=1
        fi
    fi

    # Method 2: bless --nextonly
    if [ "$BLESS_OK" -eq 0 ]; then
        log "Attempting bless --nextonly..."
        local BLESS_OUT
        BLESS_OUT=$(bless --verbose --setBoot --mount "$ESP_MOUNT" --file "$ESP_MOUNT/EFI/boot/bootx64.efi" --nextonly 2>&1) || true
        if ! echo "$BLESS_OUT" | grep -qi "error\|failed\|0xe0"; then
            BLESS_OK=1
        fi
    fi

    # Method 3: bless --device
    if [ "$BLESS_OK" -eq 0 ]; then
        log "Attempting bless --device..."
        local BLESS_OUT
        BLESS_OUT=$(bless --verbose --device "/dev/$ESP_DEVICE" --setBoot --nextonly 2>&1) || true
        if ! echo "$BLESS_OUT" | grep -qi "error\|failed\|0xe0"; then
            BLESS_OK=1
        fi
    fi

    echo "$BLESS_OK"
}

# ── Deployment Methods ──

deploy_internal_partition() {
    log "Starting internal partition deployment..."

    local ISO_PATH
    ISO_PATH=$(detect_iso)
    log "Using ISO: $ISO_PATH"

    preflight_checks
    analyze_disk_layout
    shrink_apfs_if_needed

    local ESP_MOUNT
    ESP_MOUNT=$(create_esp_partition)
    log "ESP mounted at: $ESP_MOUNT"

    extract_iso_to_esp "$ISO_PATH" "$ESP_MOUNT"

    # Copy driver packages if not present
    if ! ls "$ESP_MOUNT/macpro-pkgs/"*.deb 1>/dev/null 2>&1; then
        log "Copying driver packages to ESP..."
        mkdir -p "$ESP_MOUNT/macpro-pkgs"
        cp "$SCRIPT_DIR/packages/"*.deb "$ESP_MOUNT/macpro-pkgs/" 2>/dev/null || warn "Some packages may be missing"
    fi

    if [ -d "$SCRIPT_DIR/packages/dkms-patches" ] && [ ! -d "$ESP_MOUNT/macpro-pkgs/dkms-patches" ]; then
        mkdir -p "$ESP_MOUNT/macpro-pkgs/dkms-patches"
        cp "$SCRIPT_DIR/packages/dkms-patches/"* "$ESP_MOUNT/macpro-pkgs/dkms-patches/" 2>/dev/null || true
    fi

    # Generate autoinstall.yaml based on selections
    local STORAGE_TYPE_ARG="dualboot"
    local NETWORK_TYPE_ARG="wifi"
    [ "$STORAGE_LAYOUT" = "2" ] && STORAGE_TYPE_ARG="fulldisk"
    [ "$NETWORK_TYPE" = "2" ] && NETWORK_TYPE_ARG="ethernet"
    generate_autoinstall "$ESP_MOUNT/autoinstall.yaml" "$STORAGE_TYPE_ARG" "$NETWORK_TYPE_ARG"

    # Create cidata structure
    log "Creating cidata structure..."
    mkdir -p "$ESP_MOUNT/cidata"

    if [ "$STORAGE_LAYOUT" = "1" ]; then
        # Dual-boot: generate dynamic storage config
        generate_dualboot_storage "$ESP_MOUNT/autoinstall.yaml" "$ESP_MOUNT/cidata/user-data" "$INTERNAL_DISK"
    else
        # Full-disk: use template as-is
        cp "$ESP_MOUNT/autoinstall.yaml" "$ESP_MOUNT/cidata/user-data"
    fi

    # Validate preserve entries for dual-boot
    if [ "$STORAGE_LAYOUT" = "1" ]; then
        if ! grep -q 'preserve: true' "$ESP_MOUNT/cidata/user-data" 2>/dev/null; then
            die "Generated user-data lacks preserve:true entries — macOS partitions would be wiped"
        fi
        local PRESERVE_COUNT
        PRESERVE_COUNT=$(grep -c 'preserve: true' "$ESP_MOUNT/cidata/user-data" 2>/dev/null || echo "0")
        log "Preserve entries in user-data: $PRESERVE_COUNT"
    fi

    [ -f "$ESP_MOUNT/cidata/meta-data" ] || echo "instance-id: macpro-linux-i1" > "$ESP_MOUNT/cidata/meta-data"
    [ -f "$ESP_MOUNT/cidata/vendor-data" ] || touch "$ESP_MOUNT/cidata/vendor-data"

    write_grub_config "$ESP_MOUNT"
    verify_esp_contents "$ESP_MOUNT"

    # Attempt bless
    local ESP_DEVICE
    ESP_DEVICE=$(diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "$ESP_NAME" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
    local BLESS_OK
    BLESS_OK=$(attempt_bless "$ESP_MOUNT" "$ESP_DEVICE")

    if [ "$BLESS_OK" -eq 0 ]; then
        warn "All automated boot device methods failed (SIP blocks NVRAM writes)"
        show_blind_boot_instructions
    else
        show_success_instructions
    fi
}

deploy_usb() {
    log "Starting USB deployment..."

    local ISO_PATH
    ISO_PATH=$(detect_iso)
    log "Using ISO: $ISO_PATH"

    select_usb_device

    if ! diskutil info "$TARGET_DEVICE" 2>/dev/null | grep -qi "removable\|external\|usb"; then
        echo ""
        warn "WARNING: $TARGET_DEVICE does not appear to be a USB/removable device!"
        warn "Writing to an internal device could DESTROY all data on it."
        echo ""
        read -rp "Type 'I UNDERSTAND THE RISK' to continue, or anything else to cancel: " confirm_usb
        if [ "$confirm_usb" != "I UNDERSTAND THE RISK" ]; then
            die "Deployment cancelled — target device does not appear to be removable"
        fi
    fi

    log "Preparing USB device $TARGET_DEVICE..."

    # Unmount the device
    diskutil unmountDisk "$TARGET_DEVICE" 2>/dev/null || true
    sleep 2

    # Create GPT partition table and FAT32 partition
    log "Creating FAT32 partition on USB..."
    diskutil partitionDisk "$TARGET_DEVICE" GPT FAT32 "CIDATA" 100% 2>/dev/null || \
        die "Failed to partition USB device"

    # Find the new partition
    sleep 2
    local USB_PARTITION
    USB_PARTITION=$(diskutil list "$TARGET_DEVICE" | grep "CIDATA" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
    [ -n "$USB_PARTITION" ] || die "Cannot identify USB partition"

    # Mount it
    diskutil mount "/dev/$USB_PARTITION" 2>/dev/null || true
    local USB_MOUNT="/Volumes/CIDATA"
    [ -d "$USB_MOUNT" ] || die "USB not mounted after format"

    log "USB mounted at: $USB_MOUNT"

    # Extract ISO contents
    extract_iso_to_esp "$ISO_PATH" "$USB_MOUNT"

    # Copy driver packages
    if ! ls "$USB_MOUNT/macpro-pkgs/"*.deb 1>/dev/null 2>&1; then
        log "Copying driver packages to USB..."
        mkdir -p "$USB_MOUNT/macpro-pkgs"
        cp "$SCRIPT_DIR/packages/"*.deb "$USB_MOUNT/macpro-pkgs/" 2>/dev/null || warn "Some packages may be missing"
    fi

    if [ -d "$SCRIPT_DIR/packages/dkms-patches" ] && [ ! -d "$USB_MOUNT/macpro-pkgs/dkms-patches" ]; then
        mkdir -p "$USB_MOUNT/macpro-pkgs/dkms-patches"
        cp "$SCRIPT_DIR/packages/dkms-patches/"* "$USB_MOUNT/macpro-pkgs/dkms-patches/" 2>/dev/null || true
    fi

    # Generate autoinstall.yaml
    local STORAGE_TYPE_ARG="dualboot"
    local NETWORK_TYPE_ARG="wifi"
    [ "$STORAGE_LAYOUT" = "2" ] && STORAGE_TYPE_ARG="fulldisk"
    [ "$NETWORK_TYPE" = "2" ] && NETWORK_TYPE_ARG="ethernet"
    generate_autoinstall "$USB_MOUNT/autoinstall.yaml" "$STORAGE_TYPE_ARG" "$NETWORK_TYPE_ARG"

    # Create cidata structure
    log "Creating cidata structure..."
    mkdir -p "$USB_MOUNT/cidata"

    if [ "$STORAGE_LAYOUT" = "1" ]; then
        # For USB, we can't easily run Python against the Mac's disk from the USB
        # So we'll use the static autoinstall.yaml and note that user may need to
        # manually preserve partitions or use the full-disk option
        log "Note: For dual-boot from USB, ensure you have free space on the target disk"
        cp "$USB_MOUNT/autoinstall.yaml" "$USB_MOUNT/cidata/user-data"
    else
        cp "$USB_MOUNT/autoinstall.yaml" "$USB_MOUNT/cidata/user-data"
    fi

    [ -f "$USB_MOUNT/cidata/meta-data" ] || echo "instance-id: macpro-linux-i1" > "$USB_MOUNT/cidata/meta-data"
    [ -f "$USB_MOUNT/cidata/vendor-data" ] || touch "$USB_MOUNT/cidata/vendor-data"

    write_grub_config "$USB_MOUNT"
    verify_esp_contents "$USB_MOUNT"

    # Unmount USB
    diskutil unmountDisk "$TARGET_DEVICE" 2>/dev/null || true

    show_usb_instructions
}

deploy_vm_test() {
    log "Starting VM test deployment..."

    if ! command -v VBoxManage >/dev/null 2>&1; then
        die "VirtualBox not found. Install from https://www.virtualbox.org/ or: brew install --cask virtualbox"
    fi

    local BASE_ISO
    BASE_ISO=""
    for loc in "$SCRIPT_DIR"/prereqs/ubuntu-24.04*.iso "$HOME"/Downloads/ubuntu-24.04*.iso; do
        if [ -f "$loc" ]; then
            BASE_ISO="$loc"
            break
        fi
    done
    if [ -z "$BASE_ISO" ]; then
        die "Stock Ubuntu Server ISO not found in prereqs/. Download from https://ubuntu.com/download/server"
    fi
    log "Using base ISO: $BASE_ISO"

    local VM_DIR="$SCRIPT_DIR/vm-test"
    local VM_ISO="$VM_DIR/ubuntu-vmtest.iso"

    if [ ! -f "$VM_ISO" ]; then
        log "Building VM test ISO..."
        sudo "$VM_DIR/build-iso-vm.sh" || die "VM ISO build failed"
    else
        log "VM test ISO already exists: $VM_ISO"
        read -rp "Rebuild? (y/N): " rebuild
        if [ "$rebuild" = "y" ] || [ "$rebuild" = "Y" ]; then
            sudo "$VM_DIR/build-iso-vm.sh" || die "VM ISO build failed"
        fi
    fi

    [ -f "$VM_ISO" ] || die "VM test ISO not found after build"

    local VM_NAME="macpro-vmtest"
    if VBoxManage list vms 2>/dev/null | grep -q "\"$VM_NAME\""; then
        log "VM '$VM_NAME' already exists"
        read -rp "Recreate? (y/N): " recreate
        if [ "$recreate" = "y" ] || [ "$recreate" = "Y" ]; then
            "$VM_DIR/create-vm.sh" --force || die "VM creation failed"
        fi
    else
        log "Creating VirtualBox VM..."
        "$VM_DIR/create-vm.sh" || die "VM creation failed"
    fi

    if ! lsof -i :8080 >/dev/null 2>&1; then
        log "Starting monitoring server..."
        (cd "$SCRIPT_DIR/macpro-monitor" && ./start.sh) || warn "Monitor start failed (non-critical)"
        sleep 2
    fi

    echo ""
    log "VM test environment ready!"
    echo ""
    echo "  Next steps:"
    echo "    1. Monitor: open http://localhost:8080 in a browser"
    echo "    2. Run test: cd vm-test && ./test-vm.sh"
    echo "    3. SSH into VM (when ready): ssh -p 2222 teja@localhost"
    echo "    4. Serial console log: tail -f /tmp/vmtest-serial.log"
    echo "    5. Stop VM: cd vm-test && ./test-vm.sh stop"
    echo "    6. Grab logs: cd vm-test && ./test-vm.sh logs"
    echo ""
}

deploy_manual() {
    log "Starting full manual USB deployment..."

    show_header
    echo "Full Manual Mode"
    echo ""
    echo "This will create a bootable USB with the standard Ubuntu ISO."
    echo "You'll handle all installation choices manually (partitioning, network, etc.)"
    echo ""

    # Look for standard Ubuntu ISO
    local ISO_PATH=""
    for loc in "$SCRIPT_DIR"/prereqs/ubuntu-24.04*.iso "$SCRIPT_DIR"/prereqs/*.iso "$HOME"/Downloads/ubuntu-24.04*.iso; do
        if [ -f "$loc" ]; then
            ISO_PATH="$loc"
            break
        fi
    done

    if [ -z "$ISO_PATH" ]; then
        read -rp "Enter path to standard Ubuntu Server ISO: " ISO_PATH
    fi

    if [ ! -f "$ISO_PATH" ]; then
        die "ISO not found: $ISO_PATH"
    fi

    log "Using ISO: $ISO_PATH"

    select_usb_device

    if ! diskutil info "$TARGET_DEVICE" 2>/dev/null | grep -qi "removable\|external\|usb"; then
        echo ""
        warn "WARNING: $TARGET_DEVICE does not appear to be a USB/removable device!"
        warn "Writing to an internal device could DESTROY all data on it."
        echo ""
        read -rp "Type 'I UNDERSTAND THE RISK' to continue, or anything else to cancel: " confirm
        if [ "$confirm" != "I UNDERSTAND THE RISK" ]; then
            die "Deployment cancelled — target device does not appear to be removable"
        fi
    fi

    echo ""
    echo "WARNING: This will ERASE all data on $TARGET_DEVICE"
    echo "The ISO will be written directly to the device (dd style)"
    read -rp "Type 'yes' to proceed: " confirm
    if [ "$confirm" != "yes" ]; then
        die "Manual deployment cancelled"
    fi

    # Unmount and write ISO
    log "Writing ISO to USB (this may take several minutes)..."
    diskutil unmountDisk "$TARGET_DEVICE" 2>/dev/null || true
    sleep 2

    if ! sudo dd if="$ISO_PATH" of="$TARGET_DEVICE" bs=1m; then
        die "Failed to write ISO to USB"
    fi

    sync
    log "ISO written successfully"

    diskutil eject "$TARGET_DEVICE" 2>/dev/null || true

    show_manual_instructions
}

# ── Instruction Displays ──

show_blind_boot_instructions() {
    echo ""
    echo "========================================="
    echo " READY TO REBOOT - MANUAL BOOT REQUIRED"
    echo "========================================="
    echo ""
    echo "Boot device NOT set automatically (SIP blocks NVRAM)."
    echo "Manual keyboard selection required at boot."
    echo ""
    echo "BOOT PROCEDURE:"
    echo ""
    echo "  1. Run: sudo shutdown -r now"
    echo "  2. After startup chime, press and HOLD Option key"
    echo "  3. Release Option — Startup Manager shows disk icons"
    echo "  4. Select CIDATA (Ubuntu installer) using arrow keys"
    echo "  5. Press Enter to boot"
    echo ""
    echo "  Left:  Macintosh HD (macOS)"
    echo "  Right: CIDATA (Ubuntu installer)"
    echo ""
    echo "POST-INSTALL:"
    echo "  After Ubuntu installs, run 'sudo boot-macos' to return to macOS"
    echo ""
}

show_success_instructions() {
    echo ""
    echo "========================================="
    echo " READY TO REBOOT"
    echo "========================================="
    echo ""
    echo "Boot device set successfully!"
    echo ""
    echo "On next reboot, Mac Pro will boot into Ubuntu installer."
    echo ""
    echo "To start: sudo shutdown -r now"
    echo ""
    echo "POST-INSTALL:"
    echo "  After Ubuntu installs, run 'sudo boot-macos' to return to macOS"
    echo ""
}

show_usb_instructions() {
    echo ""
    echo "========================================="
    echo " USB DRIVE READY"
    echo "========================================="
    echo ""
    echo "Bootable USB created successfully!"
    echo ""
    echo "BOOT PROCEDURE:"
    echo ""
    echo "  1. Insert USB into Mac Pro"
    echo "  2. Hold Option key at startup"
    echo "  3. Select 'CIDATA' (EFI Boot) from boot menu"
    echo "  4. GRUB will auto-select autoinstall after 3 seconds"
    echo ""
    echo "STORAGE LAYOUT:"
    if [ "$STORAGE_LAYOUT" = "1" ]; then
        echo "    Dual-boot mode selected — ensure you have free space"
        echo "    on the internal disk for Ubuntu installation."
    else
        echo "    Full-disk mode selected — ALL DATA WILL BE ERASED"
    fi
    echo ""
    echo "NETWORK:"
    if [ "$NETWORK_TYPE" = "1" ]; then
        echo "    WiFi mode — driver will compile automatically during install"
    else
        echo "    Ethernet mode — network available immediately"
    fi
    echo ""
    echo "After install, efibootmgr from Ubuntu will manage boot order."
    echo ""
}

show_manual_instructions() {
    echo ""
    echo "========================================="
    echo " MANUAL USB READY"
    echo "========================================="
    echo ""
    echo "Standard Ubuntu USB created successfully!"
    echo ""
    echo "BOOT PROCEDURE:"
    echo ""
    echo "  1. Insert USB into Mac Pro"
    echo "  2. Hold Option key at startup"
    echo "  3. Select 'EFI Boot' from boot menu"
    echo "  4. Follow Ubuntu installer prompts"
    echo ""
    echo "POST-INSTALL SETUP (run these on the new Ubuntu system):"
    echo ""
    echo "  1. Copy packages from this Mac to the Ubuntu system:"
    echo "     scp -r $SCRIPT_DIR/packages ubuntu@<new-ip>:~/"
    echo ""
    echo "  2. On the Ubuntu system, install WiFi driver:"
    echo "     cd ~/packages"
    echo "     sudo apt install dkms"
    echo "     sudo dpkg -i broadcom-sta-dkms_*.deb"
    echo ""
    echo "  3. Configure netplan for WiFi (edit /etc/netplan/01-wifi.yaml):"
    echo "     network:"
    echo "       version: 2"
    echo "       wifis:"
    echo "         wl0:"
    echo "           dhcp4: true"
    echo "           access-points:"
    echo "             YOUR_SSID:"
    echo "               password: YOUR_PASSWORD"
    echo ""
    echo "  4. Apply netplan and reboot:"
    echo "     sudo netplan apply"
    echo ""
    echo "  5. Configure GRUB for Mac Pro GPU:"
    echo "     sudo nano /etc/default/grub"
    echo "     # Add to GRUB_CMDLINE_LINUX_DEFAULT: nomodeset amdgpu.si.modeset=0"
    echo "     sudo update-grub"
    echo ""
    echo "  6. Install UFW:"
    echo "     sudo apt install ufw"
    echo "     sudo ufw default deny incoming"
    echo "     sudo ufw allow ssh"
    echo "     sudo ufw enable"
    echo ""
}

# ── Main Entry Point ──

handle_revert_flag() {
    # Handle --revert flag for manual rollback
    if [ "${1:-}" = "--revert" ]; then
        log "Manual revert requested..."
        INTERNAL_DISK=$(diskutil list | grep -E 'internal.*physical' | head -1 | grep -oE '/dev/disk[0-9]+' || true)
        if [ -z "${INTERNAL_DISK:-}" ]; then
            die "Cannot identify internal disk for revert"
        fi

        local APFS_PARTITION
        APFS_PARTITION=$(diskutil list "$INTERNAL_DISK" | grep -i "APFS" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
        if [ -n "${APFS_PARTITION:-}" ]; then
            APFS_CONTAINER=$(diskutil info "$APFS_PARTITION" 2>/dev/null | grep -i "container" | grep -oE 'disk[0-9]+' | head -1 || true)
        fi
        if [ -z "${APFS_CONTAINER:-}" ]; then
            APFS_CONTAINER=$(diskutil list | grep -i "APFS" | grep -oE 'disk[0-9]+' | head -1 || true)
        fi

        # Find and remove the CIDATA ESP partition
        local ESP_CANDIDATE
        ESP_CANDIDATE=$(diskutil list "$INTERNAL_DISK" 2>/dev/null | grep "$ESP_NAME" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
        if [ -n "${ESP_CANDIDATE:-}" ]; then
            log "Removing ESP partition /dev/$ESP_CANDIDATE..."
            diskutil unmount "/dev/$ESP_CANDIDATE" 2>/dev/null || true
            diskutil eraseVolume free none "/dev/$ESP_CANDIDATE" 2>/dev/null || warn "Could not remove /dev/$ESP_CANDIDATE"
        else
            warn "No $ESP_NAME partition found"
        fi

        # Restore macOS boot device
        local MACOS_VOLUME
        MACOS_VOLUME=$(diskutil info "${APFS_CONTAINER:-}" 2>/dev/null | grep "Mount Point" | awk '{print $NF}' || echo "/")
        if [ -d "$MACOS_VOLUME" ] && [ "$MACOS_VOLUME" != "/" ]; then
            bless --mount "$MACOS_VOLUME" --setBoot 2>/dev/null && log "macOS boot device restored" || warn "Could not restore macOS boot device"
        else
            bless --mount / --setBoot 2>/dev/null && log "macOS boot device restored" || warn "Could not restore macOS boot device"
        fi

        log "Revert complete"
        exit 0
    fi
}

main() {
    # Check for revert flag
    handle_revert_flag "$@"

    # Initialize log
    touch "$LOG_FILE" || LOG_FILE="/dev/null"

    # Show main menu
    show_header
    log "Deploy log: $LOG_FILE"
    echo ""

    select_deployment_method

    if [ "$DEPLOY_METHOD" != "3" ] && [ "$DEPLOY_METHOD" != "4" ]; then
        select_storage_layout
        select_network_type
    fi

    confirm_settings

    # Dispatch to appropriate deployment function
    case "$DEPLOY_METHOD" in
        1)
            deploy_internal_partition
            ;;
        2)
            deploy_usb
            ;;
        3)
            deploy_manual
            ;;
        4)
            deploy_vm_test
            ;;
        *)
            die "Unknown deployment method: $DEPLOY_METHOD"
            ;;
    esac

    log "Deployment preparation complete!"
}

main "$@"

#!/bin/bash
set -e
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly ISO_PATH="${1:-${SCRIPT_DIR}/ubuntu-macpro.iso}"
readonly ESP_NAME="UBUNTU_ESP"
readonly ESP_SIZE="2g"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly NC='\033[0m'

log()   { echo -e "${GREEN}[deploy]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
die()   { error "$1"; exit 1; }

echo "========================================="
echo " Mac Pro 2013 Headless Ubuntu Deploy"
echo " Remote installation via bless"
echo "========================================="
echo ""

# ── Preflight checks ──

[ -f "$ISO_PATH" ] || die "ISO not found: $ISO_PATH (pass path as argument)"

log "Running on: $(sw_vers -productName) $(sw_vers -productVersion)"
log "ISO: $ISO_PATH"
echo ""

# ── Step 1: Analyze current disk layout ──

log "Step 1: Analyzing disk layout..."
INTERNAL_DISK=$(diskutil list | grep -E 'internal.*physical' | head -1 | grep -oE '/dev/disk[0-9]+' || true)
[ -n "$INTERNAL_DISK" ] || die "Cannot identify internal disk"

log "Internal disk: $INTERNAL_DISK"
diskutil list "$INTERNAL_DISK"
echo ""

# Check APFS container and free space
APFS_CONTAINER=$(diskutil apfs list | grep -A2 "Container.*${INTERNAL_DISK}" | grep -oE 'disk[0-9]+s[0-9]+' | head -1 || true)
if [ -n "$APFS_CONTAINER" ]; then
    APFS_INFO=$(diskutil apfs list 2>/dev/null)
    FREE_SPACE=$(echo "$APFS_INFO" | grep -A5 "Capacity" | grep "Available" | grep -oE '[0-9]+.*B' | head -1 || true)
    log "APFS container: /dev/$APFS_CONTAINER"
    log "Free space: ${FREE_SPACE:-unknown}"
fi
echo ""

# ── Step 2: Check for APFS snapshots ──

log "Step 2: Checking APFS snapshots..."
SNAPSHOTS=$(diskutil apfs listSnapshots "$APFS_CONTAINER" 2>/dev/null | grep "Snapshot.*UUID" || true)
if [ -n "$SNAPSHOTS" ]; then
    warn "APFS snapshots found — must delete before resizing:"
    echo "$SNAPSHOTS"
    echo ""
    read -p "Delete all snapshots? (yes/no): " CONFIRM
    [ "$CONFIRM" = "yes" ] || die "Cannot proceed with snapshots present"
    diskutil apfs deleteSnapshot "$APFS_CONTAINER" -uuid 2>/dev/null || true
fi
echo ""

# ── Step 3: Shrink APFS container ──

log "Step 3: Shrinking APFS container..."

CURRENT_SIZE=$(diskutil info "$APFS_CONTAINER" 2>/dev/null | grep "Disk Size" | grep -oE '[0-9]+\.[0-9]+ GB' || true)
log "Current APFS size: ${CURRENT_SIZE:-unknown}"

MIN_MACOS_GB=80
TARGET_MACOS_GB=100
log "Target macOS size: ${TARGET_MACOS_GB}GB (minimum: ${MIN_MACOS_GB}GB)"

diskutil apfs resizeContainer "$APFS_CONTAINER" "${TARGET_MACOS_GB}g" 0 0 0 || die "APFS resize failed"
log "APFS container resized"
echo ""

# ── Step 4: Create ESP partition ──

log "Step 4: Creating ESP partition for Ubuntu installer..."

FREE_START=$(diskutil list "$INTERNAL_DISK" | grep -E '\(free\)' -B1 | head -1 | grep -oE '[0-9]+\.[0-9]+ GB' || true)
log "Free space after resize: ${FREE_START:-unknown}"

diskutil addPartition "$INTERNAL_DISK" %noformat% %noformat% "$ESP_SIZE" || die "Failed to create ESP partition"
sleep 2

ESP_DEVICE=$(diskutil list "$INTERNAL_DISK" | grep -E "${ESP_NAME}|EFI| FAT|" | tail -1 | grep -oE 'disk[0-9]+s[0-9]+' || true)
if [ -z "$ESP_DEVICE" ]; then
    # Try to find the newly created partition by looking for the last one
    ESP_DEVICE=$(diskutil list "$INTERNAL_DISK" | grep -oE 'disk[0-9]+s[0-9]+' | tail -1)
fi
[ -n "$ESP_DEVICE" ] || die "Cannot identify newly created ESP partition"

log "ESP partition: /dev/$ESP_DEVICE"

# Format as FAT32 with the ESP name
diskutil eraseDisk FAT32 "$ESP_NAME" MBR "/dev/$ESP_DEVICE" 2>/dev/null || \
    diskutil eraseVolume FAT32 "$ESP_NAME" "/dev/$ESP_DEVICE" 2>/dev/null || \
    true
sleep 1

ESP_MOUNT="/Volumes/$ESP_NAME"
[ -d "$ESP_MOUNT" ] || die "ESP not mounted at $ESP_MOUNT"
log "ESP mounted at: $ESP_MOUNT"
echo ""

# ── Step 5: Mount ISO and extract contents to ESP ──

log "Step 5: Extracting ISO contents to ESP..."

ISO_MOUNT="/tmp/ubuntu-iso-mount"
mkdir -p "$ISO_MOUNT"
hdiutil attach "$ISO_PATH" -mountpoint "$ISO_MOUNT" -readonly -quiet || die "Failed to mount ISO"
log "ISO mounted at: $ISO_MOUNT"

# Copy EFI boot files
log "Copying EFI boot structure..."
mkdir -p "$ESP_MOUNT/EFI/boot"
cp "$ISO_MOUNT/EFI/boot/"* "$ESP_MOUNT/EFI/boot/" 2>/dev/null || true

# Copy casper (kernel + initrd + filesystem)
log "Copying casper directory (~850MB)..."
mkdir -p "$ESP_MOUNT/casper"
cp "$ISO_MOUNT/casper/"* "$ESP_MOUNT/casper/" 2>/dev/null || true

# Copy the autoinstall.yaml and macpro-pkgs
log "Copying autoinstall configuration..."
cp "$ISO_MOUNT/autoinstall.yaml" "$ESP_MOUNT/autoinstall.yaml" 2>/dev/null || \
    cp "$SCRIPT_DIR/autoinstall.yaml" "$ESP_MOUNT/autoinstall.yaml"

log "Copying driver compilation packages..."
mkdir -p "$ESP_MOUNT/macpro-pkgs"
cp "$ISO_MOUNT/macpro-pkgs/"* "$ESP_MOUNT/macpro-pkgs/" 2>/dev/null || \
    cp "$SCRIPT_DIR/packages/"*.deb "$ESP_MOUNT/macpro-pkgs/" 2>/dev/null || true

# Copy cidata for ds=nocloud
log "Creating cidata structure..."
mkdir -p "$ESP_MOUNT/cidata"
cp "$ISO_MOUNT/cidata/"* "$ESP_MOUNT/cidata/" 2>/dev/null || true
[ -f "$ESP_MOUNT/cidata/user-data" ] || cp "$SCRIPT_DIR/autoinstall.yaml" "$ESP_MOUNT/cidata/user-data"
[ -f "$ESP_MOUNT/cidata/meta-data" ] || echo "instance-id: macpro-linux-i1" > "$ESP_MOUNT/cidata/meta-data"
[ -f "$ESP_MOUNT/cidata/vendor-data" ] || touch "$ESP_MOUNT/cidata/vendor-data"

# Copy pool directory (packages available during install)
log "Copying package pool..."
mkdir -p "$ESP_MOUNT/pool"
cp -r "$ISO_MOUNT/pool/"* "$ESP_MOUNT/pool/" 2>/dev/null || true

# Copy dists directory (release metadata)
log "Copying release metadata..."
mkdir -p "$ESP_MOUNT/dists"
cp -r "$ISO_MOUNT/dists/"* "$ESP_MOUNT/dists/" 2>/dev/null || true

# Copy .disk directory
log "Copying disk metadata..."
mkdir -p "$ESP_MOUNT/.disk"
cp "$ISO_MOUNT/.disk/"* "$ESP_MOUNT/.disk/" 2>/dev/null || true

# Write GRUB config with pre-baked autoinstall parameters
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

# Also write boot/grub/grub.cfg for BIOS-style GRUB
mkdir -p "$ESP_MOUNT/boot/grub"
cp "$ESP_MOUNT/EFI/boot/grub.cfg" "$ESP_MOUNT/boot/grub/grub.cfg"

hdiutil detach "$ISO_MOUNT" -quiet 2>/dev/null || true
echo ""

# ── Step 6: Verify ESP contents ──

log "Step 6: Verifying ESP contents..."
REQUIRED_FILES=(
    "EFI/boot/BOOTX64.EFI"
    "EFI/boot/grub.cfg"
    "casper/vmlinuz"
    "casper/initrd"
    "autoinstall.yaml"
    "cidata/user-data"
    "cidata/meta-data"
    "macpro-pkgs/broadcom-sta-dkms_6.30.223.271-12_amd64.deb"
)
ALL_OK=true
for f in "${REQUIRED_FILES[@]}"; do
    if [ -f "$ESP_MOUNT/$f" ]; then
        log "  ✓ $f"
    else
        warn "  ✗ $f (not found)"
        ALL_OK=false
    fi
done

if [ "$ALL_OK" = "false" ]; then
    warn "Some required files are missing. Continue anyway?"
    read -p "Continue? (yes/no): " CONFIRM
    [ "$CONFIRM" = "yes" ] || die "Aborted due to missing files"
fi
echo ""

# ── Step 7: Set boot device with bless ──

log "Step 7: Setting boot device with bless..."

# bless --setBoot sets the NVRAM variable for next boot
# --mount points to the ESP volume
# --path points to the EFI bootloader
bless --setBoot --mount "$ESP_MOUNT" --path "$ESP_MOUNT/EFI/boot/BOOTX64.EFI" || \
    bless --setBoot --mount "$ESP_MOUNT" || \
    die "bless failed — cannot set boot device. Check SIP status."

log "Boot device set via bless"
log "ESP: $ESP_MOUNT"
log "Bootloader: $ESP_MOUNT/EFI/boot/BOOTX64.EFI"
echo ""

# ── Step 8: Confirm and reboot ──

echo "========================================="
echo " READY TO REBOOT"
echo "========================================="
echo ""
echo "Current boot device has been changed to:"
echo "  $ESP_MOUNT (ESP with Ubuntu installer)"
echo ""
echo "On next reboot, the Mac Pro will boot into"
echo "Ubuntu Server autoinstall and begin installation."
echo ""
echo "To monitor: start webhook monitor on MacBook"
echo "  cd macpro-monitor && ./start.sh"
echo ""
echo "To cancel: reset NVRAM boot device"
echo "  bless --mount / --setBoot  # reset to macOS"
echo ""
read -p "Reboot now? (yes/no): " CONFIRM
if [ "$CONFIRM" = "yes" ]; then
    log "Rebooting..."
    shutdown -r now
else
    log "Reboot cancelled. Boot device is set but not activated."
    log "Run 'shutdown -r now' when ready."
fi
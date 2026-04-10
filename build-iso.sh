#!/bin/bash
set -e
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly BASE_ISO="${SCRIPT_DIR}/prereqs/ubuntu-24.04.4-live-server-amd64.iso"
readonly AUTOINSTALL="${SCRIPT_DIR}/autoinstall.yaml"
readonly PKGS_DIR="${SCRIPT_DIR}/packages"
readonly OUTPUT_ISO="${SCRIPT_DIR}/ubuntu-macpro.iso"
readonly STAGING="/tmp/macpro-iso-staging"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'

echo "========================================="
echo " Mac Pro 2013 Ubuntu ISO Builder"
echo " Minimal modification approach"
echo "========================================="
echo ""

[ -f "$BASE_ISO" ] || { echo -e "${RED}ERROR${NC}: Base ISO not found: $BASE_ISO"; exit 1; }
[ -f "$AUTOINSTALL" ] || { echo -e "${RED}ERROR${NC}: autoinstall.yaml not found: $AUTOINSTALL"; exit 1; }
[ -d "$PKGS_DIR" ] || { echo -e "${RED}ERROR${NC}: packages/ directory not found: $PKGS_DIR"; exit 1; }

PKG_COUNT=$(ls "$PKGS_DIR"/*.deb 2>/dev/null | wc -l | tr -d ' ')
echo "Packages to include: $PKG_COUNT"
[ "$PKG_COUNT" -gt 0 ] || { echo -e "${RED}ERROR${NC}: No .deb files in packages/"; exit 1; }

echo ""
echo "[1/4] Preparing staging area..."
rm -rf "$STAGING"
mkdir -p "$STAGING/macpro-pkgs"
mkdir -p "$STAGING/cidata"
mkdir -p "$STAGING/efi-boot"

cp "$AUTOINSTALL" "$STAGING/autoinstall.yaml"
cp "$PKGS_DIR"/*.deb "$STAGING/macpro-pkgs/"

echo "[2/4] Creating cidata for ds=nocloud..."
echo "instance-id: macpro-linux-i1" > "$STAGING/cidata/meta-data"
cp "$AUTOINSTALL" "$STAGING/cidata/user-data"
touch "$STAGING/cidata/vendor-data"

echo "[3/4] Creating EFI boot config with pre-baked autoinstall parameters..."
cat > "$STAGING/efi-boot/grub.cfg" << 'GRUBEOF'
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

echo ""
echo "Building ISO with xorriso..."
xorriso -indev "$BASE_ISO" \
    -outdev "$OUTPUT_ISO" \
    -map "$STAGING/autoinstall.yaml" /autoinstall.yaml \
    -map "$STAGING/cidata/" /cidata/ \
    -map "$STAGING/macpro-pkgs/" /macpro-pkgs/ \
    -map "$STAGING/efi-boot/grub.cfg" /EFI/boot/grub.cfg \
    -map "$STAGING/efi-boot/grub.cfg" /boot/grub/grub.cfg \
    -volid "Ubuntu2404MacPro" \
    -boot_image any keep \
    -commit

echo ""
echo "[4/4] Verifying ISO contents..."
xorriso -indev "$OUTPUT_ISO" \
    -ls /autoinstall.yaml \
    -ls /cidata/ \
    -ls /macpro-pkgs/ \
    -ls /EFI/boot/grub.cfg \
    -ls /boot/grub/grub.cfg \
    -rollback 2>/dev/null | head -30

rm -rf "$STAGING"

SIZE=$(du -h "$OUTPUT_ISO" | cut -f1)
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} BUILD COMPLETE${NC}"
echo -e "${GREEN}=========================================${NC}"
echo "Output:   $OUTPUT_ISO"
echo "Size:     $SIZE"
echo "Packages: $PKG_COUNT debs in /macpro-pkgs/"
echo "Config:   /autoinstall.yaml"
echo "cidata:   /cidata/{user-data,meta-data,vendor-data}"
echo "GRUB:     /EFI/boot/grub.cfg + /boot/grub/grub.cfg"
echo ""
echo "Boot methods:"
echo "  USB:          Boot from USB, auto-entry selected after 3s"
echo "  Headless:     Use prepare-headless-deploy.sh to bless via SSH"
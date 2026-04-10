#!/bin/bash
set -e
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly BASE_ISO="/Users/djtchill/Desktop/Mac/prereqs/ubuntu-24.04.4-live-server-amd64.iso"
readonly AUTOINSTALL="${SCRIPT_DIR}/autoinstall.yaml"
readonly OUTPUT_ISO="${SCRIPT_DIR}/ubuntu-macpro.iso"

echo "========================================="
echo " Mac Pro 2013 Ubuntu ISO Builder"
echo " Minimal modification approach"
echo "========================================="
echo ""

[ -f "$BASE_ISO" ] || { echo "ERROR: Base ISO not found: $BASE_ISO"; exit 1; }
[ -f "$AUTOINSTALL" ] || { echo "ERROR: autoinstall.yaml not found: $AUTOINSTALL"; exit 1; }

echo "[1/2] Injecting autoinstall.yaml into ISO..."
xorriso -indev "$BASE_ISO" \
    -outdev "$OUTPUT_ISO" \
    -map "$AUTOINSTALL" /autoinstall.yaml \
    -volid "Ubuntu2404MacPro" \
    -boot_image any keep \
    -commit

echo ""
echo "[2/2] Verifying..."
echo ""
xorriso -indev "$OUTPUT_ISO" \
    -ls /autoinstall.yaml \
    -rollback

SIZE=$(du -h "$OUTPUT_ISO" | cut -f1)
echo ""
echo "========================================="
echo " BUILD COMPLETE"
echo "========================================="
echo "Output: $OUTPUT_ISO"
echo "Size:   $SIZE"
echo ""
echo "Only change: /autoinstall.yaml added"
echo "EFI boot structure preserved"
echo ""
echo "Boot parameters (set in GRUB at boot time):"
echo "  autoinstall ds=nocloud"
echo "  nomodeset amdgpu.si.modeset=0"
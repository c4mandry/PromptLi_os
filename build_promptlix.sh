#!/bin/bash
# ============================================================
#  PromptLix OS — Native x86_64 ISO builder
#
#  Run this on a Debian 12/13 or Ubuntu 22.04/24.04 x86_64
#  machine. Installs build dependencies, then builds the
#  installable live ISO.
#
#  Output: ~/promptlix-os-output/promptlix-os-1.0.0-amd64.iso
# ============================================================
set -euo pipefail

ISO_NAME="promptlix-os-1.0.0-amd64"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/promptlix-os"
BUILD_DIR="/tmp/promptlix-build"
OUTPUT_DIR="$HOME/promptlix-os-output"

echo "================================================"
echo "  PromptLix OS — Native x86_64 ISO Builder"
echo "================================================"
echo ""
echo "This script will:"
echo "  1. Install build dependencies (live-build, Calamares toolchain, etc.)"
echo "  2. Build a Debian 13 live ISO with GNOME + AIDO assistant"
echo "  3. Include the Calamares installer (install to disk, UEFI + BIOS)"
echo "  Output: $OUTPUT_DIR/$ISO_NAME.iso"
echo ""

if [ "$(uname -m)" != "x86_64" ]; then
    echo "ERROR: this native builder requires x86_64 (detected: $(uname -m))."
    echo "       On other hosts use: promptlix-os/build/build_iso.sh (Docker)."
    exit 1
fi

echo "[*] Installing build dependencies (sudo required)..."
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    live-build live-boot live-config live-tools debootstrap \
    xorriso isolinux syslinux-common syslinux-efi \
    grub-efi-amd64-bin grub-pc-bin \
    squashfs-tools rsync dosfstools mtools cpio \
    gzip xz-utils wget curl git ca-certificates \
    librsvg2-bin

echo "[*] Preparing build workspace..."
rm -rf "$BUILD_DIR" "$OUTPUT_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
cp -a "$SOURCE_DIR" "$BUILD_DIR/source"

echo "[*] Building (15-45 minutes)..."
PROJECT="$BUILD_DIR/source" WORK="$BUILD_DIR" OUTPUT="$OUTPUT_DIR" \
    bash "$BUILD_DIR/source/build/live_build_inner.sh"

echo ""
echo "========================================="
echo "  Build complete!"
echo "  $OUTPUT_DIR/$ISO_NAME.iso"
echo ""
echo "  Test it in QEMU:"
echo "    qemu-system-x86_64 -m 4G -cdrom $OUTPUT_DIR/$ISO_NAME.iso -boot d"
echo "  Or write to a USB stick and boot (then run 'Install PromptLix')."
echo "========================================="

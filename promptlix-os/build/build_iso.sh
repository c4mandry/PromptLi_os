#!/bin/bash
# ============================================================
#  PromptLix OS — Docker-based ISO builder
#
#  Works on any host with Docker (including Apple Silicon via
#  QEMU emulation, though a native x86_64 host is much faster
#  and the only fully supported path).
#
#  Output: build/output/promptlix-os-1.0.0-amd64.iso
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/.."
BUILD_DIR="$SCRIPT_DIR/work"
OUTPUT_DIR="$SCRIPT_DIR/output"
ISO_NAME="promptlix-os-1.0.0-amd64"

echo "PromptLix OS — Docker ISO builder"

rm -rf "$BUILD_DIR" "$OUTPUT_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

echo "[*] Building builder image..."
docker build --platform linux/amd64 -t promptlix-builder -f - "$SOURCE_DIR" << 'DOCKERFILE'
FROM --platform=linux/amd64 debian:13-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    live-build live-boot live-config live-tools debootstrap \
    xorriso isolinux syslinux-common syslinux-efi \
    grub-efi-amd64-bin grub-pc-bin \
    squashfs-tools rsync dosfstools mtools cpio \
    gzip xz-utils wget curl git ca-certificates \
    librsvg2-bin \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
DOCKERFILE

echo "[*] Building ISO in container (15-45 minutes)..."
docker run --rm --privileged --platform linux/amd64 \
    -v "$SOURCE_DIR:/project:ro" \
    -v "$BUILD_DIR:/build" \
    -v "$OUTPUT_DIR:/output" \
    -e PROJECT=/project -e WORK=/build -e OUTPUT=/output \
    promptlix-builder bash -c 'bash /project/build/live_build_inner.sh'

echo ""
echo "========================================="
echo "  Build complete!"
echo "  $OUTPUT_DIR/$ISO_NAME.iso"
echo "========================================="
ls -lh "$OUTPUT_DIR"

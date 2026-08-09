#!/bin/bash
# ============================================================
#  promptLi OS — ISO Builder (Docker + live-build)
# ============================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/work"
OUTPUT_DIR="$PROJECT_DIR/build/output"
ISO_NAME="promptli-os-1.0.0-amd64"

echo "⚡ promptLi OS ISO Builder"
echo "========================="

# Clean previous builds
rm -rf "$BUILD_DIR" "$OUTPUT_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# Detect if Docker is available
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "[✓] Docker detected — using containerized build"
    USE_DOCKER=true
else
    echo "[!] Docker not available — attempting local build (requires Debian/Ubuntu)"
    USE_DOCKER=false
fi

# ── Build with Docker ──────────────────────────────────
if [ "$USE_DOCKER" = true ]; then
    echo "[*] Building Docker image with live-build..."

    docker build --platform linux/amd64 -t promptli-builder -f - "$PROJECT_DIR" << 'DOCKERFILE'
FROM --platform=linux/amd64 debian:13-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    live-build \
    live-boot \
    live-config \
    live-tools \
    debootstrap \
    xorriso \
    isolinux \
    syslinux-common \
    syslinux-efi \
    squashfs-tools \
    rsync \
    dosfstools \
    mtools \
    cpio \
    gzip \
    xz-utils \
    wget \
    curl \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
ENTRYPOINT ["/bin/bash"]
DOCKERFILE

    echo "[*] Running live-build in container..."

    docker run --rm --privileged --platform linux/amd64 \
        --security-opt seccomp=unconfined \
        -v "$PROJECT_DIR:/project:ro" \
        -v "$BUILD_DIR:/build" \
        -v "$OUTPUT_DIR:/output" \
        promptli-builder \
        -c "
            set -e
            # Copy project files into build context
            cp -r /project/config /build/config
            cp -r /project/assistant /build/
            cp -r /project/tools /build/
            cp /project/build/build_config.sh /build/ 2>/dev/null || true

            # Run build script
            bash /project/build/live_build_inner.sh
        "

    echo "[✓] Build complete!"

# ── Local build (Debian/Ubuntu host) ───────────────────
else
    echo "[*] Attempting local build..."
    if ! command -v lb &> /dev/null; then
        echo "[✗] live-build not found. Install with: sudo apt install live-build"
        exit 1
    fi

    # Copy project files to build dir
    rsync -a "$PROJECT_DIR/config/" "$BUILD_DIR/config/"
    rsync -a "$PROJECT_DIR/assistant/" "$BUILD_DIR/assistant/"
    rsync -a "$PROJECT_DIR/tools/" "$BUILD_DIR/tools/"

    cd "$BUILD_DIR"
    bash "$PROJECT_DIR/build/live_build_inner.sh"
fi

echo ""
echo "========================================="
echo "  ✅ promptLi OS ISO built successfully!"
echo "  📀 Output: output/$ISO_NAME.iso"
echo "========================================="

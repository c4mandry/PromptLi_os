#!/bin/bash
# ============================================================
#  promptLi OS — Quick test runner
#  Builds a minimal version for testing in QEMU/VirtualBox
# ============================================================
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "⚡ promptLi OS — Quick Build & Test"
echo ""

# Check for required tools
command -v docker &>/dev/null && echo "[✓] Docker available" || echo "[✗] Docker not found (needed for build)"
command -v qemu-system-x86_64 &>/dev/null && echo "[✓] QEMU available" || echo "[!] QEMU not found (install to test)"

echo ""
echo "Build modes:"
echo "  1) Full ISO (30-45 min) — ./build_iso.sh"
echo "  2) Test the assistant app locally — python3 assistant/promptli_assistant.py"
echo ""
echo "To build the full ISO:"
echo "  cd build && bash build_iso.sh"
echo ""
echo "To test with QEMU after build:"
echo "  qemu-system-x86_64 -m 4G -cdrom output/promptli-os-1.0.0-amd64.iso -boot d"

#!/bin/bash
# ============================================================
#  PromptLix OS — Quick test runner
#  Checks your environment and prints build/test commands.
# ============================================================
set -e

echo "PromptLix OS — Quick Build & Test"
echo ""

# Check for required tools
command -v docker &>/dev/null && echo "[OK] Docker available" || echo "[FAIL] Docker not found"
command -v qemu-system-x86_64 &>/dev/null && echo "[OK] QEMU available" || echo "[!] QEMU not found (install to boot-test)"
command -v lb &>/dev/null && echo "[OK] live-build available (native build possible)" || echo "[!] live-build not found (use Docker or build_promptlix.sh)"

echo ""
echo "Build modes:"
echo "  1) Native x64 (recommended) — ../../build_promptlix.sh"
echo "  2) Docker — ./build_iso.sh"
echo "  3) Test the assistant locally — python3 ../assistant/promptlix-server.py (+ webview)"
echo ""
echo "To boot-test the ISO in QEMU:"
echo "  qemu-system-x86_64 -m 4G -cdrom output/promptlix-os-1.0.0-amd64.iso -boot d"
echo ""
echo "To install to disk: boot the ISO, then Super+I → Calamares installer"
echo "  (or press Super+i) and follow the Calamares installer."

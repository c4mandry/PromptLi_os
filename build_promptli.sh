#!/bin/bash
# ================================================================
#  promptLi OS — Native x86_64 Builder
#  Run this on a Debian/Ubuntu x86_64 machine.
#  All QEMU workarounds removed since we are native.
# ================================================================
set -euo pipefail

# Versioning: major is set by hand. Minor counts features/big changes since
# v1.0.0 (see git history); patch counts every bug fix, however small.
VERSION="1.22.52"
ISO_NAME="promptli-os-${VERSION}-amd64"

echo "================================================"
echo "  promptLi OS — Native x86_64 ISO Builder"
echo "================================================"
echo ""
echo "This script will:"
echo "  1. Install build dependencies (live-build etc.)"
echo "  2. Build a custom, minimal Debian live ISO (server-focused, no WM/DE):"
echo "     - promptLi AI Assistant (Claude API + system control)"
echo "     - locakHost web server (terminal: just type 'locakhost')"
echo "     - Rust TUI installer (promptli-install); updates via apt/pacman -Syu"
echo "  3. Output: promptli-os-${VERSION}-amd64.iso"
echo ""

# NOTE: /tmp on this host is a tmpfs mounted with 'nodev', which breaks
# device-node creation inside the chroot (debootstrap/dpkg need /dev/null,
# /dev/pts, etc.). Build under a real filesystem (/ is ext4) instead.
BUILD_DIR="/var/tmp/promptli-build"
OUTPUT_DIR="${PROMPTLI_OUTPUT_DIR:-$HOME/promptli-os-output}"

# Absolute path of this repo — captured BEFORE any `cd` so the build can
# find sibling sources (aido/, the Rust installer binary) from anywhere.
SCRIPT_DIR_REPO="$(cd "$(dirname "$0")" && pwd)"

# ── Check that we are on x86_64 ──────────────────────────
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    echo "ERROR: This builder requires an x86_64 machine (detected: $ARCH)"
    exit 1
fi

# ── Install dependencies ─────────────────────────────────
echo "[*] Installing build dependencies..."
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    live-build live-boot live-config live-tools \
    debootstrap \
    xorriso isolinux syslinux-common syslinux-efi \
    squashfs-tools rsync dosfstools mtools cpio \
    gzip xz-utils wget curl git ca-certificates

# ── Clean build dir ──────────────────────────────────────
# If a previous build was interrupted, the chroot may still have /proc,
# /sys, /dev/pts mounted inside it; rm -rf would fail on those (and set -e
# would abort the whole build), so lazy-unmount them first.
for m in "$BUILD_DIR/chroot/dev/pts" "$BUILD_DIR/chroot/proc" "$BUILD_DIR/chroot/sys" "$BUILD_DIR/chroot/dev"; do
    if mountpoint -q "$m" 2>/dev/null; then
        echo "[!] Unmounting leftover mount from an interrupted build: $m"
        sudo umount -l "$m" 2>/dev/null || true
    fi
done
rm -rf "$BUILD_DIR" "$OUTPUT_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
cd "$BUILD_DIR"

echo "[*] Configuring live-build..."

# Configure
lb config noauto \
    --architecture amd64 \
    --distribution trixie \
    --archive-areas "main contrib non-free non-free-firmware" \
    --bootappend-live "boot=live quiet" \
    --debian-installer none \
    --iso-application "promptLi OS" \
    --iso-publisher "promptLi" \
    --iso-volume "promptLi OS ${VERSION}" \
    --linux-flavours amd64 \
    --memtest none \
    --binary-images iso-hybrid

# ── Bootloader: no menu, promptLi branding ───────────────
# Override the live-build templates so the ISO boots straight into
# promptLi OS with zero delay — no "Debian GNU/Linux … Live system /
# fail-safe / Utilities" menu on either BIOS (isolinux) or UEFI (GRUB).
echo "[*] Customizing bootloader (no menu, promptLi branding)..."
mkdir -p config/bootloaders/isolinux config/bootloaders/syslinux_common config/bootloaders/grub-pc

cat > config/bootloaders/isolinux/isolinux.cfg << 'X'
default live
prompt 0
timeout 0

include live.cfg
X

cat > config/bootloaders/syslinux_common/live.cfg.in << X
label live
	menu label ^promptLi OS ${VERSION}
	menu default
	linux @LINUX@
	initrd @INITRD@
	append @APPEND_LIVE@

label live-failsafe
	menu label promptLi OS ${VERSION} (fail-safe mode)
	linux @LINUX@
	initrd @INITRD@
	append @APPEND_LIVE_FAILSAFE@
X

cat > config/bootloaders/grub-pc/grub.cfg << X
set default=0
set timeout=0

menuentry "promptLi OS ${VERSION}" {
	linux	@KERNEL_LIVE@ @APPEND_LIVE@
	initrd	@INITRD_LIVE@
}
X

cat > config/bootloaders/grub-pc/config.cfg << 'X'
set default=0
set timeout=0
X

# ── Package list ─────────────────────────────────────────
echo "[*] Setting package list..."
cat > config/package-lists/promptli.list.chroot << 'PACKAGES'
# promptLi OS — minimal, server-focused base.
# No window manager, no desktop environment, no Xorg — boots to a console TTY.

# Base system & boot (no live-config: we configure users/hostname ourselves,
# and dropping it removes the dbus daemon — less RAM, less attack surface)
linux-image-amd64 live-boot live-tools
systemd-sysv systemd-resolved systemd-timesyncd sudo adduser

# Shell: zsh with autosuggestions + syntax highlighting
zsh zsh-autosuggestions zsh-syntax-highlighting zsh-common

# Modern terminal tools
fastfetch fzf eza bat ripgrep fd-find zoxide btop tmux

# Console utilities
curl wget git vim htop unzip p7zip-full less
rsync ca-certificates
# kbd (loadkeys/setfont) + console-setup (console fonts): the plain console
# keymap/font loading, so KEYMAP= and FONT= in /etc/vconsole.conf work.
kbd console-setup

# Networking: systemd-networkd + resolved (lean; no NetworkManager/dbus bloat)
# wpa_supplicant + iw stay for WiFi
wpasupplicant iw iproute2

# Modern framebuffer console: fbterm (Unicode fonts, images) + Noto mono
fbterm fonts-noto-mono

# Disk / provisioning (used by the Rust installer; sfdisk ships in util-linux)
parted fdisk util-linux dosfstools
squashfs-tools gdisk cryptsetup

# Bootloader (installed to disk by the installer; grub-pc-bin avoids the
# interactive device prompt that grub-pc's postinst would trigger in-chroot)
grub-pc-bin grub-efi-amd64 grub-efi-amd64-bin efibootmgr os-prober

# Arch-style package tooling: pacman binary + (AUR via makedeb/mist, added
# from the vendored .deb in a chroot hook; gnupg is needed for its keyring).
# These are makedeb's runtime dependencies.
pacman-package-manager gnupg
build-essential binutils fakeroot file gettext gawk libarchive-tools lsb-release zstd

# Python (for aido, the promptLi assistant & locakHost CLI tools)
python3 python3-pip python3-venv python3-yaml python3-requests

# Rust runtime is NOT required — the installer ships as a static-ish binary.
PACKAGES

# ── Create project files ─────────────────────────────────
echo "[*] Creating promptLi project files..."

PROJECT_DIR="$BUILD_DIR/promptli-project"
mkdir -p "$PROJECT_DIR"/tools

# GUI assistant removed: promptLi OS is terminal-first; aido is the AI (see /opt/aido).


# --- locakHost ---
cat > "$PROJECT_DIR/tools/locakhost.py" << 'PYEOF'
#!/usr/bin/env python3
# locakHost by c4mandry — local web server for testing (CLI edition).
import argparse, http.server, os, socketserver

class SPAHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        p = self.translate_path(self.path)
        if not os.path.exists(p) and "." not in os.path.basename(self.path):
            self.path = "/index.html"
        return super().do_GET()

def main():
    ap = argparse.ArgumentParser(prog="locakhost", description="Serve a folder over HTTP (SPA-friendly).")
    ap.add_argument("folder", nargs="?", default=".", help="folder to serve (default: .)")
    ap.add_argument("-p", "--port", type=int, default=8080, help="port (default: 8080)")
    ap.add_argument("--spa", action="store_true", help="rewrite missing paths to /index.html")
    a = ap.parse_args()
    folder = os.path.abspath(a.folder)
    handler = SPAHandler if a.spa else http.server.SimpleHTTPRequestHandler
    socketserver.TCPServer.allow_reuse_address = True
    httpd = socketserver.TCPServer(("0.0.0.0", a.port), lambda *x, **k: handler(*x, directory=folder, **k))
    print(f"Serving {folder} at http://localhost:{a.port}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()

if __name__ == "__main__":
    main()
PYEOF

# ── Copy files into the live-build includes tree ────────
echo "[*] Copying files into chroot..."

INCLUDES="$BUILD_DIR/config/includes.chroot"
rm -rf "$INCLUDES"
mkdir -p "$INCLUDES"

# /opt/promptli (no GUI assets — promptLi OS has no desktop environment)
mkdir -p "$INCLUDES/opt/promptli"/tools
cp "$PROJECT_DIR/tools/locakhost.py" "$INCLUDES/opt/promptli/tools/"

# CLI wrappers: type 'promptli' or 'locakhost' in terminal
mkdir -p "$INCLUDES/usr/local/bin"
cat > "$INCLUDES/usr/local/bin/promptli" << 'X'; chmod +x "$INCLUDES/usr/local/bin/promptli"
#!/bin/sh
# Legacy name kept for muscle memory; aido is the promptLi OS AI assistant.
exec /usr/local/bin/aido "$@"
X
cat > "$INCLUDES/usr/local/bin/locakhost" << 'X'; chmod +x "$INCLUDES/usr/local/bin/locakhost"
#!/bin/sh
exec python3 /opt/promptli/tools/locakhost.py "$@"
X

# ── promptli-fast / promptli-norm: bloat mode switch ──────
# FAST mode strips almost everything non-essential (aido, python tools, zsh,
# fbterm, docs, extra packages) but ALWAYS keeps AUR support (pacman/makedeb/
# mist), the installer/updater, and networking. zsh is replaced with bash;
# systemd stays as PID1 (removing it wholesale would break login/network),
# but its optional timers/services are masked for a faster, lighter boot.
# NORM mode restores everything — packages from the internet, aido + tools
# from the live ISO or a fresh ISO download from the website.
cat > "$INCLUDES/usr/local/bin/promptli-fast" << 'X'; chmod +x "$INCLUDES/usr/local/bin/promptli-fast"
#!/bin/sh
# promptLi OS — FAST mode: remove almost everything non-essential.
# Keeps: kernel, bootloader, pacman/AUR (makedeb, mist), installer/updater,
# networking, fastfetch. Replaces zsh with bash.
set -eu
[ "$(id -u)" = 0 ] || exec sudo -E "$0" "$@"

if [ -e /etc/promptli/fast ]; then
    echo "Already in FAST mode. Restore with: promptli-norm"
    exit 0
fi

echo "promptLi OS → FAST mode (removing aido, zsh, python tools, docs ...)"

# AUR support + installer must never be removed by the purge/autoremove.
apt-mark manual pacman-package-manager makedeb makedeb-beta mist build-essential gnupg \
    fakeroot file gettext gawk libarchive-tools lsb-release zstd \
    squashfs-tools rsync curl 2>/dev/null || true

# 1. Purge heavy/optional packages.
apt-get purge -y -qq \
    zsh zsh-common zsh-autosuggestions zsh-syntax-highlighting \
    fzf eza bat ripgrep fd-find zoxide btop tmux \
    fbterm fonts-noto-mono fonts-dejavu-core fonts-dejavu-mono \
    python3 python3-minimal python3-pip python3-venv python3-yaml python3-requests \
    man-db manpages unzip p7zip-full htop 2>/dev/null || true
apt-get autoremove -y --purge -qq 2>/dev/null || true
apt-get clean -qq 2>/dev/null || true

# 2. Remove the AI assistant + python-based extras.
rm -rf /opt/aido /opt/promptli/tools /opt/promptli/promptli-wallpaper.py
rm -f /usr/local/bin/aido /usr/local/bin/promptli /usr/local/bin/locakhost /usr/local/bin/promptli-term
rm -f /etc/skel/.fbtermrc /root/.fbtermrc

# 3. zsh → bash. Use usermod (NOT chsh): once zsh is purged it vanishes
#    from /etc/shells while root's shell is still zsh, which makes PAM's
#    pam_shells reject chsh with "Authentication failure". usermod edits
#    /etc/passwd directly and never touches PAM.
usermod -s /bin/bash promptli 2>/dev/null || true
usermod -s /bin/bash root 2>/dev/null || true
sed -i 's|^SHELL=.*|SHELL=/bin/bash|' /etc/default/useradd 2>/dev/null || true

# 4. Mask optional systemd units (faster boot, less idle RAM).
for unit in apt-daily.timer apt-daily-upgrade.timer man-db.timer \
            systemd-tmpfiles-clean.timer e2scrub_all.timer e2scrub_reap.service \
            fstrim.timer wpa_supplicant.service ModemManager.service; do
    ln -sf /dev/null "/etc/systemd/system/$unit"
done
# One getty only (tty1), no fbterm — plain console login.
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nNAutoVTs=1\n' > /etc/systemd/logind.conf.d/promptli.conf
rm -rf /etc/systemd/system/getty@tty1.service.d
# Tighter journald caps.
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nRuntimeMaxUse=4M\nRuntimeMaxFileSize=2M\nSystemMaxUse=16M\n' > /etc/systemd/journald.conf.d/promptli.conf

# 5. Record the mode so fastfetch shows it (via os-release PRETTY_NAME).
# Idempotent, and repairs any previously-broken (duplicated) suffix state.
for KEY in PRETTY_NAME VERSION; do
    BASE=$(sed -n -E "s/^${KEY}=\"([^\"]*)\".*/\\1/p" /etc/os-release)
    BASE=${BASE%% fast}; BASE=${BASE%% norm}
    sed -i -E "s|^${KEY}=.*$|${KEY}=\"${BASE} fast\"|" /etc/os-release
done
touch /etc/promptli/fast

echo ""
echo "✅ FAST mode active — aido, zsh, python tools, fbterm, docs removed;"
echo "   pacman/AUR kept; systemd services masked; one plain getty."
echo "   Reboot for full effect. Restore with: promptli-norm"
X

cat > "$INCLUDES/usr/local/bin/promptli-norm" << 'X'; chmod +x "$INCLUDES/usr/local/bin/promptli-norm"
#!/bin/sh
# promptLi OS — NORM mode: restore everything promptli-fast removed.
# Packages come from the internet (apt); aido + tools come from the live
# ISO when booted from it, otherwise a fresh ISO is downloaded from the
# website.
set -eu
[ "$(id -u)" = 0 ] || exec sudo -E "$0" "$@"

if [ ! -e /etc/promptli/fast ]; then
    echo "Already in NORM mode."
    exit 0
fi

echo "promptLi OS → NORM mode (restoring aido, zsh, tools ...)"

# 1. Reinstall packages from the internet.
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    zsh zsh-common zsh-autosuggestions zsh-syntax-highlighting \
    fzf eza bat ripgrep fd-find zoxide btop tmux \
    fbterm fonts-noto-mono fonts-dejavu-core fonts-dejavu-mono \
    python3 python3-pip python3-venv python3-yaml python3-requests \
    man-db manpages unzip p7zip-full htop 2>/dev/null || true

# 2. Restore aido + tools: live ISO first, else download the ISO.
SQS=""
[ -f /run/live/medium/live/filesystem.squashfs ] && SQS=/run/live/medium/live/filesystem.squashfs
if [ -z "$SQS" ]; then
    ISO=/var/tmp/promptli-restore.iso
    MNT=/var/tmp/pl-iso-mnt
    echo "Downloading promptLi OS ISO to restore aido + tools ..."
    curl -fL --retry 2 -o "$ISO" "https://webnotes.work/api/os/iso" \
        || wget -O "$ISO" "https://webnotes.work/api/os/iso" || true
    if [ -s "$ISO" ]; then
        mkdir -p "$MNT"
        mount -o loop,ro "$ISO" "$MNT" 2>/dev/null || true
        [ -f "$MNT/live/filesystem.squashfs" ] && SQS="$MNT/live/filesystem.squashfs"
    fi
fi
if [ -n "$SQS" ]; then
    unsquashfs -f -no-progress -d / "$SQS" \
        opt/aido opt/promptli/tools opt/promptli/promptli-wallpaper.py \
        usr/local/bin/aido usr/local/bin/locakhost usr/local/bin/promptli \
        usr/local/bin/promptli-term etc/skel/.fbtermrc 2>/dev/null || true
    chmod +x /usr/local/bin/aido /usr/local/bin/locakhost \
        /usr/local/bin/promptli /usr/local/bin/promptli-term 2>/dev/null || true
fi
umount /var/tmp/pl-iso-mnt 2>/dev/null || true
rm -rf /var/tmp/pl-iso-mnt /var/tmp/promptli-restore.iso
if [ ! -f /root/.fbtermrc ]; then
    printf 'font-names=DejaVu Sans Mono\nfont-size=14\ntext-encodings=UTF-8\n' > /root/.fbtermrc
fi

# 3. bash → zsh (usermod, same PAM-proof approach as promptli-fast).
usermod -s /usr/bin/zsh promptli 2>/dev/null || true
usermod -s /usr/bin/zsh root 2>/dev/null || true
sed -i 's|^SHELL=.*|SHELL=/usr/bin/zsh|' /etc/default/useradd 2>/dev/null || true

# 4. Re-enable the units FAST masked (apt timers come back; the build's own
#    masks — ModemManager, wpa_supplicant, cron, fstrim, e2scrub — stay).
for unit in apt-daily.timer apt-daily-upgrade.timer; do
    rm -f "/etc/systemd/system/$unit"
done
# Re-apply the build's default mask set so a man-db/etc. reinstall cannot
# enable timers that promptLi keeps masked (also silences the
# deb-systemd-helper "preset failed" noise during the installs above).
for unit in systemd-networkd-wait-online.service NetworkManager-wait-online.service \
            ModemManager.service man-db.timer fstrim.timer cron.service \
            wpa_supplicant.service e2scrub_all.timer e2scrub_reap.service \
            systemd-tmpfiles-clean.timer; do
    ln -sf /dev/null "/etc/systemd/system/$unit"
done
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nNAutoVTs=2\n' > /etc/systemd/logind.conf.d/promptli.conf
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/promptli-fbterm.conf << 'DROP'
[Service]
ExecStart=
ExecStart=-/usr/local/bin/promptli-getty %I
DROP
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nRuntimeMaxUse=16M\nRuntimeMaxFileSize=8M\nSystemMaxUse=64M\n' > /etc/systemd/journald.conf.d/promptli.conf

# 5. Mode marker + os-release (idempotent; repairs broken suffixes).
rm -f /etc/promptli/fast
for KEY in PRETTY_NAME VERSION; do
    BASE=$(sed -n -E "s/^${KEY}=\"([^\"]*)\".*/\\1/p" /etc/os-release)
    BASE=${BASE%% fast}; BASE=${BASE%% norm}
    sed -i -E "s|^${KEY}=.*$|${KEY}=\"${BASE} norm\"|" /etc/os-release
done

echo ""
echo "✅ NORM mode restored — aido, zsh, tools back; apt timers re-enabled."
echo "   fastfetch now shows '(norm)'. Reboot for full effect."
X

# pacman: translation wrapper — Debian packages via apt, AUR packages built
# with makedeb. /usr/local/bin wins over /usr/bin/pacman on PATH.
cat > "$INCLUDES/usr/local/bin/pacman" << 'X'; chmod +x "$INCLUDES/usr/local/bin/pacman"
#!/bin/sh
# pacman wrapper for promptLi OS (Debian-based).
#   -S pkg   install: Debian package if it exists, otherwise build from AUR
#   -Syu     apt update + upgrade
#   -Ss q    search Debian repos
#   -Q       list installed packages
#   -R pkg   remove a package
set -e

NEED_ROOT=1
case "$1" in
    -Q*|-Ss*|-Si*|-V|--version|-h|--help|help|"") NEED_ROOT=0 ;;
esac
[ "$(id -u)" = 0 ] || { [ $NEED_ROOT = 0 ] || exec sudo -E "$0" "$@"; }

case "$1" in
    -V|--version)
        echo "pacman (promptLi OS wrapper) $(. /etc/os-release 2>/dev/null; echo "$VERSION_ID")"
        echo "Debian/apt frontend with AUR support via makedeb"
        ;;
    -S)
        shift
        for pkg in "$@"; do
            if apt-cache show "$pkg" >/dev/null 2>&1; then
                apt-get install -y "$pkg"
            else
                echo "-> '$pkg' is not in the Debian repos - building from AUR..."
                tmp="/tmp/aur-$pkg"
                rm -rf "$tmp"
                git clone --depth 1 "https://aur.archlinux.org/$pkg.git" "$tmp"
                # makepkg/makedeb refuse to run as root — drop back to the
                # invoking user for the build (makedeb -s sudo's for deps).
                if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
                    chown -R "$SUDO_USER" "$tmp"
                    runuser -u "$SUDO_USER" -- sh -c "cd '$tmp' && makedeb -si --no-confirm"
                else
                    (cd "$tmp" && makedeb -si --no-confirm)
                fi
            fi
        done
        ;;
    -Sy)
        apt-get update
        ;;
    -Su)
        apt-get upgrade
        ;;
    -Syu|-Suy)
        apt-get update && apt-get upgrade
        ;;
    -Ss)
        apt-cache search "$2"
        ;;
    -Si)
        apt-cache show "$2"
        ;;
    -Q)
        dpkg -l | grep '^ii'
        ;;
    -Qs)
        dpkg -l | grep "$2"
        ;;
    -R|-Rns|-Rs)
        shift
        apt-get remove "$@"
        ;;
    -Sc)
        apt-get clean
        ;;
    -h|--help|help|"")
        cat << 'HELP'
pacman (promptLi OS wrapper)

promptLi OS is Debian-based, so packages install through apt. AUR packages
are built from PKGBUILDs with makedeb and installed the same way.

  pacman -S <pkg>     install (Debian repo first, then AUR build)
  pacman -V           show version
  pacman -Sy          apt update
  pacman -Su          apt upgrade
  pacman -Syu         apt update + upgrade
  pacman -Ss <query>  search
  pacman -Si <pkg>    show package details
  pacman -Q           list installed packages
  pacman -Qs <query>  search installed packages
  pacman -R <pkg>     remove
  pacman -Sc          clear the apt cache

For direct apt use: apt install <pkg>.
HELP
        ;;
    *)
        echo "unknown operation '$1' - run: pacman --help" >&2
        exit 1
        ;;
esac
X

# ── Rust installer + updater ────────────────────────────────
# The installer is built from promptli-installer/ (Cargo) and installed as:
#   /usr/local/bin/promptli-install   (TUI installer)
#   /usr/local/bin/promptli-update    (hardlink/copy — dispatches via argv[0])
#
# Source: prefer the repo's compiled release binary; allow override via env.
INSTALLER_SRC="${PROMPTLI_INSTALLER_BIN:-$SCRIPT_DIR_REPO/promptli-install}"
if [ ! -f "$INSTALLER_SRC" ] && [ -f "$SCRIPT_DIR_REPO/promptli-installer/target/release/promptli-install" ]; then
    INSTALLER_SRC="$SCRIPT_DIR_REPO/promptli-installer/target/release/promptli-install"
fi
if [ -f "$INSTALLER_SRC" ]; then
    cp "$INSTALLER_SRC" "$INCLUDES/usr/local/bin/promptli-install"
    cp "$INSTALLER_SRC" "$INCLUDES/usr/local/bin/promptli-update"
    chmod +x "$INCLUDES/usr/local/bin/promptli-install" "$INCLUDES/usr/local/bin/promptli-update"
    echo "[✓] Bundled Rust installer from $INSTALLER_SRC"
else
    echo "[!] Warning: installer binary not found at $INSTALLER_SRC (run cargo build --release first)"
fi

# ── AIDO: terminal-first local AI assistant ────────────────
# Ships from the aido/ source tree (GUI/tray/voice frontends removed).
AIDO_SRC="$SCRIPT_DIR_REPO/aido"
if [ -d "$AIDO_SRC/src" ]; then
    mkdir -p "$INCLUDES/opt/aido"
    cp -r "$AIDO_SRC/src" "$AIDO_SRC/config" "$INCLUDES/opt/aido/"
    cp "$AIDO_SRC/requirements.txt" "$AIDO_SRC/setup.py" "$INCLUDES/opt/aido/" 2>/dev/null || true
    cat > "$INCLUDES/usr/local/bin/aido" << 'X'; chmod +x "$INCLUDES/usr/local/bin/aido"
#!/bin/sh
# AIDO — local, private AI assistant (terminal edition).
exec python3 /opt/aido/src/aido.py "$@"
X
    echo "[✓] Bundled AIDO assistant from $AIDO_SRC"
else
    echo "[!] Warning: aido/ source tree not found — assistant not bundled"
fi

# ── Vendored packages (makedeb .deb for AUR support) ────
if [ -d "$SCRIPT_DIR_REPO/vendor" ]; then
    mkdir -p "$INCLUDES/opt/promptli/vendor"
    cp -r "$SCRIPT_DIR_REPO/vendor/." "$INCLUDES/opt/promptli/vendor/"
    echo "[✓] Bundled vendor/ (makedeb etc.)"
fi

# ── OS identity: promptLi OS, not "Debian" ────────────────
mkdir -p "$INCLUDES/etc" "$INCLUDES/usr/lib/os-release"
cat > "$INCLUDES/etc/os-release" << X
PRETTY_NAME="promptLi OS ${VERSION} (L1-433)"
NAME="promptLi OS"
VERSION_ID="${VERSION}"
VERSION="${VERSION} (L1-433)"
VERSION_CODENAME=l1-433
ID=promptli
ID_LIKE=debian
HOME_URL="https://webnotes.work/os"
SUPPORT_URL="https://webnotes.work/os"
BUG_REPORT_URL="https://github.com/c4mandry/PromptLi_os/issues"
LOGO=promptli
ANSI_COLOR="38;2;187;154;247"
X
ln -sf /etc/os-release "$INCLUDES/usr/lib/os-release"

# ── Console login notice (MOTD + /etc/issue) ─────────────
mkdir -p "$INCLUDES/etc"
cat > "$INCLUDES/etc/motd" << X

  promptLi OS ${VERSION} (L1-433) - minimal server-focused Debian

  Assistant:  aido             AI:           aido chat
  Packages:   pacman -S pkg    AUR:          pacman -S <aur-pkg>
  Update:     sudo apt upgrade OR sudo pacman -Syu
  Installer:  promptli-install     Shell:    zsh
  Terminal:   promptli-term    Docs:         https://webnotes.work/os

X
# Export the version for the Rust installer/updater (reads PROMPTLI_VERSION).
mkdir -p "$INCLUDES/etc/profile.d"
printf 'export PROMPTLI_VERSION=%s\n' "$VERSION" > "$INCLUDES/etc/profile.d/promptli-version.sh"
cat > "$INCLUDES/etc/issue" << 'X'
\S{PRETTY_NAME} \n \l

X

# ── fastfetch: custom promptLi logo + identity ───────────
mkdir -p "$INCLUDES/etc/fastfetch" "$INCLUDES/etc/skel/.config/fastfetch"
cat > "$INCLUDES/etc/fastfetch/config.jsonc" << 'X'
// promptLi OS fastfetch config — custom logo + clean output.
// Monochrome logo: fastfetch 2.40 defaults a `data` logo to the fallback
// (unknown) OS logo's colors, so we pin color 1 to the terminal default and
// disable bold (brightColor) — the art renders in plain foreground color.
{
    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
    "logo": {
        "type": "data",
        "source": "⠀⠀⠀⠀⠀⢀⣠⣤⣶⣶⣿⣿⣿⣶⣶⣤⡀⠀⠀⠀⠀\n⠀⠀⠀⠀⣴⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣦⡀⠀⠀\n⠀⠀⠀⣼⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣧⠀⠀\n⠀⠀⢠⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡄⠀\n⠀⠀⢸⣿⣿⣿⣿⣿⡏⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⠀\n⠀⠀⠘⣿⣿⣟⡿⢿⣷⢸⠞⠛⢽⣾⣛⡟⣿⣿⣿⠁⠀\n⠀⠀⠀⠻⣿⡟⢶⡿⡿⠀⠀⠀⠀⠹⠯⠏⢸⣿⣿⠀⠀\n⠀⠀⠀⠀⠛⣾⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣼⣿⡏⠀⠀\n⠀⠀⠀⠀⠀⣿⣿⣄⠀⠀⠈⠍⠀⠀⢀⣼⣿⣿⡇⠀⠀\n⠀⠀⠀⠀⠀⠈⠀⠘⢉⠖⠠⠤⠤⠀⠈⡌⣿⡏⠀⠀⠀\n⠀⠀⠀⠀⠀⢀⡠⠔⠊⠀⠀⠀⠀⠀⠀⠈⣿⡀⠀⠀⠀\n⠀⡠⠂⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣿⠈⠁⠂⢄\n⢰⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠘⣆⠀⠀⠈",
        "padding": { "left": 2 },
        "color": { "1": "default" }
    },
    "display": {
        "separator": " ➜ ",
        "brightColor": false
    },
    "modules": [
        "title",
        "separator",
        "os",
        "host",
        "kernel",
        "uptime",
        "packages",
        "shell",
        "cpu",
        "memory",
        "disk",
        "localip",
        "colors"
    ]
}
X
cp "$INCLUDES/etc/fastfetch/config.jsonc" "$INCLUDES/etc/skel/.config/fastfetch/config.jsonc"

# ── zsh: global config + per-user skel (looks good on old terminals) ──
mkdir -p "$INCLUDES/etc/zsh" "$INCLUDES/etc/skel"
cat > "$INCLUDES/etc/zsh/zshrc" << 'X'
# promptLi OS — system-wide zsh configuration.
# Works on 8-color and 256-color terminals alike (no truecolor required).

# ── History ──────────────────────────────────────────────
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt INC_APPEND_HISTORY SHARE_HISTORY EXTENDED_HISTORY HIST_IGNORE_DUPS

# ── Completion ───────────────────────────────────────────
autoload -Uz compinit && compinit -d ~/.zcompdump
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
setopt AUTO_LIST AUTO_MENU COMPLETE_IN_WORD

# ── Editing niceties ─────────────────────────────────────
setopt AUTO_CD CORRECT INTERACTIVE_COMMENTS
autoload -Uz edit-command-line
zle -N edit-command-line
bindkey '^X^E' edit-command-line

# ── Prompt ───────────────────────────────────────────────
# Two variants:
#  - plain Linux console (TERM=linux): pure ASCII so nothing renders as a
#    box in the kernel console font, and cell spacing is perfect.
#  - real terminal emulators: a bit fancier (git branch, ⚡/❯ glyphs).
autoload -Uz vcs_info
precmd() { vcs_info }
zstyle ':vcs_info:git:*' formats '(%b)'
zstyle ':vcs_info:*' enable git
setopt PROMPT_SUBST
if [[ "$TERM" == "linux" ]]; then
    PROMPT='%B%F{green}%n@%m%f%b:%F{cyan}%~%f%F{yellow}${vcs_info_msg_0_}%f%(!.%F{red}#%f.%F{green}$%f) '
else
    PROMPT='%B%F{magenta}⚡%f%b %B%F{cyan}%~%f%b %F{yellow}${vcs_info_msg_0_}%f%(!.%F{red}%n@%m.%F{green}❯)%f '
fi

# ── Aliases (modern tools) ───────────────────────────────
# NOTE: cat stays plain cat — a `cat='batcat ... || cat'` alias recurses in
# zsh (the trailing word is the alias itself) and wedges the line editor.
# bat is available as `bat` if you want syntax-highlighted output.
alias ls='eza --icons=never --color=auto --group-directories-first'
alias ll='eza -lh --icons=never --color=auto --group-directories-first'
alias la='eza -lah --icons=never --color=auto --group-directories-first'
alias bat='batcat --paging=never --style=plain'
alias grep='grep --color=auto'
alias tree='eza --tree --icons=never'
alias mkdir='mkdir -pv'
alias df='df -h'
alias free='free -h'

# ── Keybindings ──────────────────────────────────────────
bindkey '^[[A' up-line-or-search
bindkey '^[[B' down-line-or-search
bindkey '^R' history-incremental-search-backward

# ── Plugin setup (Debian packages) ───────────────────────
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh 2>/dev/null
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh 2>/dev/null
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'

# ── Normal console look ──────────────────────────────────
# promptLi OS logs you into the plain Linux console (perfect character
# spacing, the look every Linux user knows). fbterm is still available as
# an OPT-IN fancy terminal — run `promptli-term` if you want Unicode fonts
# and a wallpaper background.

# ── promptLi autostart (sourced once per login shell) ────
# Drop executable scripts in /etc/promptli/autostart.d/ (system-wide) or
# ~/.config/promptli/autostart.d/ (user) — they run in zsh login shells.
if [[ -o login && -z "$PROMPTLI_AUTOSTART_RAN" ]]; then
    export PROMPTLI_AUTOSTART_RAN=1
    for f in /etc/promptli/autostart.d/*(N.x) ~/.config/promptli/autostart.d/*(N.x); do
        source "$f"
    done
fi

# ── fzf + zoxide ─────────────────────────────────────────
if command -v zoxide >/dev/null 2>&1; then
    eval "$(zoxide init zsh)"
fi
if command -v fzf >/dev/null 2>&1; then
    source /usr/share/doc/fzf/examples/key-bindings.zsh 2>/dev/null
fi
X
cp "$INCLUDES/etc/zsh/zshrc" "$INCLUDES/etc/skel/.zshrc"

# ── fbterm config + launcher + framebuffer wallpaper ─────
# fbterm is OPT-IN (`promptli-term`): the default login uses the plain
# Linux console. DejaVu Sans Mono at 14px has uniform advance widths, which
# avoids the uneven letter spacing that other fonts produce in fbterm.
mkdir -p "$INCLUDES/usr/share/promptli"
cat > "$INCLUDES/etc/skel/.fbtermrc" << 'X'
# promptLi OS fbterm config (used only when running promptli-term).
font-names=DejaVu Sans Mono
font-size=14
text-encodings=UTF-8
X
cat > "$INCLUDES/usr/local/bin/promptli-term" << 'X'; chmod +x "$INCLUDES/usr/local/bin/promptli-term"
#!/bin/sh
# promptLi OS — modern framebuffer terminal launcher.
# Draws a Tokyo Night gradient wallpaper straight into /dev/fb0, then runs
# fbterm on top of it (Unicode fonts + the screenshot as background).
if [ -n "$FBTERM_BACKGROUND_IMAGE" ]; then
    exec fbterm
fi
python3 /opt/promptli/promptli-wallpaper.py >/dev/null 2>&1
sleep 0.2
FBTERM_BACKGROUND_IMAGE=1 exec fbterm
X
cat > "$INCLUDES/opt/promptli/promptli-wallpaper.py" << 'X'
#!/usr/bin/env python3
"""Draw a Tokyo Night gradient directly into the Linux framebuffer.
No dependencies: writes raw pixels to /dev/fb0 (32-bit framebuffers)."""
import mmap, os, sys

FB = "/dev/fb0"
SYS = "/sys/class/graphics/fb0"

TOP = (0x1a, 0x1b, 0x26)     # Tokyo Night bg
BOTTOM = (0x0f, 0x0f, 0x15)  # darker floor
ACCENT = (0xbb, 0x9a, 0xf7)   # purple band

def main():
    if not os.path.exists(FB):
        sys.exit(0)
    try:
        with open(f"{SYS}/bits_per_pixel") as f:
            bpp = int(f.read().strip())
        with open(f"{SYS}/virtual_size") as f:
            w, h = map(int, f.read().strip().split(","))
    except Exception:
        sys.exit(0)
    if bpp not in (32, 24):
        sys.exit(0)
    bytespp = bpp // 8
    fd = os.open(FB, os.O_RDWR)
    size = w * h * bytespp
    mm = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_WRITE)
    buf = bytearray(w * bytespp)
    for y in range(h):
        t = y / max(h - 1, 1)
        r = int(TOP[0] + (BOTTOM[0] - TOP[0]) * t)
        g = int(TOP[1] + (BOTTOM[1] - TOP[1]) * t)
        b = int(TOP[2] + (BOTTOM[2] - TOP[2]) * t)
        # Subtle purple band near the vertical center.
        d = abs(y - h * 0.42) / (h * 0.08 + 1)
        if d < 1:
            k = (1 - d) * 0.35
            r = int(r + (ACCENT[0] - r) * k)
            g = int(g + (ACCENT[1] - g) * k)
            b = int(b + (ACCENT[2] - b) * k)
        off = y * w * bytespp
        for x in range(w):
            buf[x * bytespp] = b          # framebuffer is typically BGRA
            buf[x * bytespp + 1] = g
            buf[x * bytespp + 2] = r
            buf[x * bytespp + 3] = 255
        mm[off:off + len(buf)] = buf
    mm.flush()
    mm.close()
    os.close(fd)

if __name__ == "__main__":
    main()
X

# ── Autostart config system ──────────────────────────────
mkdir -p "$INCLUDES/etc/promptli/autostart.d" "$INCLUDES/etc/skel/.config/promptli/autostart.d"
cat > "$INCLUDES/etc/promptli/autostart.d/10-welcome.sh" << 'X'
# promptLi autostart — runs in zsh login shells.
# Add your own scripts here (system) or ~/.config/promptli/autostart.d/ (user).
if [[ -o interactive && -o login ]]; then
    command -v fastfetch >/dev/null 2>&1 && fastfetch
fi
X
chmod +x "$INCLUDES/etc/promptli/autostart.d/10-welcome.sh"

# ── First-boot setup service ────────────────────────────────
cat > "$INCLUDES/opt/promptli/setup.sh" << 'X'; chmod +x "$INCLUDES/opt/promptli/setup.sh"
#!/bin/sh
# promptLi first-boot setup: user, zsh default, aido deps, AUR tooling.
if ! id promptli >/dev/null 2>&1; then
    useradd -m -s /usr/bin/zsh -G sudo,netdev,video promptli
    echo "promptli:promptli" | chpasswd
fi
# Always sync /etc/skel into the user + root homes (fbtermrc, zshrc, ...)
# in case the live overlay or a pre-existing home is missing them.
cp -r /etc/skel/. /home/promptli/ 2>/dev/null || true
chown -R promptli:promptli /home/promptli 2>/dev/null || true
cp -f /etc/skel/.fbtermrc /root/.fbtermrc 2>/dev/null || true
cp -f /etc/skel/.zshrc /root/.zshrc 2>/dev/null || true
chsh -s /usr/bin/zsh root 2>/dev/null || true
# aido's light deps (PyYAML, requests) come from Debian packages; no pip
# install is needed at first boot.
# AUR: if mist isn't installed yet (makedeb repo was down during the build),
# retry now that the machine is online.
if ! command -v mist >/dev/null 2>&1; then
    echo "  [*] Retrying mist install (AUR support)..."
    wget -qO- --timeout=10 'https://proget.makedeb.org/releases/makedeb/makedeb.pub' 2>/dev/null | \
        gpg --dearmor > /usr/share/keyrings/makedeb-archive-keyring.gpg 2>/dev/null || true
    if [ -s /usr/share/keyrings/makedeb-archive-keyring.gpg ]; then
        echo 'deb [signed-by=/usr/share/keyrings/makedeb-archive-keyring.gpg arch=all] https://proget.makedeb.org makedeb main' \
            > /etc/apt/sources.list.d/makedeb.list
        apt-get update -qq 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mist 2>/dev/null || true
    fi
fi
if command -v mist >/dev/null 2>&1; then
    echo "  [ok] AUR ready: mist install <package>"
else
    echo "  [ok] AUR available via: pacman -S <aur-package> (makedeb)"
fi
systemctl disable promptli-setup.service 2>/dev/null || true
X

# Systemd service
mkdir -p "$INCLUDES/etc/systemd/system/multi-user.target.wants"
cat > "$INCLUDES/etc/systemd/system/promptli-setup.service" << 'X'
[Unit]
Description=promptLi first boot setup
After=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/promptli/setup.sh
[Install]
WantedBy=multi-user.target
X
ln -sf /etc/systemd/system/promptli-setup.service "$INCLUDES/etc/systemd/system/multi-user.target.wants/promptli-setup.service"

# Hostname + hosts (no live-config: we set both ourselves)
echo "promptli" > "$INCLUDES/etc/hostname"
cat > "$INCLUDES/etc/hosts" << 'X'
127.0.0.1	localhost
127.0.1.1	promptli

# The following lines are desirable for IPv6 capable hosts
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
X

# ── Hooks ───────────────────────────────────────────────
mkdir -p config/hooks/normal
cat > config/hooks/normal/9999-promptli-customize.hook.chroot << 'HOOK'
#!/bin/bash
echo "⚡ Customizing promptLi OS..."

# ── Console keymap: make console-setup own it ─────────────
# On Debian, the *console* keymap is derived from /etc/default/keyboard via
# console-setup (setupcon/ckbcomp), NOT from /etc/vconsole.conf. Setting
# KEYMAP=et in vconsole.conf without the matching console-setup cache leaves
# loadkeys with no usable keymap -> every keypress spits <ffffffff> (dead
# keys / bad codepoints) and colored backgrounds. So: set the layout in
# /etc/default/keyboard and regenerate the cached keymap so keyboard-setup
# and console-setup load it at boot. vconsole.conf gets a real KEYMAP= too
# for systemd-vconsole-setup (harmless and correct if present).
echo "  [*] Setting console keymap (et) via console-setup..."
mkdir -p /etc/default
cat > /etc/default/keyboard << 'KB'
XKBMODEL="pc105"
XKBLAYOUT="et"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KB
# Regenerate the console keymap cache from the XKB layout above.
if command -v setupcon >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive setupcon --force --save 2>/dev/null || true
fi

# ── AUR support: makedeb + mist (install AUR packages on Debian) ──
# makedeb is vendored (vendor/makedeb/*.deb) so the build works offline;
# mist comes from the makedeb repo and is retried at first boot if it's down.
echo "  [*] Setting up AUR support (makedeb + mist)..."
VENDOR_DEB=$(find /opt/promptli/vendor/makedeb -name '*.deb' 2>/dev/null | head -1)
if [ -n "$VENDOR_DEB" ] && ! command -v makedeb >/dev/null 2>&1; then
    # --force-overwrite: Debian's makepkg (a pacman dep) also ships
    # /etc/makepkg.conf; makedeb's version is a compatible superset.
    DEBIAN_FRONTEND=noninteractive dpkg -i --force-overwrite "$VENDOR_DEB" 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -f -qq 2>/dev/null || true
fi
# The vendored .deb is a bullseye build whose makedeb-rs links
# libapt-pkg.so.6.0 — trixie ships .7.0. Replace it with a binary built
# from source against trixie's apt (vendor/makedeb/makedeb-rs).
VENDOR_RS=/opt/promptli/vendor/makedeb/makedeb-rs
if [ -f "$VENDOR_RS" ] && [ -f /usr/share/makedeb/makedeb-rs ]; then
    cp -f "$VENDOR_RS" /usr/share/makedeb/makedeb-rs
    chmod +x /usr/share/makedeb/makedeb-rs
    echo "  [✓] makedeb-rs replaced with trixie build"
fi
# Try the makedeb repo for mist (may be offline; setup.sh retries on first boot).
if ! command -v mist >/dev/null 2>&1; then
    wget -qO- --timeout=10 'https://proget.makedeb.org/releases/makedeb/makedeb.pub' 2>/dev/null | \
        gpg --dearmor > /usr/share/keyrings/makedeb-archive-keyring.gpg 2>/dev/null || true
    if [ -s /usr/share/keyrings/makedeb-archive-keyring.gpg ]; then
        echo 'deb [signed-by=/usr/share/keyrings/makedeb-archive-keyring.gpg arch=all] https://proget.makedeb.org makedeb main' \
            > /etc/apt/sources.list.d/makedeb.list
        apt-get update -qq 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mist 2>/dev/null || true
    fi
fi
if command -v makedeb >/dev/null 2>&1; then echo "  [✓] makedeb installed"; else echo "  [!] makedeb install failed"; fi
if command -v mist >/dev/null 2>&1; then echo "  [✓] mist installed (AUR ready)"; else echo "  [!] mist not available yet (repo offline; retried at first boot)"; fi

# ── Fix makepkg.conf architecture for AUR builds ──────────
# Debian's pacman-package-manager ships CARCH="$(uname -p)" — but Debian
# kernels report "unknown" for uname -p (Arch's report x86_64), so makedeb
# rejects every AUR PKGBUILD with arch=('x86_64'):
#   "yay is not available for the 'amd64' architecture."
# makepkg's canonical arch comes from uname -m; use that instead.
if [ -f /etc/makepkg.conf ]; then
    sed -i 's|CARCH="\$(uname -p)"|CARCH="$(uname -m)"|' /etc/makepkg.conf
    sed -i 's|CHOST="\$(uname -p)-pc-linux-gnu"|CHOST="$(uname -m)-pc-linux-gnu"|' /etc/makepkg.conf
    grep -q 'CARCH="\$(uname -m)"' /etc/makepkg.conf && echo "  [✓] makepkg.conf CARCH fixed (uname -m)" || echo "  [!] makepkg.conf CARCH patch did not apply"
fi

# ── Fast boot + low idle RAM tweaks ─────────────────────
echo "  [*] Applying boot-speed + RAM tweaks..."
# systemctl needs dbus, which doesn't exist inside a build chroot — masking
# is just a symlink to /dev/null, so do that directly.
# NOTE: apt-daily.timer / apt-daily-upgrade.timer are KEPT enabled — promptLi
# OS updates through apt, so background update checks are desired.
for unit in systemd-networkd-wait-online.service \
            NetworkManager-wait-online.service \
            ModemManager.service \
            man-db.timer fstrim.timer \
            cron.service \
            wpa_supplicant.service \
            e2scrub_all.timer e2scrub_reap.service \
            systemd-tmpfiles-clean.timer; do
    ln -sf /dev/null "/etc/systemd/system/$unit"
done
# Raise systemd's default timeout (older/slow disks) and keep quiet boot.
mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\nDefaultTimeoutStartSec=45s\nDefaultTimeoutStopSec=20s\n' > /etc/systemd/system.conf.d/promptli.conf

# Cap journald's RAM usage (live sessions run journald in tmpfs).
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nRuntimeMaxUse=16M\nRuntimeMaxFileSize=8M\nSystemMaxUse=64M\n' > /etc/systemd/journald.conf.d/promptli.conf

# Fewer virtual terminals: 2 gettys instead of 6 (each ~3MB).
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nNAutoVTs=2\n' > /etc/systemd/logind.conf.d/promptli.conf

# ── Networking: systemd-networkd + resolved (no NM/dbus bloat) ──
echo "  [*] Enabling systemd-networkd + resolved..."
# live-config is gone, so purge it (and the dbus daemon family it dragged
# in) and replace the system bus with the lighter/faster dbus-broker.
# Order matters a lot here:
#  - installing dbus-broker first keeps systemd-resolved's dependency graph
#    satisfiable, but the purge still removes both (dbus-broker depends on
#    dbus-system-bus-common, resolved on a system bus), so both are
#    reinstalled afterwards with no recommends (that would pull dbus back).
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dbus-broker 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
    live-config live-config-systemd live-config-doc \
    dbus dbus-bin dbus-daemon dbus-session-bus-common dbus-system-bus-common \
    2>/dev/null || true
apt-get autoremove -y -qq 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    dbus-broker systemd-resolved 2>/dev/null || true

# ── Console keymap/font data must survive autoremove ────────
# `kbd` (the kernel keymap files in /usr/share/keymaps/i386) and console-setup
# fonts are sometimes marked auto and stripped by the autoremove above, which
# leaves KEYMAP=et in /etc/vconsole.conf pointing at data that no longer
# exists — the kernel then falls back to a broken default keymap and every
# keypress prints <ffffffff> or colored garbage. Reinstall them explicitly
# and mark them manually-installed so a later autoremove won't take them.
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    kbd console-setup console-setup-linux keyboard-configuration 2>/dev/null || true
apt-mark manual kbd console-setup console-setup-linux keyboard-configuration 2>/dev/null || true
# Keep a real KEYMAP= in /etc/vconsole.conf too (harmless; systemd-vconsole-
# setup loads it where present, and keyboard-setup uses the console-setup cache).
if [ -L /etc/vconsole.conf ]; then
    rm -f /etc/vconsole.conf
fi
printf 'KEYMAP=et\nFONT=Lat2-Terminus16\n' > /etc/vconsole.conf
# Also stop Debian's tmpfiles rule (usr/lib/tmpfiles.d/debian.conf) from
# re-symlinking /etc/vconsole.conf to /etc/default/keyboard at boot; an
# /etc/tmpfiles.d file with the SAME name shadows it entirely.
mkdir -p /etc/tmpfiles.d
cat > /etc/tmpfiles.d/debian.conf << 'TC'
# promptLi: shadows Debian's debian.conf — keeps the console keymap instead
# of re-symlinking /etc/vconsole.conf to /etc/default/keyboard.
L /run/shm - - - - /dev/shm
d /run/sendsigs.omit.d 0755 root root -
d /run/lock 1777 root root -
L+ /etc/mtab - - - - ../proc/self/mounts
L+ /etc/default/locale - - - - ../locale.conf
f /etc/vconsole.conf 0644 root root - KEYMAP=et\nFONT=Lat2-Terminus16\n
TC
# dbus-broker does not ship a dbus.socket unit (the purged dbus package owned
# it) and without it the broker can never be socket-activated — logins would
# stall ~25s in pam_systemd. Ship our own socket unit and enable it.
cat > /etc/systemd/system/dbus.socket << 'SOCK'
[Unit]
Description=D-Bus System Message Bus Socket
Documentation=man:dbus-broker-launch(1)
Before=sockets.target

[Socket]
ListenStream=/run/dbus/system_bus_socket
SocketMode=0666
Accept=no

[Install]
WantedBy=sockets.target
SOCK
ln -sf /usr/lib/systemd/system/dbus-broker.service /etc/systemd/system/dbus.service
ln -sf /etc/systemd/system/dbus.socket /etc/systemd/system/sockets.target.wants/dbus.socket
ln -sf /lib/systemd/system/systemd-networkd.service /etc/systemd/system/multi-user.target.wants/systemd-networkd.service
ln -sf /lib/systemd/system/systemd-networkd.socket /etc/systemd/system/sockets.target.wants/systemd-networkd.socket
ln -sf /lib/systemd/system/systemd-resolved.service /etc/systemd/system/multi-user.target.wants/systemd-resolved.service
ln -sf /lib/systemd/system/systemd-resolved.socket /etc/systemd/system/sockets.target.wants/systemd-resolved.socket

# ── No display managers on a server distro ─────────────────
# promptLi OS boots to a console TTY only; purge any display manager that
# could sneak in through dependency chains (lightdm, gdm3, sddm, xdm).
echo "  [*] Purging display managers..."
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
    lightdm lightdm-gtk-greeter gdm3 sddm xdm 2>/dev/null || true
apt-get autoremove -y -qq 2>/dev/null || true
rm -f /etc/systemd/system/display-manager.service
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-wired.network << 'NET'
[Match]
Type=ether

[Network]
DHCP=yes

[DHCP]
RouteMetric=10
NET
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# ── Ensure resolv.conf at boot ─────────────────────────────
# live-build empties /etc/resolv.conf after the chroot hooks, so the
# symlink above does not survive into the image. Recreate it at boot
# (before resolved/networkd come up) so tools that read resolv.conf
# directly see the stub. libnss-resolve already handles most lookups.
mkdir -p /etc/systemd/system/sysinit.target.wants
cat > /etc/systemd/system/promptli-resolvconf.service << 'SVC'
[Unit]
Description=Link /etc/resolv.conf to systemd-resolved stub
DefaultDependencies=no
After=systemd-tmpfiles-setup.service
Before=systemd-resolved.service network.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'rm -f /etc/resolv.conf && ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf'
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
SVC
ln -sf /etc/systemd/system/promptli-resolvconf.service /etc/systemd/system/sysinit.target.wants/promptli-resolvconf.service

# ── NO autologin ──────────────────────────────────────────
# live-config ships a systemd generator that auto-logs the live user in on
# tty1-6. promptLi OS is a server distro — always ask for credentials.
echo "  [*] Removing live-config tty autologin generator..."
rm -f /lib/systemd/system-generators/live-config-getty-generator

# ── Serial console: use the same TERM as the VGA console ──
# serial-getty@.service defaults to TERM=vt220, which makes zsh's prompt
# rendering unreliable (glitched prompts / wedged line editor on some
# clients). TERM=linux gives the plain ASCII prompt everywhere.
mkdir -p /etc/systemd/system/serial-getty@.service.d
printf '[Service]\nEnvironment=TERM=linux\n' > /etc/systemd/system/serial-getty@.service.d/term.conf

# ── tty1: Unicode framebuffer console (fbterm) ────────────
# The main console runs fbterm when a framebuffer exists, so the promptLi
# logo (braille block glyphs) and Unicode render properly on the screen you
# log into. Falls back to the plain Linux console on headless/serial
# machines and VMs without a framebuffer; tty2+/ttyS0 stay plain getty.
echo "  [*] tty1 -> fbterm (Unicode console)..."
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/promptli-fbterm.conf << 'DROP'
[Service]
ExecStart=
ExecStart=-/usr/local/bin/promptli-getty %I
DROP
cat > /usr/local/bin/promptli-getty << 'GTY'
#!/bin/sh
# promptLi tty1 launcher: fbterm (Unicode/braille-capable console) when a
# framebuffer exists AND fbterm actually starts. If fbterm fails (some GPUs
# / DRM framebuffers it cannot handle), fall back to the plain Linux console
# so a login prompt is ALWAYS available — a broken tty1 must never lock the
# user out. The failure is remembered for this boot via a stamp file.
# NOTE: getty@tty1 passes %I = "tty1" (WITH the prefix), so use it as-is.
TTY="${1:-tty1}"
STAMP=/run/promptli-no-fbterm
if [ -e /dev/fb0 ] && command -v fbterm >/dev/null 2>&1 && [ ! -e "$STAMP" ]; then
    if fbterm -s 14 -- /bin/login -p; then
        exit 0
    fi
    : > "$STAMP" 2>/dev/null || true
fi
exec /sbin/agetty --noclear --login-program /bin/login "$TTY" 115200 linux
GTY
chmod +x /usr/local/bin/promptli-getty
cat > /root/.fbtermrc << 'RC'
font-names=DejaVu Sans Mono
font-size=14
text-encodings=UTF-8
RC

# ── Default user: created at build time (not first boot) ──
echo "  [*] Creating default user 'promptli'..."
if ! id promptli >/dev/null 2>&1; then
    useradd -m -s /usr/bin/zsh -G sudo,netdev,video promptli
    echo 'promptli:promptli' | chpasswd
    cp -r /etc/skel/. /home/promptli/ 2>/dev/null || true
    chown -R promptli:promptli /home/promptli
fi
chsh -s /usr/bin/zsh root 2>/dev/null || true

# ── Permissions ─────────────────────────────────────────
echo "  [*] Fixing permissions..."
chown -R root:root /opt/promptli /opt/aido
chmod +x /usr/local/bin/promptli /usr/local/bin/locakhost /usr/local/bin/aido
chmod +x /usr/local/bin/pacman /usr/local/bin/promptli-term
chmod +x /usr/local/bin/promptli-fast /usr/local/bin/promptli-norm
chmod +x /opt/promptli/setup.sh
chmod +x /opt/promptli/promptli-wallpaper.py
chmod +x /opt/aido/src/aido.py
echo "✅ Done."
HOOK
chmod +x config/hooks/normal/9999-promptli-customize.hook.chroot

# ── BUILD ───────────────────────────────────────────────
echo ""
echo "[*] Building ISO (this takes 10-20 minutes)..."
echo ""

lb build 2>&1 | tee "$BUILD_DIR/build.log"

# Copy output
mkdir -p "$OUTPUT_DIR"
ISO_OUTPUT=$(find . -maxdepth 2 -name '*.iso' -print -quit)
if [ -n "$ISO_OUTPUT" ]; then
    cp "$ISO_OUTPUT" "$OUTPUT_DIR/$ISO_NAME.iso"
else
    echo "WARNING: no ISO found in build tree."
fi

# (Re)generate the release manifest so the website /api/os/latest always
# matches the freshly built ISO (sha256 + size are recomputed here).
ISO_PATH="$OUTPUT_DIR/$ISO_NAME.iso"
if [ -f "$ISO_PATH" ]; then
    ISO_SHA=$(sha256sum "$ISO_PATH" | cut -d' ' -f1)
    ISO_SIZE=$(stat -c %s "$ISO_PATH")
    ISO_DATE=$(date -u +%Y-%m-%d)
    cat > "$OUTPUT_DIR/latest.json" << JSON
{
  "name": "promptLi OS",
  "version": "${VERSION}",
  "codename": "L1-433",
  "base": "Debian 13 (trixie)",
  "arch": "amd64",
  "iso_filename": "$ISO_NAME.iso",
  "iso_url": "/api/os/iso",
  "sha256": "$ISO_SHA",
  "size_bytes": $ISO_SIZE,
  "released_at": "$ISO_DATE",
  "release_notes": [
    "Minimal, bloat-free base — no window manager, no desktop environment",
    "aido — private, offline local AI assistant (terminal-first)",
    "pacman works: Debian packages via apt, AUR packages built with makedeb",
    "Plain Linux console by default; fbterm opt-in via promptli-term",
    "zsh with autosuggestions, syntax highlighting, and a git-aware prompt",
    "systemd-networkd + resolved networking (no NetworkManager bloat)",
    "Custom fastfetch identity with the promptLi OS logo",
    "Rust TUI installer (promptli-install); updates via apt/pacman -Syu",
    "Fast, quiet boot with low idle RAM (capped journald, 2 gettys)",
    "locakHost local web server"
  ],
  "default_credentials": {
    "user": "promptli",
    "password": "promptli"
  }
}
JSON
    echo "[✓] Regenerated $OUTPUT_DIR/latest.json (sha256 $ISO_SHA)"
fi

# The web server (running as the invoking user, not root) must be able to
# write enrollments.jsonl + latest.json into this directory.
OUT_OWNER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
chown "$OUT_OWNER":"$(id -gn "$OUT_OWNER" 2>/dev/null || echo root)" "$OUTPUT_DIR" "$OUTPUT_DIR/$ISO_NAME.iso" "$OUTPUT_DIR/latest.json" 2>/dev/null || true

echo ""
echo "================================================"
echo "  ✅ promptLi OS built successfully!"
echo "  📀 $OUTPUT_DIR/$ISO_NAME.iso"
echo "  📏 $(du -h "$OUTPUT_DIR/$ISO_NAME.iso" | cut -f1)"
echo "================================================"

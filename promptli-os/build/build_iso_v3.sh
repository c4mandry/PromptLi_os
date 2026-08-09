#!/bin/bash
# ============================================================
#  promptLi OS — ISO Builder v3 (mmdebstrap + xorriso)
#  Tested on Apple Silicon with OrbStack + Rosetta 2
# ============================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/work"
OUTPUT_DIR="$PROJECT_DIR/build/output"
ISO_NAME="promptli-os-1.0.0-amd64"

echo "⚡ promptLi OS ISO Builder v3"
echo "============================"

rm -rf "$BUILD_DIR" "$OUTPUT_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# ── Check Docker ────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    echo "[✗] Docker required."
    exit 1
fi

# ── Build Docker image (if needed) ──────────────────────
IMAGE="promptli-builder-v3"
echo "[*] Building Docker image..."
docker build --platform linux/amd64 --no-cache -t "$IMAGE" -f - "$PROJECT_DIR" << 'DOCKERFILE'
FROM --platform=linux/amd64 debian:13-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    mmdebstrap fakeroot fakechroot \
    xorriso isolinux syslinux-common syslinux-efi \
    squashfs-tools rsync dosfstools mtools cpio \
    gzip xz-utils wget curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
DOCKERFILE

echo "[*] Running build in Docker..."

# ── Run build ───────────────────────────────────────────
docker run --rm --privileged --platform linux/amd64 \
    -v "$PROJECT_DIR:/project:ro" \
    -v "$BUILD_DIR:/build" \
    -v "$OUTPUT_DIR:/output" \
    "$IMAGE" /usr/bin/bash -c '
set -euo pipefail

ISO_NAME="promptli-os-1.0.0-amd64"
CHROOT="/build/chroot"
OUTDIR="/output"

# ── Step 1: Bootstrap with mmdebstrap ────────────────
echo "[1/5] Bootstrapping Debian base system..."

# Create hook to prevent service starts during bootstrap
mkdir -p /tmp/hooks
cat > /tmp/hooks/setup-policy.sh << "HOOKEOF"
#!/bin/bash
mkdir -p "$1/usr/sbin"
cat > "$1/usr/sbin/policy-rc.d" << "POL"
#!/bin/sh
exit 101
POL
chmod +x "$1/usr/sbin/policy-rc.d"
HOOKEOF
chmod +x /tmp/hooks/setup-policy.sh

# Build the chroot
mmdebstrap \
    --mode unshare \
    --arch amd64 \
    --variant important \
    --components "main contrib non-free non-free-firmware" \
    --hook-dir=/tmp/hooks \
    --include="\
        linux-image-amd64,live-boot,systemd,systemd-sysv,sudo,\
        xorg,xinit,x11-xserver-utils,xterm,\
        i3-wm,i3status,i3lock,dmenu,suckless-tools,\
        picom,feh,xcompmgr,\
        fonts-jetbrains-mono,fonts-font-awesome,fonts-noto,\
        network-manager,network-manager-gnome,wireless-tools,wpasupplicant,\
        pulseaudio,pavucontrol,alsa-utils,\
        curl,wget,git,vim,htop,neofetch,unzip,p7zip-full,\
        scrot,xclip,brightnessctl,arandr,lxappearance,\
        python3,python3-pip,python3-tk,python3-pil,python3-pil.imagetk,\
        alacritty,thunar,gvfs,gvfs-backends,\
        lightdm,lightdm-gtk-greeter,policykit-1,\
        libasound2,libdbus-glib-1-2,libgtk-3-0,libfuse2,fuse,\
        rsync\
    " \
    trixie \
    "$CHROOT" \
    http://deb.debian.org/debian

# Remove policy-rc.d after bootstrap
rm -f "$CHROOT/usr/sbin/policy-rc.d"

echo "[1/5] OK"

# ── Step 2: Copy promptLi custom files ────────────────
echo "[2/5] Installing promptLi files..."

# App
mkdir -p "$CHROOT/opt/promptli/assets" "$CHROOT/opt/promptli/tools"
cp /project/assistant/promptli_assistant.py "$CHROOT/opt/promptli/"
cp /project/assistant/promptli_daemon.py "$CHROOT/opt/promptli/"
cp /project/assistant/requirements.txt "$CHROOT/opt/promptli/"
cp /project/assistant/assets/wallpaper.svg "$CHROOT/opt/promptli/assets/" 2>/dev/null || true

# locakHost
cp /project/tools/locakhost.py "$CHROOT/opt/promptli/tools/"

# Desktop entries
mkdir -p "$CHROOT/usr/share/applications"
cp /project/assistant/promptli.desktop "$CHROOT/usr/share/applications/"
cp /project/tools/locakhost.desktop "$CHROOT/usr/share/applications/"

# CLI wrappers (type locakhost or promptli from terminal)
cat > "$CHROOT/usr/local/bin/promptli" << "WRAP"
#!/bin/bash
exec python3 /opt/promptli/promptli_assistant.py "$@"
WRAP
chmod +x "$CHROOT/usr/local/bin/promptli"

cat > "$CHROOT/usr/local/bin/locakhost" << "WRAP"
#!/bin/bash
exec python3 /opt/promptli/tools/locakhost.py "$@"
WRAP
chmod +x "$CHROOT/usr/local/bin/locakhost"

# i3 config
mkdir -p "$CHROOT/etc/skel/.config/i3" "$CHROOT/etc/skel/.config/i3status"
cp /project/config/i3/config "$CHROOT/etc/skel/.config/i3/config"
cp /project/config/i3/i3status.conf "$CHROOT/etc/skel/.config/i3status/config"

# i3 autostart
echo "" >> "$CHROOT/etc/skel/.config/i3/config"
echo "exec --no-startup-id ~/.config/autostart.sh" >> "$CHROOT/etc/skel/.config/i3/config"

# picom config
mkdir -p "$CHROOT/etc/skel/.config/picom"
cat > "$CHROOT/etc/skel/.config/picom/picom.conf" << "PICOM"
backend = "glx";
vsync = true;
shadow = true;
shadow-radius = 12;
shadow-opacity = 0.5;
shadow-offset-x = -8;
shadow-offset-y = -8;
fading = true;
inactive-opacity = 0.9;
corner-radius = 8;
PICOM

# Autostart script
cat > "$CHROOT/etc/skel/.config/autostart.sh" << "STARTUP"
#!/bin/bash
picom --config ~/.config/picom/picom.conf &
feh --bg-fill /opt/promptli/assets/wallpaper.svg &
nm-applet &
promptli &
STARTUP
chmod +x "$CHROOT/etc/skel/.config/autostart.sh"

# Root user config too
mkdir -p "$CHROOT/root/.config/i3" "$CHROOT/root/.config/i3status"
cp /project/config/i3/config "$CHROOT/root/.config/i3/config"
cp /project/config/i3/i3status.conf "$CHROOT/root/.config/i3status/config"

# LightDM autologin
mkdir -p "$CHROOT/etc/lightdm"
cat > "$CHROOT/etc/lightdm/lightdm.conf" << "LIGHTDM"
[Seat:*]
autologin-user=promptli
autologin-user-timeout=0
user-session=i3
greeter-session=lightdm-gtk-greeter
LIGHTDM

# First-boot setup service
cat > "$CHROOT/etc/systemd/system/promptli-setup.service" << "UNIT"
[Unit]
Description=promptLi OS first boot setup
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/promptli/setup.sh

[Install]
WantedBy=multi-user.target
UNIT

cat > "$CHROOT/opt/promptli/setup.sh" << "SETUP"
#!/bin/bash
set -e

echo "⚡ Running promptLi OS first-boot setup..."

# Create default user
if ! id promptli &>/dev/null; then
    useradd -m -s /bin/bash -G sudo,audio,video,netdev promptli
    echo "promptli:promptli" | chpasswd
    cp -r /etc/skel/. "$(getent passwd promptli | cut -d: -f6)/"
    chown -R promptli:promptli "$(getent passwd promptli | cut -d: -f6)"
fi

# Install Zen Browser (default & only browser)
if [ ! -f /opt/zen-browser/zen ]; then
    echo "  Installing Zen Browser..."
    mkdir -p /opt/zen-browser
    cd /tmp
    wget -q "https://github.com/zen-browser/desktop/releases/latest/download/zen.linux-x86_64.tar.xz" -O zen.tar.xz
    tar -xf zen.tar.xz -C /opt/zen-browser/ --strip-components=1
    rm zen.tar.xz
    ln -sf /opt/zen-browser/zen /usr/local/bin/zen-browser
    update-alternatives --install /usr/bin/x-www-browser x-www-browser /opt/zen-browser/zen 100
    update-alternatives --set x-www-browser /opt/zen-browser/zen
fi

# Zen Browser desktop entry
cat > /usr/share/applications/zen-browser.desktop << "ZEN"
[Desktop Entry]
Name=Zen Browser
Comment=Browse the web
Exec=/opt/zen-browser/zen %u
Icon=/opt/zen-browser/browser/chrome/icons/default/default128.png
Type=Application
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
Terminal=false
ZEN

# Install Python deps
pip3 install --break-system-packages anthropic 2>/dev/null || true

# Self-disable
systemctl disable promptli-setup.service
echo "✅ Setup complete."
SETUP
chmod +x "$CHROOT/opt/promptli/setup.sh"

# Enable first-boot service
mkdir -p "$CHROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/promptli-setup.service "$CHROOT/etc/systemd/system/multi-user.target.wants/promptli-setup.service"

# Hostname
echo "promptli" > "$CHROOT/etc/hostname"
echo "127.0.0.1 localhost promptli" > "$CHROOT/etc/hosts"

# Enable LightDM
ln -sf /lib/systemd/system/lightdm.service "$CHROOT/etc/systemd/system/display-manager.service" 2>/dev/null || true
mkdir -p "$CHROOT/etc/systemd/system/multi-user.target.wants"

# Enable NetworkManager
ln -sf /lib/systemd/system/NetworkManager.service "$CHROOT/etc/systemd/system/multi-user.target.wants/NetworkManager.service" 2>/dev/null || true

echo "[2/5] OK"

# ── Step 3: Clean up ──────────────────────────────────
echo "[3/5] Cleaning up..."
rm -rf "$CHROOT/var/lib/apt/lists/"* "$CHROOT/var/cache/apt/"*
echo "[3/5] OK"

# ── Step 4: Create squashfs ───────────────────────────
echo "[4/5] Creating squashfs filesystem..."
mkdir -p /build/iso/live
mksquashfs "$CHROOT" /build/iso/live/filesystem.squashfs \
    -comp xz -b 1048576 -Xdict-size 100% -noappend \
    -e boot/ -e var/cache/ -e var/lib/apt/lists/ -e dev/ -e proc/ -e sys/ -e tmp/ -e run/
echo "[4/5] OK ($(du -h /build/iso/live/filesystem.squashfs | cut -f1))"

# ── Step 5: Build ISO ─────────────────────────────────
echo "[5/5] Building bootable ISO..."

# Kernel and initrd
cp "$CHROOT/boot/vmlinuz-"* /build/iso/live/vmlinuz 2>/dev/null || true
cp "$CHROOT/boot/initrd.img-"* /build/iso/live/initrd.img 2>/dev/null || true

# ISOLINUX bootloader
mkdir -p /build/iso/isolinux
cp /usr/lib/ISOLINUX/isolinux.bin /build/iso/isolinux/ 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 /build/iso/isolinux/ 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/libcom32.c32 /build/iso/isolinux/ 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/libutil.c32 /build/iso/isolinux/ 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/menu.c32 /build/iso/isolinux/ 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/vesamenu.c32 /build/iso/isolinux/ 2>/dev/null || true

cat > /build/iso/isolinux/isolinux.cfg << "ISOCFG"
UI vesamenu.c32
MENU TITLE promptLi OS 1.0.0
DEFAULT live
TIMEOUT 50
PROMPT 0

LABEL live
    MENU LABEL Boot promptLi OS
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img boot=live quiet splash
ISOCFG

# Create ISO with xorriso
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "promptLiOS" \
    -appid "promptLi OS 1.0.0" \
    -publisher "promptLi" \
    -preparer "promptLi OS Builder" \
    -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -output "/output/$ISO_NAME.iso" \
    /build/iso/ 2>&1

echo ""
echo "========================================="
echo "  ✅ promptLi OS ISO built!"
echo "  📀 /output/$ISO_NAME.iso"
echo "  📏 $(du -h /output/$ISO_NAME.iso | cut -f1)"
echo "========================================="
'

echo ""
echo "========================================="
echo "  ✅ Build complete!"
echo "  📀 $OUTPUT_DIR/$ISO_NAME.iso"
echo "========================================="
ls -lh "$OUTPUT_DIR/" 2>/dev/null

#!/bin/bash
# ============================================================
#  promptLi OS — ISO Builder v2 (mmdebstrap + xorriso)
#  Works on Apple Silicon with QEMU emulation
# ============================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/work"
OUTPUT_DIR="$PROJECT_DIR/build/output"
ISO_NAME="promptli-os-1.0.0-amd64"
CHROOT_DIR="$BUILD_DIR/chroot"

echo "⚡ promptLi OS ISO Builder v2"
echo "============================"

rm -rf "$BUILD_DIR" "$OUTPUT_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR" "$CHROOT_DIR"

# ── Check Docker ────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    echo "[✗] Docker required. Please install Docker or OrbStack."
    exit 1
fi

# ── Pull/check Docker image ─────────────────────────────
IMAGE="promptli-builder"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[*] Building Docker image..."
    docker build --platform linux/amd64 -t "$IMAGE" -f - "$PROJECT_DIR" << 'DOCKERFILE'
FROM --platform=linux/amd64 debian:13-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    mmdebstrap xorriso isolinux syslinux-common syslinux-efi \
    squashfs-tools rsync dosfstools mtools cpio \
    gzip xz-utils wget curl ca-certificates \
    linux-image-amd64 live-boot systemd systemd-sysv \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
ENTRYPOINT ["/bin/bash"]
DOCKERFILE
fi

echo "[*] Building promptLi OS filesystem..."

# ── Run build in Docker ─────────────────────────────────
docker run --rm --privileged --platform linux/amd64 \
    -v "$PROJECT_DIR:/project:ro" \
    -v "$BUILD_DIR:/build" \
    -v "$OUTPUT_DIR:/output" \
    "$IMAGE" \
    -c '
set -euo pipefail

ISO_NAME="promptli-os-1.0.0-amd64"
CHROOT="/build/chroot"
OUTDIR="/output"

# ── Step 1: Bootstrap base Debian with mmdebstrap ─────
echo "[1/5] Bootstrapping base Debian system..."
mmdebstrap \
    --arch amd64 \
    --variant minbase \
    --components "main contrib non-free non-free-firmware" \
    --include="
        linux-image-amd64,live-boot,systemd,systemd-sysv,sudo,
        xorg,xinit,x11-xserver-utils,xterm,
        i3-wm,i3status,i3lock,dmenu,suckless-tools,
        picom,feh,xcompmgr,
        fonts-jetbrains-mono,fonts-font-awesome,fonts-noto,fonts-noto-cjk,
        network-manager,network-manager-gnome,wireless-tools,wpasupplicant,
        pulseaudio,pavucontrol,alsa-utils,pulseaudio-module-bluetooth,
        curl,wget,git,vim,htop,neofetch,unzip,p7zip-full,
        scrot,xclip,brightnessctl,arandr,lxappearance,
        python3,python3-pip,python3-tk,python3-pil,python3-pil.imagetk,
        alacritty,thunar,gvfs,gvfs-backends,
        lightdm,lightdm-gtk-greeter,policykit-1,
        libasound2,libdbus-glib-1-2,libgtk-3-0,libfuse2,fuse,
        rsync
    " \
    trixie \
    "$CHROOT" \
    http://deb.debian.org/debian

echo "[1/5] Base system bootstrapped."

# ── Step 2: Copy custom promptLi files ────────────────
echo "[2/5] Installing promptLi custom files..."

# promptLi Assistant
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

# CLI wrappers
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

# i3 autostart extension
cat >> "$CHROOT/etc/skel/.config/i3/config" << "I3AUTO"
exec --no-startup-id ~/.config/autostart.sh
I3AUTO

# Root user i3 config
mkdir -p "$CHROOT/root/.config/i3" "$CHROOT/root/.config/i3status"
cp /project/config/i3/config "$CHROOT/root/.config/i3/config"
cp /project/config/i3/i3status.conf "$CHROOT/root/.config/i3status/config"

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
mkdir -p "$CHROOT/etc/skel/.config"
cat > "$CHROOT/etc/skel/.config/autostart.sh" << "STARTUP"
#!/bin/bash
picom --config ~/.config/picom/picom.conf &
feh --bg-fill /opt/promptli/assets/wallpaper.svg &
nm-applet &
promptli &
STARTUP
chmod +x "$CHROOT/etc/skel/.config/autostart.sh"

# LightDM autologin
mkdir -p "$CHROOT/etc/lightdm"
cat > "$CHROOT/etc/lightdm/lightdm.conf" << "LIGHTDM"
[Seat:*]
autologin-user=promptli
autologin-user-timeout=0
user-session=i3
greeter-session=lightdm-gtk-greeter
LIGHTDM

# First-boot user setup
cat > "$CHROOT/etc/systemd/system/promptli-setup.service" << "UNIT"
[Unit]
Description=promptLi OS first boot setup
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/promptli/setup.sh

[Install]
WantedBy=multi-user.target
UNIT

mkdir -p "$CHROOT/opt/promptli"
cat > "$CHROOT/opt/promptli/setup.sh" << "SETUP"
#!/bin/bash
# Create default promptli user if not exists
if ! id promptli &>/dev/null; then
    useradd -m -s /bin/bash -G sudo,audio,video,netdev promptli
    echo "promptli:promptli" | chpasswd
    # Copy skel files
    cp -r /etc/skel/. "$(getent passwd promptli | cut -d: -f6)/"
    chown -R promptli:promptli "$(getent passwd promptli | cut -d: -f6)"
fi

# Install Zen Browser on first boot
if [ ! -f /opt/zen-browser/zen ]; then
    echo "[*] Installing Zen Browser..."
    mkdir -p /opt/zen-browser
    cd /tmp
    wget -q "https://github.com/zen-browser/desktop/releases/latest/download/zen.linux-x86_64.tar.xz" -O zen.tar.xz
    tar -xf zen.tar.xz -C /opt/zen-browser/ --strip-components=1
    rm zen.tar.xz
    ln -sf /opt/zen-browser/zen /usr/local/bin/zen-browser
    update-alternatives --install /usr/bin/x-www-browser x-www-browser /opt/zen-browser/zen 100
    update-alternatives --set x-www-browser /opt/zen-browser/zen
    echo "[✓] Zen Browser installed."
fi

# Create Zen Browser desktop entry
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

# Install Python deps for promptLi Assistant
pip3 install --break-system-packages anthropic 2>/dev/null || true

systemctl disable promptli-setup.service
SETUP
chmod +x "$CHROOT/opt/promptli/setup.sh"

# Enable first-boot service
ln -sf /etc/systemd/system/promptli-setup.service "$CHROOT/etc/systemd/system/multi-user.target.wants/promptli-setup.service" 2>/dev/null || true
mkdir -p "$CHROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/promptli-setup.service "$CHROOT/etc/systemd/system/multi-user.target.wants/promptli-setup.service"

echo "[2/5] Custom files installed."

# ── Step 3: Configure live-boot ───────────────────────
echo "[3/5] Configuring live system..."

# Set hostname
echo "promptli" > "$CHROOT/etc/hostname"
echo "127.0.0.1 localhost promptli" > "$CHROOT/etc/hosts"

# Enable NetworkManager
ln -sf /lib/systemd/system/NetworkManager.service "$CHROOT/etc/systemd/system/dbus-org.freedesktop.nvideosettings.service" 2>/dev/null || true
ln -sf /lib/systemd/system/NetworkManager.service "$CHROOT/etc/systemd/system/multi-user.target.wants/NetworkManager.service" 2>/dev/null || true

# Enable LightDM
ln -sf /lib/systemd/system/lightdm.service "$CHROOT/etc/systemd/system/display-manager.service" 2>/dev/null || true

echo "[3/5] System configured."

# ── Step 4: Create squashfs ───────────────────────────
echo "[4/5] Creating squashfs filesystem..."

# Clean up apt cache
rm -rf "$CHROOT/var/lib/apt/lists/"* "$CHROOT/var/cache/apt/"*

# Create squashfs
mkdir -p /build/tmp/live
mksquashfs "$CHROOT" /build/tmp/live/filesystem.squashfs \
    -comp xz -b 1048576 -Xdict-size 100% \
    -noappend -e boot/ -e var/cache/apt/ -e var/lib/apt/lists/

echo "[4/5] SquashFS created."

# ── Step 5: Build ISO with xorriso ────────────────────
echo "[5/5] Building ISO..."

# Setup ISO directory structure
mkdir -p /build/iso/live
cp /build/tmp/live/filesystem.squashfs /build/iso/live/

# Get kernel and initrd from chroot
cp "$CHROOT/boot/vmlinuz-"* /build/iso/live/vmlinuz
cp "$CHROOT/boot/initrd.img-"* /build/iso/live/initrd.img

# Copy isolinux files
mkdir -p /build/iso/isolinux
cp /usr/lib/ISOLINUX/isolinux.bin /build/iso/isolinux/ 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/{ldlinux,libcom32,libutil,menu,vesamenu}.c32 /build/iso/isolinux/ 2>/dev/null || true

# Create isolinux config
cat > /build/iso/isolinux/isolinux.cfg << "ISOCFG"
UI vesamenu.c32
MENU TITLE promptLi OS 1.0.0
DEFAULT live
TIMEOUT 50

LABEL live
    MENU LABEL ^Boot promptLi OS
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img boot=live quiet splash
ISOCFG

# Build ISO
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "promptLi OS" \
    -appid "promptLi OS 1.0.0" \
    -publisher "promptLi" \
    -preparer "promptLi OS Builder" \
    -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -output "/output/$ISO_NAME.iso" \
    /build/iso/

echo ""
echo "========================================="
echo "  ✅ promptLi OS ISO built successfully!"
echo "  📀 /output/$ISO_NAME.iso"
echo "========================================="
ls -lh "/output/$ISO_NAME.iso"
'

echo ""
echo "========================================="
echo "  ✅ promptLi OS ISO built successfully!"
echo "  📀 Location: $OUTPUT_DIR/$ISO_NAME.iso"
echo "========================================="
ls -lh "$OUTPUT_DIR/$ISO_NAME.iso" 2>/dev/null || echo "Check $OUTPUT_DIR"

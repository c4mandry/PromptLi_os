#!/bin/bash
# ============================================================
#  Inner live-build script (runs inside build environment)
# ============================================================
set -euo pipefail

ISO_NAME="promptli-os-1.0.0-amd64"
LB_DIR="/build/live-build"
CONFIG_DIR="/build/config"
ASSISTANT_DIR="/build/assistant"
TOOLS_DIR="/build/tools"
INCLUDES_DIR="$CONFIG_DIR/includes.chroot"

echo "[*] Configuring live-build..."

# Clean
lb clean --all 2>/dev/null || true

# Configure the build
lb config noauto \
    --architecture amd64 \
    --distribution trixie \
    --archive-areas "main contrib non-free non-free-firmware" \
    --bootappend-live "boot=live components quiet splash" \
    --debian-installer none \
    --bootstrap mmdebstrap \
    --iso-application "promptLi OS" \
    --iso-publisher "promptLi" \
    --iso-volume "promptLi OS 1.0.0" \
    --linux-flavours amd64 \
    --memtest none \
    --binary-images iso-hybrid

echo "[*] Setting package lists..."

# Package list for promptLi OS
cat > config/package-lists/promptli.list.chroot << 'PACKAGES'
# ── Base System ──
xorg
xinit
x11-xserver-utils
xterm

# ── Window Manager (i3) ──
i3-wm
i3status
i3lock
dmenu
suckless-tools

# ── Display & Compositing ──
picom
feh
xcompmgr

# ── Fonts ──
fonts-jetbrains-mono
fonts-font-awesome
fonts-noto
fonts-noto-cjk

# ── Networking ──
network-manager
network-manager-gnome
wireless-tools
wpasupplicant

# ── Audio ──
pulseaudio
pavucontrol
alsa-utils

# ── Utilities ──
sensible-utils
curl
wget
git
vim
htop
neofetch
unzip
p7zip-full
scrot
xclip
brightnessctl
arandr
lxappearance

# ── Python (for promptLi Assistant) ──
python3
python3-pip
python3-tk
python3-pil
python3-pil.imagetk

# ── Terminal ──
alacritty
# or: rxvt-unicode

# ── Zen Browser deps ──
libasound2
libdbus-glib-1-2
libgtk-3-0

# ── File Manager ──
thunar
gvfs
gvfs-backends

# ── Login Manager ──
lightdm
lightdm-gtk-greeter

# ── promptLi specific ──
sudo
policykit-1

# ── AppImage / Zen Browser runtime deps ──
libfuse2
fuse
PACKAGES

echo "[*] Copying custom files into chroot..."

# Prepare includes.chroot directory
rm -rf "$INCLUDES_DIR"
mkdir -p "$INCLUDES_DIR"

# ── /opt/promptli — main application ──
mkdir -p "$INCLUDES_DIR/opt/promptli"
cp "$ASSISTANT_DIR/promptli_assistant.py" "$INCLUDES_DIR/opt/promptli/"
cp "$ASSISTANT_DIR/promptli_daemon.py" "$INCLUDES_DIR/opt/promptli/"
cp "$ASSISTANT_DIR/requirements.txt" "$INCLUDES_DIR/opt/promptli/"
cp -r "$ASSISTANT_DIR/assets" "$INCLUDES_DIR/opt/promptli/" 2>/dev/null || mkdir -p "$INCLUDES_DIR/opt/promptli/assets"

# ── Zen Browser ──
mkdir -p "$INCLUDES_DIR/opt/zen-browser"
cat > "$INCLUDES_DIR/opt/zen-browser/install-zen.sh" << 'ZENINSTALL'
#!/bin/bash
# Download and install Zen Browser (runs on first boot if not present)
if [ ! -f /opt/zen-browser/zen ]; then
    echo "[*] Installing Zen Browser..."
    ZEN_URL="https://github.com/zen-browser/desktop/releases/latest/download/zen.linux-x86_64.tar.xz"
    cd /tmp
    wget -q "$ZEN_URL" -O zen.tar.xz
    tar -xf zen.tar.xz -C /opt/zen-browser/ --strip-components=1
    rm zen.tar.xz
    # Create symlink
    ln -sf /opt/zen-browser/zen /usr/local/bin/zen-browser
    # Set as default browser
    update-alternatives --install /usr/bin/x-www-browser x-www-browser /opt/zen-browser/zen 100
    update-alternatives --set x-www-browser /opt/zen-browser/zen
    echo "[✓] Zen Browser installed."
fi
ZENINSTALL
chmod +x "$INCLUDES_DIR/opt/zen-browser/install-zen.sh"

# Zen Browser desktop entry
mkdir -p "$INCLUDES_DIR/usr/share/applications"
cat > "$INCLUDES_DIR/usr/share/applications/zen-browser.desktop" << 'ZENDESKTOP'
[Desktop Entry]
Name=Zen Browser
Comment=Browse the web
Exec=/opt/zen-browser/zen %u
Icon=/opt/zen-browser/browser/chrome/icons/default/default128.png
Type=Application
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupWMClass=zen
Terminal=false
ZENDESKTOP

# ── /opt/promptli/tools — bundled tools ──
mkdir -p "$INCLUDES_DIR/opt/promptli/tools"
cp "$TOOLS_DIR/locakhost.py" "$INCLUDES_DIR/opt/promptli/tools/"

# ── /usr/share/applications — desktop entries ──
mkdir -p "$INCLUDES_DIR/usr/share/applications"
cp "$ASSISTANT_DIR/promptli.desktop" "$INCLUDES_DIR/usr/share/applications/"
cp "$TOOLS_DIR/locakhost.desktop" "$INCLUDES_DIR/usr/share/applications/"

# ── /usr/local/bin — symlink ──
mkdir -p "$INCLUDES_DIR/usr/local/bin"
cat > "$INCLUDES_DIR/usr/local/bin/promptli" << 'WRAPPER'
#!/bin/bash
exec python3 /opt/promptli/promptli_assistant.py "$@"
WRAPPER
chmod +x "$INCLUDES_DIR/usr/local/bin/promptli"

cat > "$INCLUDES_DIR/usr/local/bin/locakhost" << 'WRAPPER'
#!/bin/bash
exec python3 /opt/promptli/tools/locakhost.py "$@"
WRAPPER
chmod +x "$INCLUDES_DIR/usr/local/bin/locakhost"

# ── /etc/skel — default user config ──
	mkdir -p "$INCLUDES_DIR/etc/skel/.config/i3"
	mkdir -p "$INCLUDES_DIR/etc/skel/.config/i3status"
	cp "$CONFIG_DIR/i3/config" "$INCLUDES_DIR/etc/skel/.config/i3/config"
	cp "$CONFIG_DIR/i3/i3status.conf" "$INCLUDES_DIR/etc/skel/.config/i3status/config"

mkdir -p "$INCLUDES_DIR/etc/skel/.config/picom"
cat > "$INCLUDES_DIR/etc/skel/.config/picom/picom.conf" << 'PICOM'
# picom config for promptLi OS
backend = "glx";
vsync = true;
unredir-if-possible = true;
shadow = true;
shadow-radius = 12;
shadow-opacity = 0.5;
shadow-offset-x = -8;
shadow-offset-y = -8;
fading = true;
fade-in-step = 0.03;
fade-out-step = 0.03;
inactive-opacity = 0.9;
frame-opacity = 0.8;
corner-radius = 8;
rounded-corners-exclude = [
    "window_type = 'dock'",
    "window_type = 'desktop'"
];
PICOM

# ── /etc/skel/.config/autostart.sh ──
cp "$CONFIG_DIR/autostart/autostart.sh" "$INCLUDES_DIR/etc/skel/.config/autostart.sh"
chmod +x "$INCLUDES_DIR/etc/skel/.config/autostart.sh"

# ── /root — same config for root ──
	mkdir -p "$INCLUDES_DIR/root/.config/i3"
	mkdir -p "$INCLUDES_DIR/root/.config/i3status"
	cp "$CONFIG_DIR/i3/config" "$INCLUDES_DIR/root/.config/i3/config"
	cp "$CONFIG_DIR/i3/i3status.conf" "$INCLUDES_DIR/root/.config/i3status/config"

# ── i3 autostart integration ──
mkdir -p "$INCLUDES_DIR/etc/skel/.config/i3"
cat >> "$INCLUDES_DIR/etc/skel/.config/i3/config" << 'I3AUTOSTART'

# ── promptLi autostart ──────────────────────────────
exec --no-startup-id ~/.config/autostart.sh
I3AUTOSTART

# ── LightDM autologin ──
mkdir -p "$INCLUDES_DIR/etc/lightdm"
cat > "$INCLUDES_DIR/etc/lightdm/lightdm.conf" << 'LIGHTDM'
[Seat:*]
autologin-user=promptli
autologin-user-timeout=0
user-session=i3
greeter-session=lightdm-gtk-greeter
LIGHTDM

# ── Create default user ──
# This will be handled by a hook
mkdir -p "$INCLUDES_DIR/usr/lib/live/config"
cat > "$INCLUDES_DIR/usr/lib/live/config/9999-promptli-setup" << 'HOOK'
#!/bin/bash
# promptLi OS — first boot setup

# Create default user
if ! id promptli &>/dev/null; then
    useradd -m -s /bin/bash -G sudo,audio,video,netdev promptli
    echo "promptli:promptli" | chpasswd
fi

# Install Zen Browser on first boot
/opt/zen-browser/install-zen.sh 2>/dev/null || true

# Install Python deps
pip3 install --break-system-packages anthropic 2>/dev/null || true

# Set i3 as default session
update-alternatives --set x-session-manager /usr/bin/i3 2>/dev/null || true
HOOK
chmod +x "$INCLUDES_DIR/usr/lib/live/config/9999-promptli-setup"

echo "[*] Setting up hooks..."

# Copy hook configuration
mkdir -p config/hooks/normal
cat > config/hooks/normal/9999-promptli-customize.hook.chroot << 'HOOKSCRIPT'
#!/bin/bash
# promptLi OS customization hook

echo "⚡ Customizing promptLi OS..."

# Create default promptli user directory skeleton
mkdir -p /etc/skel/.config/i3
mkdir -p /etc/skel/.config/picom
mkdir -p /etc/skel/.config/promptli

# Set permissions
chown -R root:root /opt/promptli
chmod +x /usr/local/bin/promptli
chmod +x /usr/local/bin/locakhost
chmod +x /opt/promptli/promptli_assistant.py
chmod +x /opt/promptli/promptli_daemon.py

echo "✅ promptLi OS customization complete."
HOOKSCRIPT
chmod +x config/hooks/normal/9999-promptli-customize.hook.chroot

echo "[*] Building ISO (this may take 15-30 minutes)..."

# Build
lb build 2>&1 | tee /build/build.log

# Copy output
mkdir -p /output
if [ -f live-image-amd64.hybrid.iso ]; then
    cp live-image-amd64.hybrid.iso "/output/$ISO_NAME.iso"
    echo "[✓] ISO copied to /output/$ISO_NAME.iso"
else
    # Try alternate names
    cp *.iso "/output/$ISO_NAME.iso" 2>/dev/null || echo "[!] Could not find built ISO"
fi

#!/bin/bash
# ============================================================
#  PromptLix OS — inner build logic (live-build + Calamares)
#
#  Runs inside the build environment (native or Docker).
#  Expected environment:
#    PROJECT  — path to the PromptLix source tree (promptlix-os/)
#    WORK     — writable build workspace (default /build)
#    OUTPUT   — directory where the final ISO is copied (default /output)
#
#  Produces an iso-hybrid live ISO that boots in both BIOS and
#  UEFI and ships the Calamares installer, so PromptLix can be
#  installed permanently to disk (not just run as a live session).
#  Desktop: GNOME (GDM auto-login).
# ============================================================
set -euo pipefail

PROJECT="${PROJECT:-$(cd "$(dirname "$0")/.." && pwd)}"
WORK="${WORK:-/build}"
OUTPUT="${OUTPUT:-/output}"
ISO_NAME="promptlix-os-1.0.0-amd64"
VERSION="1.0.0"

echo "PromptLix OS — building installable live ISO ($ISO_NAME)"

mkdir -p "$WORK" "$OUTPUT"
rm -rf "$WORK/live-build"
mkdir -p "$WORK/live-build"
cd "$WORK/live-build"

echo "[*] Configuring live-build..."
lb config noauto \
    --architecture amd64 \
    --distribution trixie \
    --archive-areas "main contrib non-free non-free-firmware" \
    --bootappend-live "boot=live" \
    --debian-installer none \
    --iso-application "PromptLix OS" \
    --iso-publisher "PromptLix" \
    --iso-volume "PromptLix" \
    --linux-flavours amd64 \
    --memtest none \
    --binary-images iso-hybrid

# ── Package list ────────────────────────────────────────
echo "[*] Writing package list..."
mkdir -p config/package-lists
cat > config/package-lists/promptlix.list.chroot << 'PACKAGES'
# ── Kernel & live boot ──
linux-image-amd64
live-boot
systemd-sysv

# ── Installer (Calamares) ──
calamares
squashfs-tools
dosfstools
grub-pc-bin
grub-efi-amd64-bin
grub2-common
os-prober

# ── GNOME desktop ──
gnome-core
gnome-tweaks
gdm3
file-roller
librsvg2-common
pipewire-pulse
gnome-shell-extension-dashtodock
plymouth

# ── X11 ──
xorg

# ── Fonts ──
fonts-jetbrains-mono
fonts-noto
fonts-noto-cjk

# ── Networking ──
network-manager
wireless-tools
wpasupplicant

# ── Audio ──
alsa-utils

# ── Utilities ──
sensible-utils
curl
wget
git
vim
htop
unzip
p7zip-full
xclip
brightnessctl
xdotool
x11-utils
wmctrl

# ── Python (PromptLix Assistant + AIDO) ──
python3
python3-pip
python3-gi
gir1.2-webkit2-4.1
python3-tk
python3-pil
python3-pil.imagetk

# ── System ──
sudo
polkitd
pkexec
libasound2
libdbus-glib-1-2
libgtk-3-0
libfuse2
fuse
rsync
unattended-upgrades
PACKAGES

# ── Project files into the chroot (includes.chroot) ─────
echo "[*] Copying PromptLix files into the chroot..."
INCLUDES="config/includes.chroot"
rm -rf "$INCLUDES"
mkdir -p "$INCLUDES"

# /opt/promptlix — main application
mkdir -p "$INCLUDES/opt/promptlix/assets" "$INCLUDES/opt/promptlix/tools" "$INCLUDES/opt/promptlix/web"
cp "$PROJECT/assistant/promptlix-server.py" "$INCLUDES/opt/promptlix/"
cp "$PROJECT/assistant/promptlix-webview.py" "$INCLUDES/opt/promptlix/"
cp "$PROJECT/assistant/promptlix_windowd.py" "$INCLUDES/opt/promptlix/"
cp "$PROJECT/assistant/system_prompt.txt" "$INCLUDES/opt/promptlix/"
cp "$PROJECT/assistant/requirements.txt" "$INCLUDES/opt/promptlix/"
cp -r "$PROJECT/assistant/web/"* "$INCLUDES/opt/promptlix/web/"

# Wallpaper: convert SVG → PNG at build time (GNOME renders PNG reliably)
if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w 1920 -h 1080 \
        "$PROJECT/assistant/assets/wallpaper.svg" \
        -o "$INCLUDES/opt/promptlix/assets/wallpaper.png"
    echo "  [OK] Wallpaper converted to PNG"
else
    echo "  [!] rsvg-convert not found — shipping SVG only (install librsvg2-bin in the builder)"
    cp "$PROJECT/assistant/assets/wallpaper.svg" "$INCLUDES/opt/promptlix/assets/"
fi
cp "$PROJECT/assistant/assets/wallpaper.svg" "$INCLUDES/opt/promptlix/assets/"

cp "$PROJECT/tools/locakhost.py" "$INCLUDES/opt/promptlix/tools/"
cp "$PROJECT/config/autostart/gnome-setup.sh" "$INCLUDES/opt/promptlix/gnome-setup.sh"
chmod +x "$INCLUDES/opt/promptlix/gnome-setup.sh"

# /opt/aido — AIDO: fully local AI desktop operator (no cloud, no API keys)
mkdir -p "$INCLUDES/opt/aido"
cp -r "$PROJECT/aido/src" "$INCLUDES/opt/aido/"
cp -r "$PROJECT/aido/config" "$INCLUDES/opt/aido/"
cp -r "$PROJECT/aido/scripts" "$INCLUDES/opt/aido/"
cp "$PROJECT/aido/requirements.txt" "$PROJECT/aido/setup.py" "$PROJECT/aido/README.md" "$PROJECT/aido/LICENSE" "$INCLUDES/opt/aido/"

# First-boot setup script (runs on live session AND installed system)
cat > "$INCLUDES/opt/promptlix/setup.sh" << 'SETUP'
#!/bin/bash
# PromptLix OS — first-boot setup (live session and installed system)
set -e
echo "Running PromptLix first-boot setup..."

# Default user (idempotent; Calamares may already have created it)
if ! id promptlix &>/dev/null; then
    useradd -m -s /bin/bash -G sudo,audio,video,netdev promptlix
    echo "promptlix:promptlix" | chpasswd
    chown -R promptlix:promptlix /home/promptlix
fi

# Passwordless sudo for the default user (needed by the GUI installer launcher)
mkdir -p /etc/sudoers.d
echo "promptlix ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/promptlix
chmod 440 /etc/sudoers.d/promptlix

# Zen Browser — default and only browser (requires internet)
if [ ! -f /opt/zen-browser/zen ]; then
    echo "  Installing Zen Browser..."
    mkdir -p /opt/zen-browser
    cd /tmp
    wget -q "https://github.com/zen-browser/desktop/releases/latest/download/zen.linux-x86_64.tar.xz" -O zen.tar.xz
    tar -xf zen.tar.xz -C /opt/zen-browser/ --strip-components=1
    rm -f zen.tar.xz
    ln -sf /opt/zen-browser/zen /usr/local/bin/zen-browser
    update-alternatives --install /usr/bin/x-www-browser x-www-browser /opt/zen-browser/zen 100
    update-alternatives --set x-www-browser /opt/zen-browser/zen
fi

# Python deps for the assistant
pip3 install --break-system-packages anthropic openai 2>/dev/null || true

# AIDO — local AI desktop operator
# Default config for new users (and the live user, if already created)
mkdir -p /etc/skel/.aido
cp /opt/aido/config/aido.yaml /etc/skel/.aido/aido.yaml 2>/dev/null || true
if id promptlix &>/dev/null; then
    mkdir -p /home/promptlix/.aido
    cp /opt/aido/config/aido.yaml /home/promptlix/.aido/aido.yaml 2>/dev/null || true
    chown -R promptlix:promptlix /home/promptlix/.aido 2>/dev/null || true
fi
# Install AIDO deps (llama-cpp-python ships prebuilt wheels for amd64)
pip3 install --break-system-packages -r /opt/aido/requirements.txt 2>/dev/null || true
# Heavy downloads in the background so login is not blocked:
# the ~700MB Granite model + Playwright's Chromium, as the desktop user
if id promptlix &>/dev/null; then
    nohup sudo -u promptlix bash -c "bash /opt/aido/scripts/download_model.sh; python3 -m playwright install chromium" \
        >/tmp/aido-setup.log 2>&1 &
fi

# Run once per installation
systemctl disable promptlix-setup.service 2>/dev/null || true
echo "PromptLix setup complete."
SETUP
chmod +x "$INCLUDES/opt/promptlix/setup.sh"

# ── Desktop entries ──
mkdir -p "$INCLUDES/usr/share/applications"
cp "$PROJECT/assistant/promptlix.desktop" "$INCLUDES/usr/share/applications/"
cp "$PROJECT/tools/locakhost.desktop" "$INCLUDES/usr/share/applications/"

cat > "$INCLUDES/usr/share/applications/install-promptlix.desktop" << 'DESKTOP'
[Desktop Entry]
Name=Install PromptLix
Comment=Install PromptLix OS to your hard drive
Exec=sudo -E calamares
Icon=system-installer
Type=Application
Categories=System;
Terminal=false
DESKTOP

cat > "$INCLUDES/usr/share/applications/zen-browser.desktop" << 'DESKTOP'
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
DESKTOP

cat > "$INCLUDES/usr/share/applications/aido.desktop" << 'DESKTOP'
[Desktop Entry]
Name=AIDO — Local AI
Comment=Offline AI desktop operator (local model, no cloud)
Exec=/usr/local/bin/aido --gui
Icon=utilities-terminal
Type=Application
Categories=Utility;AI;
Terminal=false
DESKTOP

# ── CLI wrappers ──
mkdir -p "$INCLUDES/usr/local/bin"
cat > "$INCLUDES/usr/local/bin/promptlix" << 'WRAP'
#!/bin/bash
exec python3 /opt/promptlix/promptlix-webview.py "$@"
WRAP
chmod +x "$INCLUDES/usr/local/bin/promptlix"

cat > "$INCLUDES/usr/local/bin/aido" << 'WRAP'
#!/bin/bash
PYTHONPATH=/opt/aido/src exec python3 /opt/aido/src/aido.py "$@"
WRAP
chmod +x "$INCLUDES/usr/local/bin/aido"

cat > "$INCLUDES/usr/local/bin/locakhost" << 'WRAP'
#!/bin/bash
exec python3 /opt/promptlix/tools/locakhost.py "$@"
WRAP
chmod +x "$INCLUDES/usr/local/bin/locakhost"

# ── /etc/skel — default user config ──
mkdir -p "$INCLUDES/etc/skel/.config/autostart"
mkdir -p "$INCLUDES/etc/skel/.config/promptlix"
cp "$PROJECT/config/autostart/promptlix.desktop" "$INCLUDES/etc/skel/.config/autostart/"
cp "$PROJECT/config/autostart/promptlix-gnome-setup.desktop" "$INCLUDES/etc/skel/.config/autostart/"

# ── GDM autologin (X11 session — required for window tracking via xdotool) ──
mkdir -p "$INCLUDES/etc/gdm3"
cat > "$INCLUDES/etc/gdm3/daemon.conf" << 'GDM'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=promptlix
WaylandEnable=false
GDM

# ── Hostname ──
echo "promptlix" > "$INCLUDES/etc/hostname"

# ── Kernel hardening (sysctl) ──
mkdir -p "$INCLUDES/etc/sysctl.d"
cat > "$INCLUDES/etc/sysctl.d/99-promptlix-hardening.conf" << 'SYSCTL'
# PromptLix OS — kernel attack-surface reduction
# (Debian's kernel is built from kernel.org source with GPG-signed
# packages; these settings further restrict what userspace can reach.)

# Hide kernel pointers and dmesg from unprivileged users
kernel.kptr_restrict=1
kernel.dmesg_restrict=1

# No unprivileged eBPF programs (root can still load them)
kernel.unprivileged_bpf_disabled=1

# Full ASLR
kernel.randomize_va_space=2

# Yama: only parent processes may ptrace children
kernel.yama.ptrace_scope=1

# Hardened file creation in sticky, world-writable dirs
fs.protected_hardlinks=1
fs.protected_symlinks=1
fs.protected_fifos=2
fs.protected_regular=2
fs.suid_dumpable=0

# Network hygiene
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.tcp_syncookies=1
net.ipv6.conf.all.accept_redirects=0
SYSCTL

# ── Automatic security updates (kernel CVEs etc.) ──
mkdir -p "$INCLUDES/etc/apt/apt.conf.d"
cat > "$INCLUDES/etc/apt/apt.conf.d/20auto-upgrades" << 'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT

cat > "$INCLUDES/etc/apt/apt.conf.d/50unattended-upgrades" << 'APT'
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
APT

# ── Assistant server: systemd user service (starts at login, hidden port always up) ──
mkdir -p "$INCLUDES/usr/lib/systemd/user"
cat > "$INCLUDES/usr/lib/systemd/user/promptlix-server.service" << 'UNIT'
[Unit]
Description=PromptLix assistant server (hidden local port)
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/promptlix/promptlix-server.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
UNIT

# Enable it for every new user via /etc/skel (copied at user creation)
mkdir -p "$INCLUDES/etc/skel/.config/systemd/user/default.target.wants"
ln -sf /usr/lib/systemd/user/promptlix-server.service \
    "$INCLUDES/etc/skel/.config/systemd/user/default.target.wants/promptlix-server.service"

# ── Boot branding: GRUB ──
mkdir -p "$INCLUDES/etc/default"
cat > "$INCLUDES/etc/default/grub" << 'GRUB'
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="PromptLix"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUB

# ── Boot branding: Plymouth splash theme ──
mkdir -p "$INCLUDES/usr/share/plymouth/themes/promptlix"
cat > "$INCLUDES/usr/share/plymouth/themes/promptlix/promptlix.plymouth" << 'PLY'
[Plymouth Theme]
Name=PromptLix
Description=PromptLix OS boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/promptlix
ScriptFile=/usr/share/plymouth/themes/promptlix/promptlix.script
PLY

cat > "$INCLUDES/usr/share/plymouth/themes/promptlix/promptlix.script" << 'PLYSCRIPT'
# PromptLix boot splash (Tokyo Night)
Plymouth.SetRefreshRate(50);
Plymouth.SetBackgroundColor(0.10, 0.10, 0.14);

logo.image = Image("logo.png");
logo.sprite = Sprite(logo.image);
logo.sprite.SetX(Window.GetWidth() / 2 - logo.image.GetWidth() / 2);
logo.sprite.SetY(Window.GetHeight() / 2 - logo.image.GetHeight() / 2 - 30);

title.image = Image.Text("PromptLix", 0.75, 0.60, 0.97);
title.sprite = Sprite(title.image);
title.sprite.SetX(Window.GetWidth() / 2 - title.image.GetWidth() / 2);
title.sprite.SetY(Window.GetHeight() / 2 + 40);
PLYSCRIPT

# ── Boot branding: GDM login screen (Tokyo Night + wallpaper) ──
mkdir -p "$INCLUDES/etc/dconf/profile" "$INCLUDES/etc/dconf/db/gdm.d"
cat > "$INCLUDES/etc/dconf/profile/gdm" << 'DCONF'
user-db:user
system-db:gdm
DCONF

cat > "$INCLUDES/etc/dconf/db/gdm.d/00-promptlix" << 'DCONF'
[org/gnome/desktop/interface]
color-scheme='prefer-dark'

[org/gnome/desktop/background]
picture-uri='file:///opt/promptlix/assets/wallpaper.png'
picture-uri-dark='file:///opt/promptlix/assets/wallpaper.png'
picture-options='zoom'
DCONF

# ── First-boot systemd service ──
mkdir -p "$INCLUDES/etc/systemd/system"
cat > "$INCLUDES/etc/systemd/system/promptlix-setup.service" << 'UNIT'
[Unit]
Description=PromptLix OS first boot setup
After=network.target network-online.target
Wants=network-online.target
Before=display-manager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/promptlix/setup.sh

[Install]
WantedBy=graphical.target
UNIT

# ── Calamares installer configuration ───────────────────
CAL="$INCLUDES/etc/calamares"
mkdir -p "$CAL/modules" "$CAL/branding/promptlix"

cat > "$CAL/settings.conf" << 'CAL'
---
branding: promptlix
prompt-install: false
dont-chroot: false
disable-cancel: false
disable-cancel-during-exec: false
quit-at-end: false
sequence:
  show:
    - welcome
    - locale
    - keyboard
    - partition
    - users
    - summary
  exec:
    - mount
    - unpackfs
    - machineid
    - fstab
    - bootloader
    - umount
  show:
    - finished
CAL

cat > "$CAL/branding/promptlix/branding.desc" << 'CAL'
---
componentName: promptlix
welcomeStyleCalamares: true
strings:
  productName: PromptLix
  shortProductName: PromptLix
  version: "1.0.0"
  shortVersion: "1.0.0"
  bootloaderEntryName: PromptLix
  productUrl: ""
  supportUrl: ""
images:
  productLogo: logo.png
  productIcon: logo.png
  productWelcome: welcome.png
style:
  sidebarBackground: "#1a1b26"
  sidebarText: "#c0caf5"
  sidebarTextSelect: "#1a1b26"
  sidebarTextHighlight: "#bb9af7"
CAL

cat > "$CAL/modules/welcome.conf" << 'CAL'
showSupportUrl: false
showKnownIssuesUrl: false
showReleaseNotesUrl: false
showDonateUrl: false
CAL

cat > "$CAL/modules/locale.conf" << 'CAL'
region: "America"
zone: "New_York"
CAL

cat > "$CAL/modules/keyboard.conf" << 'CAL'
defaultLayout: "us"
CAL

cat > "$CAL/modules/partition.conf" << 'CAL'
defaultFileSystemType: ext4
userSwapChoices:
  - none
  - small
  - suspend
  - file
alwaysShowPartitionLabels: true
CAL

cat > "$CAL/modules/users.conf" << 'CAL'
userShell: /bin/bash
autologinUser: promptlix
doAutologin: true
sudoersGroup: sudo
setRootPassword: true
doReusePasswordForRoot: true
passwordRequirements:
  minLength: 1
  maxLength: -1
defaultGroups:
  - sudo
  - audio
  - video
  - netdev
  - lpadmin
CAL

cat > "$CAL/modules/summary.conf" << 'CAL'
{}
CAL

cat > "$CAL/modules/mount.conf" << 'CAL'
{}
CAL

cat > "$CAL/modules/unpackfs.conf" << 'CAL'
unpack:
  - source: /run/live/medium/live/filesystem.squashfs
    sourcefs: squashfs
    destination: ""
CAL

cat > "$CAL/modules/machineid.conf" << 'CAL'
symlink: true
CAL

cat > "$CAL/modules/fstab.conf" << 'CAL'
mountOptions: defaults
CAL

cat > "$CAL/modules/bootloader.conf" << 'CAL'
efiBootLoader: grub
grubInstall: grub-install
grubMkconfig: grub-mkconfig
grubCfg: /boot/grub/grub.cfg
CAL

cat > "$CAL/modules/umount.conf" << 'CAL'
{}
CAL

cat > "$CAL/modules/finished.conf" << 'CAL'
restartNowEnabled: true
restartNowChecked: false
restartNowCommand: systemctl -i reboot
CAL

# ── Chroot customization hook ───────────────────────────
echo "[*] Writing chroot customization hook..."
mkdir -p config/hooks/normal
cat > config/hooks/normal/9999-promptlix-customize.hook.chroot << 'HOOK'
#!/bin/bash
# PromptLix OS — runs inside the chroot during build
set -e

echo "Customizing PromptLix OS chroot..."

# Hostname
echo "promptlix" > /etc/hostname
grep -q "promptlix" /etc/hosts || echo "127.0.0.1 localhost promptlix" >> /etc/hosts

# Permissions
chmod +x /opt/promptlix/promptlix-server.py
chmod +x /opt/promptlix/promptlix-webview.py
chmod +x /opt/promptlix/promptlix_windowd.py
chmod +x /opt/promptlix/setup.sh
chmod +x /opt/promptlix/gnome-setup.sh
chmod +x /usr/local/bin/promptlix
chmod +x /usr/local/bin/aido
chmod +x /usr/local/bin/locakhost
chmod 644 /opt/promptlix/system_prompt.txt
chown -R root:root /opt/promptlix

# Placeholder branding images (Tokyo Night colors) — replace with real artwork
python3 - << 'PY'
import os
import struct
import zlib

def write_png(path, w, h, rgb):
    def chunk(t, data):
        c = t + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    png = sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)

brand = "/etc/calamares/branding/promptlix"
os.makedirs(brand, exist_ok=True)
write_png(brand + "/logo.png", 192, 192, (187, 154, 247))  # Tokyo Night purple
write_png(brand + "/welcome.png", 800, 450, (26, 27, 38))  # Tokyo Night background
write_png("/usr/share/plymouth/themes/promptlix/logo.png", 192, 192, (187, 154, 247))  # boot splash placeholder
PY

# Boot splash: make PromptLix the default Plymouth theme
plymouth-set-default-theme promptlix 2>/dev/null || true

# Login screen branding (GDM dconf database)
dconf update 2>/dev/null || true

# Enable services
mkdir -p /etc/systemd/system/graphical.target.wants
ln -sf /etc/systemd/system/promptlix-setup.service /etc/systemd/system/graphical.target.wants/promptlix-setup.service
ln -sf /lib/systemd/system/gdm3.service /etc/systemd/system/display-manager.service
ln -sf /lib/systemd/system/NetworkManager.service /etc/systemd/system/multi-user.target.wants/NetworkManager.service

echo "Chroot customization complete."
HOOK
chmod +x config/hooks/normal/9999-promptlix-customize.hook.chroot

# ── Build the ISO ───────────────────────────────────────
echo "[*] Building ISO (this can take 15-45 minutes)..."
lb build 2>&1 | tee "$WORK/build.log"

mkdir -p "$OUTPUT"
if [ -f live-image-amd64.hybrid.iso ]; then
    cp live-image-amd64.hybrid.iso "$OUTPUT/$ISO_NAME.iso"
elif compgen -G '*.iso' > /dev/null; then
    cp *.iso "$OUTPUT/$ISO_NAME.iso"
else
    echo "[!] No ISO produced — check $WORK/build.log"
    exit 1
fi

echo ""
echo "========================================="
echo "  PromptLix OS ISO built successfully!"
echo "  $OUTPUT/$ISO_NAME.iso ($(du -h "$OUTPUT/$ISO_NAME.iso" | cut -f1))"
echo "     GNOME desktop; boots in BIOS and UEFI; includes the Calamares installer."
echo "========================================="

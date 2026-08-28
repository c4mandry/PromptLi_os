# PromptLix OS — Project Context Handoff

> **To:** The AI on the x64 machine  
> **From:** Previous session (macOS / Apple Silicon)  
> **Purpose:** Catch you up on everything built so far so you can continue

---

## 1. What Is PromptLix OS?

A custom Debian-based Linux distribution. The user's vision:

- **Work-focused** OS
- **i3** tiling window manager (not GNOME/KDE)
- **Built-in AI assistant** with Claude API — a desktop chat app that can execute system commands
- **locakHost** pre-installed — a local web server tool by c4mandry (github.com/c4mandry/locakHost)
- **Zen Browser** as the default and only browser (not Firefox)
- Tokyo Night dark theme throughout

---

## 2. What Was Built

### Project structure (on macOS at `~/Documents/PromptLix_os/v1?PromptLix/`)

```
v1?PromptLix/
├── uzip/                              # Extracted Debian 13.6 DVD (9,459 files, ~3.7GB unpacked)
├── promptlix-os/                       # The distro source tree
│   ├── assistant/
│   │   ├── promptlix_assistant.py      # Main AI chat app (Python + tkinter, Claude API)
│   │   ├── promptlix_daemon.py         # Unix socket daemon for elevated commands
│   │   ├── promptlix.desktop           # Desktop entry for app launchers
│   │   ├── install.sh                 # Installer script
│   │   ├── requirements.txt           # Just: anthropic>=0.39.0
│   │   └── assets/wallpaper.svg       # Tokyo Night wallpaper (1920x1080)
│   ├── config/
│   │   ├── i3/config                  # i3 WM config (Super key, Tokyo Night colors)
│   │   ├── i3/i3status.conf           # i3status bar config
│   │   └── autostart/autostart.sh     # Startup: picom, feh wallpaper, nm-applet, promptlix
│   ├── tools/
│   │   ├── locakhost.py               # c4mandry's web server (unchanged)
│   │   └── locakhost.desktop          # Desktop entry
│   ├── build/
│   │   ├── build_iso.sh               # Docker-based builder (QEMU workaround)
│   │   ├── build_iso_v2.sh            # mmdebstrap attempt
│   │   ├── build_iso_v3.sh            # Latest attempt (needs cleanup)
│   │   ├── live_build_inner.sh        # Inner build logic
│   │   └── test.sh
│   └── README.md
├── build_promptlix.sh                  # Self-contained native x64 builder (888 lines)
└── promptlix-os/build/output/
    └── promptlix-os-1.0.0-amd64.iso    # First successful build: 651 MB
```

### The ISO that was built

- **File:** `promptlix-os/build/output/promptlix-os-1.0.0-amd64.iso` (651 MB)
- **Built on:** macOS Apple Silicon using Docker + QEMU emulation + mmdebstrap
- **Status:** Built successfully but **NOT tested** (no QEMU/VirtualBox boot test done)
- **Contents:**
  - Debian 13 "Trixie" base
  - i3 WM with Tokyo Night theme
  - PromptLix Assistant at `/opt/promptlix/`
  - locakHost at `/opt/promptlix/tools/`
  - Both available as CLI commands: `promptlix` and `locakhost`
  - Zen Browser installed on first boot via `setup.sh`
  - Auto-login as user `promptlix` (password: `promptlix`)
  - LightDM display manager

---

## 3. Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Desktop | i3 (not GNOME/KDE) | User wanted lightweight, keyboard-driven |
| AI backend | Claude API (Anthropic) | User specified this |
| AI app framework | Python + tkinter | Matches locakhost's stack, no extra deps |
| Browser | Zen Browser (not Firefox) | User's preference, installed first-boot |
| locakhost access | CLI wrapper at `/usr/local/bin/locakhost` | User wanted to type just `locakhost` in terminal |
| Default user | `promptlix` / `promptlix` | Auto-login, in sudo group |
| Build approach | Docker + mmdebstrap (on Mac) or native live-build (on x64) | See section 4 |

---

## 4. The Build Saga (Important for x64 AI)

### On x86_64 (native) — SHOULD BE SIMPLE

The user is moving to an x64 PC. On native x86_64, you can use standard `live-build` directly. The script `build_promptlix.sh` (888 lines, in the project root) is a self-contained builder that:

1. Installs `live-build` and dependencies
2. Generates all project files inline
3. Uses native `debootstrap` (no QEMU needed!)
4. Builds the ISO in ~15 minutes

**This should work on Debian 12/13 or Ubuntu 22.04/24.04 x86_64.**

### On Apple Silicon (what we fought through)

Building an amd64 ISO on ARM Mac required many workarounds:

| Approach | Result | Why it failed |
|---|---|---|
| `live-build` + `debootstrap` | FAIL | QEMU tar extraction bug with `libpam-runtime` package |
| `live-build` + `mmdebstrap` wrapper | FAIL | CLI incompatible, live-build hardcoded for debootstrap |
| `mmdebstrap --mode fakechroot` | FAIL | dash shell fd issues, QEMU postinst script failures |
| `mmdebstrap --mode unshare` | FAIL | macOS APFS volume mount broke package scripts |
| `mmdebstrap --mode root` in `/tmp` | OK | Working in container's native overlay FS, then copy ISO out |
| `docker build` with `rm /bin/sh` | FAIL | Broke bash execution under QEMU (baffling bug) |
| `docker build` with `SHELL` directive | FAIL | Also broke binary execution under QEMU |

**The working incantation** (for reference):

```bash
docker run --rm --privileged --platform linux/amd64 \
    -v "$PROJECT_DIR:/project:ro" \
    -v "$OUTPUT_DIR:/output" \
    promptlix-builder -c '
        # Build in /tmp (container native fs), not mounted volume
        mmdebstrap --mode root --arch amd64 --variant important \
            --hook-dir=/tmp/hooks \
            trixie /tmp/chroot http://deb.debian.org/debian
        
        # Then install extra packages via chroot
        chroot /tmp/chroot apt-get install -y ...
        
        # Build squashfs + ISO
        mksquashfs /tmp/chroot /tmp/iso/live/filesystem.squashfs
        xorriso -as mkisofs ... -output /output/promptlix-os.iso /tmp/iso/
    '
```

Key lessons:
- **Always build inside `/tmp` not a mounted volume** — macOS APFS is incompatible
- **Use `--mode root` not `--mode unshare`** — more reliable under QEMU
- **Add a `policy-rc.d` hook** that exits 101 to prevent service starts during bootstrap
- **Install heavy packages (kernel, Xorg, i3) via `chroot apt-get`** after bootstrap, not in `--include`
- **Neither `fakechroot` nor `fakeroot` actually helped** — they caused separate problems
- **Docker `SHELL` directive on ARM→x86 QEMU silently breaks things**

---

## 5. What's Inside the PromptLix Assistant

### promptlix_assistant.py

- Python 3 + tkinter GUI
- Tokyo Night dark color scheme (#1a1b26 background)
- Sidebar with New Chat, Settings, Command Log buttons
- Chat area with message bubbles (user = blue, AI = dark)
- Settings panel: API key, model selection, system prompt
- Command execution flow:
  1. Claude suggests bash commands in ```bash blocks
  2. App extracts them and shows "Run" buttons
  3. User clicks → confirmation dialog appears
  4. Danger check for destructive commands (extra warning)
  5. Runs via `subprocess.run()` with 120s timeout
  6. Output displayed in chat, logged to `~/.config/promptlix/command_log.json`
- Conversation persisted to `~/.config/promptlix/chat_history.json`
- Model: claude-sonnet-4-20250514 (configurable)
- System prompt instructs Claude it has system-level access and should wrap commands in ```bash blocks

### promptlix_daemon.py

- Separate Unix socket daemon at `/tmp/promptlix-daemon.sock`
- Can run as root for elevated commands
- Same danger keyword detection
- JSON protocol over Unix socket
- NOT automatically started — user would need to run it manually or via systemd

### promptlix.desktop

- Desktop entry for app menus (dmenu, thunar, etc.)
- Exec: `python3 /opt/promptlix/promptlix_assistant.py`
- Category: System;Utility

---

## 6. What's NOT Done / Known Issues

### Critical — MUST address:
1. **ISO not boot-tested** — Never actually booted the ISO in QEMU or real hardware
2. **No UEFI support** — ISO only has ISOLINUX (BIOS), no GRUB-EFI
3. **Wallpaper is SVG** — `feh` might not render SVG; may need PNG conversion
4. **No default wallpaper file setup** — autostart.sh references `/opt/promptlix/assets/wallpaper.svg` but the copy step may be missing
5. **Zen Browser download on first boot** — requires internet; if offline, no browser at all

### Should address:
6. **`tkinter` on live system** — needs `python3-tk` package (included in package list, verify)
7. **No network persistence** — live ISO changes are lost on reboot
8. **No installer** — this is a live ISO only, not an installer
9. **Daemon not auto-started** — the `promptlix_daemon.py` exists but isn't wired into the assistant app
10. **Assistant uses `subprocess` directly** — doesn't talk to the daemon; it runs commands as the current user

### Nice to have:
11. **No custom icon/logo** — just text "PromptLix" in the app
12. **No Plymouth boot screen** — just text-mode boot
13. **i3 config uses hardcoded paths** — `/opt/promptlix/` instead of relative
14. **No locale/keyboard configuration** — defaults to US English

---

## 7. The Package List

These are the packages included (from the live-build config):

```
xorg, xinit, x11-xserver-utils, xterm
i3-wm, i3status, i3lock, dmenu, suckless-tools
picom, feh, xcompmgr
fonts-jetbrains-mono, fonts-font-awesome, fonts-noto, fonts-noto-cjk
network-manager, network-manager-gnome, wireless-tools, wpasupplicant
pulseaudio, pavucontrol, alsa-utils
curl, wget, git, vim, htop, unzip, p7zip-full
scrot, xclip, brightnessctl, arandr, lxappearance
python3, python3-pip, python3-tk, python3-pil, python3-pil.imagetk
alacritty
thunar, gvfs, gvfs-backends
lightdm, lightdm-gtk-greeter
sudo, polkitd, pkexec
libasound2, libdbus-glib-1-2, libgtk-3-0, libfuse2, fuse, rsync
linux-image-amd64, live-boot, systemd-sysv
```

Note: `neofetch` was removed (not in Debian 13), `policykit-1` renamed to `polkitd pkexec`.

---

## 8. How to Continue on x64

### If you want to rebuild the ISO natively:

```bash
# Option A: Use the self-contained build script
chmod +x build_promptlix.sh
./build_promptlix.sh
# Output: ~/promptlix-os-output/promptlix-os-1.0.0-amd64.iso

# Option B: Use the existing project files
cd promptlix-os/build
# Edit live_build_inner.sh to remove QEMU workarounds
# Just run lb config + lb build (native debootstrap works on x64)
```

### If you want to test the existing ISO:

```bash
qemu-system-x86_64 -m 4G \
    -cdrom promptlix-os/build/output/promptlix-os-1.0.0-amd64.iso \
    -boot d
```

### If you want to develop the assistant app directly (no ISO needed):

```bash
cd promptlix-os
pip install anthropic
python3 assistant/promptlix_assistant.py
```

---

## 9. User Preferences Summary

- **Name:** PromptLix OS
- **Purpose:** Work-focused distro
- **Desktop:** i3 (tiling WM)
- **AI:** Claude API, system-level control
- **Browser:** Zen Browser (only browser)
- **Pre-installed tool:** locakHost (c4mandry)
- **locakhost must run from terminal** by typing just `locakhost`
- **First ISO already built** (651 MB, untested)
- **Moving to x64 PC** for easier native builds

---

## 10. File Reference

| File | Purpose |
|---|---|
| `promptlix-os/assistant/promptlix_assistant.py` | Main AI chat app |
| `promptlix-os/assistant/promptlix_daemon.py` | System daemon |
| `promptlix-os/assistant/promptlix.desktop` | Desktop entry for assistant |
| `promptlix-os/tools/locakhost.py` | Web server tool |
| `promptlix-os/config/i3/config` | i3 WM config |
| `promptlix-os/config/i3/i3status.conf` | i3status bar |
| `promptlix-os/config/autostart/autostart.sh` | Startup script |
| `promptlix-os/build/output/promptlix-os-1.0.0-amd64.iso` | Built ISO (651 MB) |
| `build_promptlix.sh` | Self-contained native x64 builder |
| `uzip/` | Extracted Debian 13.6 DVD (for reference) |

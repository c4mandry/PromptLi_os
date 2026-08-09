# ⚡ promptLi OS

**AI-powered Debian-based Linux distribution with system-level AI assistant.**

---

## Table of Contents

1. [Overview](#1-overview)
2. [Project Structure](#2-project-structure)
3. [Architecture](#3-architecture)
4. [The promptLi Assistant](#4-the-promptli-assistant)
5. [Building the ISO](#5-building-the-iso)
6. [Testing & Running](#6-testing--running)
7. [Package List](#7-package-list)
8. [Default Credentials & Shortcuts](#8-default-credentials--shortcuts)
9. [Build History & Lessons Learned](#9-build-history--lessons-learned)
10. [Known Issues & TODO](#10-known-issues--todo)
11. [File Reference](#11-file-reference)
12. [License](#12-license)

---

## 1. Overview

promptLi OS is a **work-focused Linux distribution** built on Debian 13 "Trixie". It features:

- **i3** tiling window manager — fast, keyboard-driven workflow
- **promptLi Assistant** — Multi-provider AI chat app (Claude, OpenAI, DeepSeek, Gemini) with system-level command execution
- **locakHost** — local web hosting tool by [c4mandry](https://github.com/c4mandry/locakHost)
- **Zen Browser** — the default and only browser
- **Tokyo Night** dark theme throughout the entire UI

The vision is a lightweight, AI-first operating system where you can talk to top AI models directly from your desktop and let them help you run shell commands, manage files, write code, and more — all with safety confirmations and full audit logging.

---

## 2. Project Structure

```
PromptLi_os/                              # Project root
├── Readme.md                             # ← This file
├── CONTEXT_FOR_X64.md                    # Handoff doc from macOS → x64 build
├── build_promptli.sh                     # Self-contained native x64 ISO builder (888 lines)
├── promptli-os-source.zip                # Source archive (if zipped)
├── .gitignore
│
└── promptli-os/                          # The distro source tree
    ├── README.md                         # Distro-specific README
    ├── assistant/
    │   ├── promptli_assistant.py         # Main AI chat desktop app (Python + tkinter)
    │   ├── promptli_daemon.py            # Unix socket daemon for elevated commands
    │   ├── promptli.desktop              # Desktop entry for app launchers
    │   ├── install.sh                    # Installation script
    │   ├── requirements.txt              # Python dependencies: anthropic>=0.39.0
    │   └── assets/
    │       └── wallpaper.svg             # Tokyo Night wallpaper (1920×1080)
    ├── config/
    │   ├── i3/
    │   │   ├── config                    # i3 window manager config (Tokyo Night colors)
    │   │   └── i3status.conf             # Status bar configuration
    │   ├── autostart/
    │   │   └── autostart.sh              # Startup: picom, feh wallpaper, nm-applet, promptli
    │   └── branding/                     # (logos, icons — placeholder)
    ├── tools/
    │   ├── locakhost.py                  # c4mandry's local web server (unchanged)
    │   └── locakhost.desktop             # Desktop entry
    └── build/
        ├── build_iso.sh                  # Docker-based ISO builder
        ├── build_iso_v2.sh               # mmdebstrap attempt (archived)
        ├── build_iso_v3.sh               # Latest build attempt
        ├── live_build_inner.sh           # Inner build logic
        ├── test.sh                       # Quick test runner
        └── output/
            └── promptli-os-1.0.0-amd64.iso  # ✅ First successful build: 651 MB
```

---

## 3. Architecture

```
promptLi OS
├── Debian 13 "Trixie" base         # Stable, well-tested foundation
├── i3 WM                            # Keyboard-driven tiling workflow
│   ├── Super + Enter → Alacritty terminal
│   ├── Super + Space → promptLi Assistant
│   └── Super + D → dmenu app launcher
├── promptLi Assistant       # Desktop AI chat app
│   ├── Multi-provider AI    # Claude, GPT, DeepSeek, Gemini
│   ├── Command execution    # System commands with safety confirmations
│   ├── Audit logging        # All commands logged to ~/.config/promptli/
│   └── System daemon        # Background service for elevated access
├── locakHost                        # CLI web development server
└── Zen Browser                      # Default browser (installed on first boot)
```

### Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Desktop | i3 (not GNOME/KDE) | Lightweight, keyboard-driven, distraction-free |
| AI backend | Multi-provider (Anthropic, OpenAI, DeepSeek, Gemini) | Maximum flexibility |
| AI app framework | Python + tkinter | Matches locakHost's stack, zero extra dependencies |
| Browser | Zen Browser | User's preference; installed first-boot via script |
| locakHost access | CLI wrapper at `/usr/local/bin/locakhost` | Type just `locakhost` in terminal |
| Default user | `promptli` / `promptli` | Auto-login, in sudo group |
| Display manager | LightDM | Simple, reliable |

---

## 4. The promptLi Assistant

### `promptli_assistant.py` — Main Chat App

- **Framework:** Python 3 + tkinter GUI
- **Theme:** Tokyo Night dark color scheme (`#1a1b26` background)
- **Supported Providers:**
  - **Anthropic (Claude)** — `claude-sonnet-4-20250514`, `claude-3-5-sonnet`, `claude-3-opus`, `claude-3-5-haiku`
  - **OpenAI** — `gpt-4o`, `gpt-4o-mini`, `gpt-4-turbo`, `o3-mini`, `o1`
  - **DeepSeek** — `deepseek-chat`, `deepseek-reasoner`
  - **Google Gemini** — `gemini-2.5-pro`, `gemini-2.5-flash`, `gemini-2.0-flash`, `gemini-1.5-pro`
- **Packages required:** `anthropic` + `openai` (DeepSeek & Gemini use OpenAI-compatible endpoints)
- **UI Layout:**
  - Sidebar with **New Chat**, **Settings**, **Command Log** buttons, current provider indicator
  - Chat area with message bubbles (user = blue, AI = dark)
  - Settings panel: Provider selector, API key, model dropdown (dynamic per provider), system prompt
- **Command Execution Flow:**
  1. AI suggests bash commands wrapped in ` ```bash ` blocks
  2. App extracts them and displays **"▶ Run"** buttons
  3. User clicks → confirmation dialog appears
  4. **Danger check** — destructive commands get an extra warning
  5. Runs via `subprocess.run()` with a 120-second timeout
  6. Output displayed in chat, logged to `~/.config/promptli/command_log.json`
- **Persistence:**
  - Chat history saved to `~/.config/promptli/chat_history.json`
  - Command log saved to `~/.config/promptli/command_log.json`
- **Model:** Configurable per provider in Settings
- **System prompt** instructs the AI it has system-level access and should output commands in ` ```bash ` blocks

### `promptli_daemon.py` — System Daemon

- **Protocol:** JSON over Unix socket at `/tmp/promptli-daemon.sock`
- **Purpose:** Run elevated commands (root-level) separately from the GUI
- **Safety:** Same danger keyword detection as the assistant
- **Status:** Exists but **NOT auto-started** — not yet wired into the assistant app
- To use: run manually (`sudo python3 promptli_daemon.py`) or set up as a systemd service

### Getting an API Key

promptLi Assistant supports four providers. Pick the one you want:

| Provider | Sign-up URL |
|---|---|
| **Anthropic (Claude)** | [console.anthropic.com](https://console.anthropic.com) |
| **OpenAI (GPT/o-series)** | [platform.openai.com](https://platform.openai.com) |
| **DeepSeek** | [platform.deepseek.com](https://platform.deepseek.com) |
| **Google Gemini** | [aistudio.google.com](https://aistudio.google.com) |

1. Create an account with your chosen provider and generate an API key
2. Open promptLi Assistant → Settings
3. Select your provider from the dropdown
4. Paste your API key and choose a model
5. Click **Save**

---

## 5. Building the ISO

### Prerequisites

- **Docker** (recommended, cross-platform) — for containerized build
- **Or Debian 12/13 or Ubuntu 22.04/24.04 x86_64** — for native build
- `live-build` package (auto-installed by the build script)

### Option A: Self-Contained Native Builder (Recommended for x64)

```bash
# From the project root:
chmod +x build_promptli.sh
./build_promptli.sh

# Output: ~/promptli-os-output/promptli-os-1.0.0-amd64.iso
# Build time: ~15–30 minutes
```

This 888-line script:
1. Installs `live-build` and all dependencies automatically
2. Generates all project files inline
3. Uses native `debootstrap` (no QEMU needed on x86_64)
4. Builds the ISO

### Option B: Docker-Based Builder

```bash
cd promptli-os/build
bash build_iso.sh
```

Creates `promptli-os/build/output/promptli-os-1.0.0-amd64.iso`.

### Option C: Manual Build (for experts)

```bash
cd promptli-os/build
# Edit live_build_inner.sh to remove QEMU workarounds if on native x64
bash live_build_inner.sh
```

---

## 6. Testing & Running

### Boot the ISO in QEMU

```bash
qemu-system-x86_64 -m 4G \
    -cdrom promptli-os/build/output/promptli-os-1.0.0-amd64.iso \
    -boot d
```

### Test the Assistant Locally (No ISO Needed)

```bash
cd promptli-os
pip install anthropic
python3 assistant/promptli_assistant.py
```

### Test the Daemon

```bash
sudo python3 promptli-os/assistant/promptli_daemon.py
```

---

## 7. Package List

The following packages are installed on the live ISO:

**X11 & Desktop:**
`xorg`, `xinit`, `x11-xserver-utils`, `xterm`

**Window Manager:**
`i3-wm`, `i3status`, `i3lock`, `dmenu`, `suckless-tools`

**Compositing & Wallpaper:**
`picom`, `feh`, `xcompmgr`

**Fonts:**
`fonts-jetbrains-mono`, `fonts-font-awesome`, `fonts-noto`, `fonts-noto-cjk`

**Networking:**
`network-manager`, `network-manager-gnome`, `wireless-tools`, `wpasupplicant`

**Audio:**
`pulseaudio`, `pavucontrol`, `alsa-utils`

**Utilities:**
`curl`, `wget`, `git`, `vim`, `htop`, `unzip`, `p7zip-full`, `scrot`, `xclip`, `brightnessctl`, `arandr`, `lxappearance`

**Python:**
`python3`, `python3-pip`, `python3-tk`, `python3-pil`, `python3-pil.imagetk`

**Terminal & File Manager:**
`alacritty`, `thunar`, `gvfs`, `gvfs-backends`

**System:**
`lightdm`, `lightdm-gtk-greeter`, `sudo`, `polkitd`, `pkexec`, `libasound2`, `libdbus-glib-1-2`, `libgtk-3-0`, `libfuse2`, `fuse`, `rsync`, `linux-image-amd64`, `live-boot`, `systemd-sysv`

> **Note:** `neofetch` was removed (not available in Debian 13), and `policykit-1` was renamed to `polkitd pkexec`.

---

## 8. Default Credentials & Shortcuts

### Live Session Credentials

| Field | Value |
|---|---|
| **Username** | `promptli` |
| **Password** | `promptli` |
| **Auto-login** | Yes (LightDM) |
| **Sudo access** | Yes (member of sudo group) |

### i3 Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Super + Enter` | Open terminal (Alacritty) |
| `Super + Space` | Launch promptLi Assistant |
| `Super + D` | Application launcher (dmenu) |
| `Super + 1-9` | Switch workspace |
| `Super + Shift + Q` | Close window |
| `Super + H / J / K / L` | Navigate windows (left/down/up/right) |
| `Super + Shift + H / J / K / L` | Move windows |
| `Super + F` | Fullscreen toggle |
| `Super + Shift + E` | Exit i3 |

---

## 9. Build History & Lessons Learned

### On Apple Silicon (macOS) — What We Fought Through

Building an amd64 ISO on ARM Mac required many workarounds due to QEMU emulation:

| Approach | Result | Why It Failed |
|---|---|---|
| `live-build` + `debootstrap` | ❌ | QEMU tar extraction bug with `libpam-runtime` |
| `live-build` + `mmdebstrap` wrapper | ❌ | CLI incompatible; live-build hardcoded for debootstrap |
| `mmdebstrap --mode fakechroot` | ❌ | dash shell fd issues; QEMU postinst script failures |
| `mmdebstrap --mode unshare` | ❌ | macOS APFS volume mount broke package scripts |
| `mmdebstrap --mode root` in `/tmp` | ✅ | **Working!** Container's native overlay FS |
| `docker build` with `rm /bin/sh` | ❌ | Broke bash execution under QEMU (baffling bug) |
| `docker build` with `SHELL` directive | ❌ | Also broke binary execution under QEMU |

**The Working Incantation** (for reference):

```bash
docker run --rm --privileged --platform linux/amd64 \
    -v "$PROJECT_DIR:/project:ro" \
    -v "$OUTPUT_DIR:/output" \
    promptli-builder -c '
        # Build in /tmp (container native fs), not mounted volume
        mmdebstrap --mode root --arch amd64 --variant important \
            --hook-dir=/tmp/hooks \
            trixie /tmp/chroot http://deb.debian.org/debian

        # Install extra packages via chroot
        chroot /tmp/chroot apt-get install -y ...

        # Build squashfs + ISO
        mksquashfs /tmp/chroot /tmp/iso/live/filesystem.squashfs
        xorriso -as mkisofs ... -output /output/promptli-os.iso /tmp/iso/
    '
```

### Key Lessons

- **Always build inside `/tmp`**, not a mounted volume — macOS APFS is incompatible with QEMU chroot operations
- **Use `--mode root`**, not `--mode unshare` — more reliable under emulation
- **Add a `policy-rc.d` hook** that exits 101 to prevent service starts during bootstrap
- **Install heavy packages (kernel, Xorg, i3) via `chroot apt-get`** after bootstrap, not in `--include`
- **Neither `fakechroot` nor `fakeroot` helped** — they caused separate, different problems
- **Docker `SHELL` directive on ARM→x86 QEMU silently breaks things**

### On x86_64 (Native) — Should Be Simple

Native x64 builds with `live-build` + `debootstrap` should work without any of the above workarounds. Use `build_promptli.sh` for a one-command build.

> **First successful ISO:** `promptli-os/build/output/promptli-os-1.0.0-amd64.iso` — 651 MB, built on macOS via Docker+QEMU, **not yet boot-tested.**

---

## 10. Known Issues & TODO

### Critical — Must Address

1. **ISO not boot-tested** — Never actually booted the ISO in QEMU or on real hardware
2. **No UEFI support** — ISO only has ISOLINUX (BIOS boot); no GRUB-EFI
3. **Wallpaper is SVG** — `feh` may not render SVG; may need PNG conversion
4. **Wallpaper copy step may be missing** — `autostart.sh` references `/opt/promptli/assets/wallpaper.svg` but the copy step in the build script may be incomplete
5. **Zen Browser requires internet** — Downloaded on first boot via `setup.sh`; if offline, there is no browser at all

### Should Address

6. **`tkinter` on live system** — Needs `python3-tk` (included in package list, but should verify)
7. **No network persistence** — Live ISO changes are lost on reboot (no persistence partition)
8. **No installer** — This is a live ISO only; no option to install to disk
9. **Daemon not auto-started** — `promptli_daemon.py` exists but is not wired into the assistant app
10. **Assistant runs commands directly** — Uses `subprocess` instead of talking to the daemon; runs as current user only

### Nice to Have

11. **No custom icon/logo** — Just text "⚡ promptLi" in the app
12. **No Plymouth boot screen** — Text-mode boot only
13. **Hardcoded paths** — i3 config uses `/opt/promptli/` instead of relative paths
14. **No locale/keyboard configuration** — Defaults to US English

---

## 11. File Reference

| File | Purpose |
|---|---|
| `Readme.md` | **← This file** — comprehensive project documentation |
| `CONTEXT_FOR_X64.md` | Detailed handoff from macOS build → x64 continuation |
| `build_promptli.sh` | Self-contained native x64 ISO builder |
| `promptli-os-source.zip` | Archived copy of the source tree |
| `promptli-os/README.md` | Distro-specific README |
| `promptli-os/assistant/promptli_assistant.py` | Main AI chat desktop app |
| `promptli-os/assistant/promptli_daemon.py` | System daemon for elevated commands |
| `promptli-os/assistant/promptli.desktop` | Desktop entry for the assistant |
| `promptli-os/assistant/install.sh` | Assistant installation script |
| `promptli-os/assistant/requirements.txt` | Python dependencies (`anthropic>=0.39.0`) |
| `promptli-os/assistant/assets/wallpaper.svg` | Tokyo Night wallpaper |
| `promptli-os/tools/locakhost.py` | Local web hosting tool |
| `promptli-os/tools/locakhost.desktop` | Desktop entry for locakHost |
| `promptli-os/config/i3/config` | i3 window manager configuration |
| `promptli-os/config/i3/i3status.conf` | i3status bar configuration |
| `promptli-os/config/autostart/autostart.sh` | Startup script |
| `promptli-os/build/build_iso.sh` | Docker-based ISO builder |
| `promptli-os/build/live_build_inner.sh` | Inner build logic |
| `promptli-os/build/test.sh` | Quick test runner |
| `promptli-os/build/output/promptli-os-1.0.0-amd64.iso` | Built ISO (651 MB, untested) |

---

## 12. License

**MIT** — Build freely, modify freely.

---

## Quick Start Summary

```bash
# 1. Build the ISO (on x64 Linux)
chmod +x build_promptli.sh && ./build_promptli.sh

# 2. Test it
qemu-system-x86_64 -m 4G \
    -cdrom ~/promptli-os-output/promptli-os-1.0.0-amd64.iso \
    -boot d

# 3. Or just run the assistant locally
cd promptli-os
pip install anthropic
python3 assistant/promptli_assistant.py
```

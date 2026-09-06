# PromptLix OS

**AI-powered Debian-based Linux distribution with a system-level AI assistant — GNOME desktop, macOS-premium styling, fully installable.**

---

## Table of Contents

1. [Overview](#1-overview)
2. [Project Structure](#2-project-structure)
3. [Architecture](#3-architecture)
4. [AIDO — the AI Assistant](#4-aido--the-ai-assistant)
5. [Building the ISO](#5-building-the-iso)
6. [Installing to Disk](#6-installing-to-disk)
7. [Testing & Running](#7-testing--running)
8. [Package List](#8-package-list)
9. [Default Credentials & Shortcuts](#9-default-credentials--shortcuts)
10. [Known Issues & TODO](#10-known-issues--todo)
11. [File Reference](#11-file-reference)
12. [License](#12-license)

---

## 1. Overview

PromptLix OS is a **work-focused Linux distribution** built on Debian 13 "Trixie". It features:

- **GNOME** desktop with a **macOS-premium look** — Tokyo Night dark theme, dock at the bottom, window controls on the left, glass effects
- **AIDO** — the AI assistant app: web-based with full system access. The desktop app is a webview of a local website served from a hidden port.
- **AIDO Local** — a fully local, open-source AI desktop operator (llama.cpp + Granite 1B): no cloud, no API keys, natural-language desktop/file/web automation
- **Any AI model** — Anthropic, OpenAI, DeepSeek, Gemini, or any OpenAI-compatible endpoint (Ollama, LM Studio, OpenRouter, vLLM, ...)
- **Locked system prompt** — the user cannot edit the AI's system prompt
- **Live window awareness** — the AI receives a JSONC reference (`windows.jsonc`) describing every visible window: program, title, position, size, fullscreen state, and focus
- **locakHost** — local web hosting tool by [c4mandry](https://github.com/c4mandry/locakHost)
- **Zen Browser** — the default and only browser
- **Calamares installer** — install PromptLix permanently to your hard drive

---

## 2. Project Structure

```
PromptLix_os/                             # Project root
├── Readme.md                             # ← This file
├── CONTEXT_FOR_X64.md                    # Historical handoff doc (macOS → x64, i3 era)
├── BRANDING_ASSETS.md                    # Visual assets that still need rebranding
├── build_promptlix.sh                    # Native x64 ISO builder (one command)
├── .gitignore
│
└── promptlix-os/                         # The distro source tree
    ├── README.md                         # Distro-specific README
    ├── assistant/
    │   ├── promptlix-server.py           # Local web server: hidden port, token auth, AI + commands
    │   ├── promptlix-webview.py          # Desktop webview (GTK WebKit2) around the web UI
    │   ├── promptlix_windowd.py          # Window tracker → windows.jsonc (JSONC desktop reference)
    │   ├── system_prompt.txt             # LOCKED system prompt (not editable from the UI)
    │   ├── promptlix.desktop             # Desktop entry for app launchers
    │   ├── install.sh                    # Assistant installation script
    │   ├── requirements.txt              # Python dependencies: anthropic, openai
    │   ├── web/
    │   │   └── index.html                # The macOS-style assistant UI (CSS + JS)
    │   └── assets/
    │       └── wallpaper.svg             # Tokyo Night wallpaper (converted to PNG at build)
    ├── config/
    │   └── autostart/
    │       ├── promptlix.desktop         # Autostarts the assistant on login
    │       ├── promptlix-gnome-setup.desktop  # One-time GNOME theming (self-removing)
    │       └── gnome-setup.sh            # Tokyo Night + macOS-style GNOME preset
    ├── tools/
    │   ├── locakhost.py                  # c4mandry's local web server (unchanged)
    │   └── locakhost.desktop             # Desktop entry
    └── build/
        ├── build_iso.sh                  # Docker-based ISO builder
        ├── live_build_inner.sh           # Inner build logic (live-build + Calamares)
        ├── test.sh                       # Quick test runner
        └── output/
            └── promptlix-os-1.0.0-amd64.iso  # Built ISO
```

---

## 3. Architecture

```
PromptLix OS
├── Debian 13 "Trixie" base         # Stable, well-tested foundation
├── GNOME desktop                   # GDM auto-login (X11), macOS-premium theming
├── AIDO (assistant app)             # Web app + local backend
│   ├── promptlix-server            # 127.0.0.1:18437 (hidden port, token auth)
│   │   ├── AI chat                 # Any model: Anthropic / OpenAI-compatible / custom
│   │   ├── Command execution       # Run buttons, danger checks, audit log
│   │   └── Desktop awareness       # windows.jsonc injected into the AI context
│   ├── promptlix-webview           # Desktop shell (GTK WebKit2) around the website
│   └── promptlix_windowd           # xdotool-based window tracker (2s refresh)
├── AIDO Local (offline AI)        # Fully offline AI desktop operator
│   ├── aido CLI                   # REPL + one-shot natural-language commands
│   ├── aido --gui                 # Tkinter chat GUI (desktop entry included)
│   ├── Local model                # IBM Granite 4.0 H 1B GGUF (~700MB, auto-download)
│   └── Desktop/file/web tools     # window control, config edits, browsing, downloads
├── Calamares installer             # Graphical disk installer (UEFI + BIOS)
├── locakHost                       # CLI web development server
└── Zen Browser                     # Default browser (installed on first boot)
```

### The web-app model

- `promptlix-server.py` binds **127.0.0.1:18437** (a hidden, local-only port) and serves the assistant website from `/opt/promptlix/web/`. It is never exposed to the network.
- Every `/api/*` call requires a bearer token stored in `~/.config/promptlix/server_token` (0600). The webview reads the file and passes the token — it never appears on a command line.
- The desktop app (`promptlix-webview.py`) is just a GTK WebKit2 frame around the website — the website IS the app.
- `promptlix_windowd.py` scans the visible windows every 2 seconds (via xdotool) and writes `~/.config/promptlix/windows.jsonc` — a JSONC document describing each window's program, title, position, size, fullscreen state, and focus. The server injects this into the AI's context on every request, so the AI is aware of the user's actual desktop.
- The system prompt is **locked**: it lives in `/opt/promptlix/system_prompt.txt` (root-owned) and there is no prompt editor in the UI.

### Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Desktop | GNOME, X11 session (GDM) | macOS-premium look; X11 required for window tracking |
| Assistant UI | Local website + webview | Premium HTML/CSS UI, easy to iterate, "app = webview" |
| Assistant backend | Python stdlib HTTP server on 127.0.0.1:18437 | Zero web-framework deps, hidden local port |
| AI backend | Anthropic SDK + OpenAI-compatible (incl. custom) | Any model: Claude, GPT, DeepSeek, Gemini, Ollama, ... |
| System prompt | Locked file, no UI editor | User cannot alter the AI's behavior contract |
| Window awareness | xdotool → windows.jsonc (JSONC) | AI knows what is on screen, where, and how big |
| Installer | Calamares (unpackfs from live squashfs) | Standard, graphical, proven approach |
| Boot | iso-hybrid (BIOS + UEFI) | Boots on both legacy and modern machines |
| Default user | `promptlix` / `promptlix` | Auto-login, in sudo group |

---

## 4. AIDO — the AI Assistant

### How to use it

1. AIDO is **fully up at every boot**: a systemd user service starts the server at login (hidden port always listening), and GNOME autostart opens the AIDO window on the PromptLix-branded desktop.
2. First time, open **Settings** and pick a provider, paste an API key, and choose a model — or point a custom provider at any OpenAI-compatible URL (e.g. `http://localhost:11434/v1` for Ollama).
3. Ask the AI anything. It has full system access: it can run shell commands (each wrapped in a ```bash block becomes a **Run** button with a confirmation dialog), manage files, install packages, and see your desktop.

### Supported providers

| Provider | Default endpoint | Example models |
|---|---|---|
| Anthropic (Claude) | native SDK | `claude-sonnet-4-20250514`, `claude-3-5-sonnet`, `claude-3-opus` |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o`, `gpt-4o-mini`, `o3-mini` |
| DeepSeek | `https://api.deepseek.com` | `deepseek-chat`, `deepseek-reasoner` |
| Google Gemini | OpenAI-compatible endpoint | `gemini-2.5-flash`, `gemini-2.5-pro` |
| Custom (any) | anything you type | Ollama, LM Studio, OpenRouter, vLLM, local models |

Model names are editable — you can type any model the endpoint supports.

### Safety model

- Every command the AI suggests must be approved by clicking **Run** (confirmation dialog first).
- Commands matching dangerous patterns (disk wiping, formatting, recursive deletes on `/`, shutdown, ...) get a red warning and are **blocked server-side** unless the user re-confirms.
- Every executed command is logged to `~/.config/promptlix/command_log.json` (0600) with timestamp, exit code, and output. View it from the Command Log panel.
- The hidden port requires the bearer token for all API calls; the port binds to localhost only.

### Window awareness (windows.jsonc)

`promptlix_windowd.py` refreshes `~/.config/promptlix/windows.jsonc` every 2 seconds:

```jsonc
{
  // Live desktop reference for PromptLix AI.
  // Coordinates are pixels from the top-left.
  "screen": { "width": 1920, "height": 1080 },
  "windows": [
    { "id": "0x0400002", "name": "Zen Browser", "class": "zen",
      "x": 120, "y": 80, "width": 1280, "height": 900,
      "fullscreen": false, "focused": true, "on_screen": true }
  ]
}
```

The AI receives this on every request, so it can answer "what's on my screen", "is my editor fullscreen", or "where is the terminal window" — and act on it.

---

## 5. Building the ISO

### Prerequisites

- **Debian 12/13 or Ubuntu 22.04/24.04 x86_64** — for the native build (recommended)
- **Or Docker** — for a containerized build on any host
- Root/sudo access on the build machine

### Option A: Native Builder (Recommended for x64)

```bash
# From the project root:
chmod +x build_promptlix.sh
./build_promptlix.sh

# Output: ~/promptlix-os-output/promptlix-os-1.0.0-amd64.iso
# Build time: ~15–45 minutes
```

### Option B: Docker-Based Builder

```bash
cd promptlix-os/build
bash build_iso.sh
# Output: promptlix-os/build/output/promptlix-os-1.0.0-amd64.iso
```

---

## 6. Installing to Disk

1. Write the ISO to a USB stick (`sudo dd if=promptlix-os-1.0.0-amd64.iso of=/dev/sdX bs=4M status=progress && sync`) or boot it in QEMU/VirtualBox.
2. Boot the medium (BIOS or UEFI — both supported).
3. In the live desktop, launch the installer: **Super + I**, or press **Super** and search "Install PromptLix".
4. Calamares walks you through disk selection ("Erase disk" is the default layout), user creation (defaults to `promptlix` / `promptlix`), and installs GRUB.
5. Reboot into your installed PromptLix. Changes persist; first boot downloads Zen Browser and Python deps if online.

> Secure Boot must be off (the ISO is unsigned). Remove the USB stick before rebooting if you installed to the same disk.

---

## 7. Testing & Running

```bash
# Boot the ISO in QEMU
qemu-system-x86_64 -m 4G \
    -cdrom promptlix-os/build/output/promptlix-os-1.0.0-amd64.iso \
    -boot d

# Run the assistant server standalone (no ISO needed)
cd promptlix-os/assistant
pip install -r requirements.txt
python3 promptlix-server.py          # serves http://127.0.0.1:18437
python3 promptlix-webview.py         # or open it in a browser with ?token=<token>

# Run AIDO locally (no ISO needed)
cd aido
pip install -r requirements.txt
bash scripts/download_model.sh       # ~700MB local Granite model
PYTHONPATH=src python3 src/aido.py   # or: aido --gui
```

### AIDO Local — the offline operator

AIDO Local runs entirely on your hardware: a 700MB quantized Granite 1B model via llama.cpp, no cloud calls, no API keys. It opens apps, manages windows (move/resize/focus), lists and edits config files (with backups), browses/downloads from the web, and logs every action to `~/.aido/logs/aido.log`. File access is sandboxed to `~` by default (`safety.allowed_dirs` in `~/.aido/aido.yaml`).

### Boot troubleshooting (if the ISO won't boot)

1. The live boot is **verbose** — kernel and init messages are visible. Note the last lines before any loop.
2. For even more detail, edit the boot entry and append `debug` to the kernel line (or pass `boot=live debug`).
3. Report: the last screen output, whether you boot BIOS or UEFI, and whether it's QEMU/VirtualBox or real hardware. Known weak spots to check first:
   - **BIOS boot via ISOLINUX** — try the UEFI boot path (or vice versa); some firmwares dislike the hybrid MBR.
   - **Kernel panic after initramfs** — screenshot the trace; it names the failing module/driver.
   - **Display manager loop (flashing login)** — GDM restarting: check `journalctl -u gdm3` after booting with `systemd.debug-shell` or from a chroot.

---

## 8. Package List

The following packages are installed on the ISO (and therefore on the installed system):

**Kernel & live boot:** `linux-image-amd64`, `live-boot`, `systemd-sysv`

**Installer:** `calamares`, `squashfs-tools`, `dosfstools`, `grub-pc-bin`, `grub-efi-amd64-bin`, `grub2-common`, `os-prober`

**GNOME desktop:** `gnome-core`, `gnome-tweaks`, `gdm3`, `file-roller`, `librsvg2-common`, `pipewire-pulse`, `gnome-shell-extension-dashtodock`, `plymouth`

**X11:** `xorg`, `x11-utils`, `xdotool`, `wmctrl` (window tracking + AIDO window tools)

**Fonts:** `fonts-jetbrains-mono`, `fonts-noto`, `fonts-noto-cjk`

**Networking:** `network-manager`, `wireless-tools`, `wpasupplicant`

**Audio:** `alsa-utils`

**Utilities:** `curl`, `wget`, `git`, `vim`, `htop`, `unzip`, `p7zip-full`, `xclip`, `brightnessctl`

**Python:** `python3`, `python3-pip`, `python3-gi`, `gir1.2-webkit2-4.1` (webview), `python3-tk` (AIDO GUI), `python3-pil`

**System:** `sudo`, `polkitd`, `pkexec`, `libasound2`, `libdbus-glib-1-2`, `libgtk-3-0`, `libfuse2`, `fuse`, `rsync`, `unattended-upgrades`

---

## 9. Default Credentials & Shortcuts

### Credentials

| Field | Value |
|---|---|
| **Username** | `promptlix` |
| **Password** | `promptlix` |
| **Auto-login** | Yes (GDM) |
| **Sudo access** | Yes (passwordless for the default user) |

### GNOME Shortcuts

| Shortcut | Action |
|---|---|
| `Super` | Overview (apps + search) |
| `Super + Enter` | Open terminal |
| `Super + I` | Launch installer (Calamares) |
| `Alt + Tab` | Switch windows |
| `Super + Tab` | Switch applications |
| `Print` | Screenshot |

The dock (dash-to-dock) sits at the bottom, macOS-style, with window controls on the left of every titlebar.

---

## 10. Known Issues & TODO

### Should Address

1. **Not yet boot-tested** — this web-assistant rewrite has not been built or booted; test in QEMU before trusting real hardware
2. **X11 session forced** — GDM runs X11 (not Wayland) because window tracking via xdotool requires it. Tradeoff: Wayland is more secure; document if you revisit this
3. **No Secure Boot support** — the ISO is unsigned (UEFI works with Secure Boot disabled)
4. **Zen Browser requires internet** — downloaded on first boot; if offline, there is no browser
5. **Placeholder branding** — Calamares images, app icons, and the wallpaper are placeholders (see `BRANDING_ASSETS.md`)
6. **Passwordless sudo for the default user** — convenience tradeoff; revisit for hardening
7. **"Locked" system prompt is filesystem-locked** — the UI has no editor, and the file is root-owned; a user with sudo could still edit it
8. **Local web surface** — the assistant API runs on a hidden localhost port with token auth; treat the token file as a secret

### Nice to Have

9. **No custom icon/logo** — placeholder art in the app, Plymouth splash, and Calamares (see `BRANDING_ASSETS.md`)
10. **No locale/keyboard configuration** — defaults to US English
12. **Boot menu has no direct "Install" entry** — the installer is launched from the live desktop (Super+I)
13. **No conversation persistence** — chat history resets when the page reloads (live session resets anyway; installed systems could persist)

### Kernel & supply-chain security

The kernel is Debian's official `linux-image-amd64` (kernel.org source, GPG-signed via secure APT — nothing kernel-related is built or modified by this project). `unattended-upgrades` auto-applies Debian-Security kernel CVE patches. Extra hardening ships by default: `/etc/sysctl.d/99-promptlix-hardening.conf` (kptr/dmesg restrict, unprivileged eBPF disabled, ASLR, Yama ptrace, protected_* filesystem flags, network hygiene). Kernel lockdown is available but off by default (breaks unsigned DKMS modules — VirtualBox/NVIDIA).

---

## 11. File Reference

| File | Purpose |
|---|---|
| `Readme.md` | **← This file** — comprehensive project documentation |
| `BRANDING_ASSETS.md` | List of visual assets needing rebranding |
| `CONTEXT_FOR_X64.md` | Historical handoff (macOS → x64, i3 era) |
| `build_promptlix.sh` | Native x64 ISO builder (one command) |
| `promptlix-os/README.md` | Distro-specific README |
| `promptlix-os/assistant/promptlix-server.py` | Local web server: hidden port, token auth, AI chat, commands, window context |
| `promptlix-os/assistant/promptlix-webview.py` | Desktop webview (GTK WebKit2) |
| `promptlix-os/assistant/promptlix_windowd.py` | Window tracker → windows.jsonc |
| `promptlix-os/assistant/system_prompt.txt` | Locked system prompt |
| `promptlix-os/assistant/web/index.html` | The macOS-style assistant UI |
| `promptlix-os/assistant/promptlix.desktop` | Desktop entry for the assistant |
| `promptlix-os/assistant/install.sh` | Assistant installation script |
| `promptlix-os/assistant/requirements.txt` | Python dependencies |
| `promptlix-os/assistant/assets/wallpaper.svg` | Tokyo Night wallpaper (PNG generated at build) |
| `promptlix-os/tools/locakhost.py` | Local web hosting tool |
| `promptlix-os/tools/locakhost.desktop` | Desktop entry for locakHost |
| `promptlix-os/config/autostart/promptlix.desktop` | GNOME autostart for the assistant |
| `promptlix-os/config/autostart/promptlix-gnome-setup.desktop` | One-time GNOME theming (self-removing) |
| `promptlix-os/config/autostart/gnome-setup.sh` | Tokyo Night + macOS-style GNOME preset |
| `promptlix-os/build/build_iso.sh` | Docker-based ISO builder |
| `promptlix-os/build/live_build_inner.sh` | Inner build logic (live-build + Calamares config) |
| `promptlix-os/build/test.sh` | Quick test runner |
| `aido/` | AIDO Local — fully local AI desktop operator (src, config, scripts, tests) |

Boot experience: GRUB shows "PromptLix" (via `GRUB_DISTRIBUTOR` + Calamares `bootloaderEntryName`), a Plymouth splash theme (`/usr/share/plymouth/themes/promptlix/`) shows a Tokyo Night logo screen during boot, and the GDM login/lock screen uses the PromptLix wallpaper + dark theme (dconf profile `gdm`). The assistant server runs as a systemd user service (`promptlix-server.service`) enabled for every new user via `/etc/skel`.

---

## 12. License

**MIT** — Build freely, modify freely.

---

## Quick Start Summary

```bash
# 1. Build the ISO (on x64 Linux)
chmod +x build_promptlix.sh && ./build_promptlix.sh

# 2. Boot it (live session)
qemu-system-x86_64 -m 4G \
    -cdrom ~/promptlix-os-output/promptlix-os-1.0.0-amd64.iso \
    -boot d

# 3. Install it permanently
#    In the live desktop: Super+I → Calamares → pick disk → reboot

# 4. Or just run the assistant locally (server + webview)
cd promptlix-os/assistant
pip install -r requirements.txt
python3 promptlix-server.py &
python3 promptlix-webview.py
```

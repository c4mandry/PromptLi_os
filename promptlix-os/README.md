# PromptLix OS

**AI-powered Debian-based Linux distribution with system-level AI assistant.**

## Overview

PromptLix OS is a work-focused Linux distro built on Debian 13 "Trixie" featuring:

- **GNOME** desktop — macOS-premium look: Tokyo Night dark theme, bottom dock, window controls on the left
- **AIDO** — the assistant app: a website with full system access, shown in a desktop webview
- **AIDO Local** — fully offline AI desktop operator (local model, no cloud, `aido` / `aido --gui`)
- **Any AI model** — Anthropic, OpenAI, DeepSeek, Gemini, or any OpenAI-compatible endpoint
- **Locked system prompt** — not editable from the UI
- **Live window awareness** — the AI sees a JSONC desktop reference (windows.jsonc)
- **Calamares installer** — install permanently to disk (BIOS + UEFI)
- **locakHost** — local web hosting tool by c4mandry
- **Zen Browser** — default and only browser (installed on first boot)

## Architecture

```
PromptLix OS
├── GNOME desktop            # GDM auto-login (X11), macOS-premium theming
├── Boot branding            # GRUB "PromptLix", Plymouth splash theme, themed login screen
├── AIDO (assistant app)      # Web app + local backend, starts on boot
│   ├── server (127.0.0.1:18437, token auth)   # AI chat + command execution
│   ├── webview (GTK WebKit2)                  # Desktop shell around the website
│   └── windowd (xdotool)                      # windows.jsonc every 2s
├── Calamares installer      # Graphical installer (erase-disk layout)
├── locakHost                # Web development server
└── Debian 13 base           # Stable, well-tested foundation
```

## Directory Structure

```
promptlix-os/
├── assistant/
│   ├── promptlix-server.py       # Local web server: hidden port, token auth, AI + commands
│   ├── promptlix-webview.py      # Desktop webview (GTK WebKit2)
│   ├── promptlix_windowd.py      # Window tracker → windows.jsonc
│   ├── system_prompt.txt         # LOCKED system prompt
│   ├── promptlix.desktop         # Desktop entry for app launcher
│   ├── install.sh                # Assistant installation script
│   ├── requirements.txt          # Python dependencies
│   ├── web/
│   │   └── index.html            # The macOS-style assistant UI
│   └── assets/
│       └── wallpaper.svg         # Default wallpaper (PNG generated at build)
├── config/
│   └── autostart/
│       ├── promptlix.desktop     # GNOME autostart for the assistant
│       ├── promptlix-gnome-setup.desktop  # One-time GNOME theming
│       └── gnome-setup.sh        # Tokyo Night + macOS-style GNOME preset
├── tools/
│   ├── locakhost.py              # Local web hosting tool
│   └── locakhost.desktop         # Desktop entry
└── build/
    ├── build_iso.sh              # Docker-based ISO builder
    ├── live_build_inner.sh       # Inner build logic (live-build + Calamares)
    └── test.sh                   # Quick test runner
```

## Building the ISO

### Prerequisites

- **Debian/Ubuntu x86_64** with `live-build` (native, recommended), or
- **Docker** for a containerized build

### Quick Build

```bash
# Native (from the project root, one level up):
chmod +x ../build_promptlix.sh && ../build_promptlix.sh

# Or Docker:
cd build && bash build_iso.sh
```

This creates `build/output/promptlix-os-1.0.0-amd64.iso` (takes 15–45 minutes).

## Installing to Disk

1. Boot the ISO (QEMU, VirtualBox, or a USB stick — BIOS or UEFI).
2. In the live desktop press **Super+I** (or press Super and search "Install PromptLix").
3. Follow Calamares: pick a disk (erase-disk is the default layout), set user (default `promptlix` / `promptlix`), wait for GRUB to install.
4. Reboot into your installed, persistent PromptLix.

## Testing

```bash
# Boot the ISO in QEMU
qemu-system-x86_64 -m 4G -cdrom build/output/promptlix-os-1.0.0-amd64.iso -boot d

# Run the assistant locally (no ISO needed)
cd assistant
pip install -r requirements.txt
python3 promptlix-server.py     # http://127.0.0.1:18437
python3 promptlix-webview.py
```

## Default Credentials

- **Username:** `promptlix`
- **Password:** `promptlix`
- Auto-login enabled (GDM); passwordless sudo for the default user.

## Key Shortcuts (GNOME)

| Shortcut | Action |
|---|---|
| `Super` | Overview (apps + search) |
| `Super + Enter` | Open terminal |
| `Super + I` | Launch installer (Calamares) |
| `Alt + Tab` | Switch windows |
| `Super + Tab` | Switch applications |

## Assistant Security Model

- Server starts automatically at every boot: systemd user service `promptlix-server.service` (hidden port 127.0.0.1:18437, bearer token in `~/.config/promptlix/server_token`, 0600)
- The desktop webview opens the UI at login (GNOME autostart)
- Every AI-suggested command needs explicit Run approval; dangerous patterns are blocked server-side and re-confirmed
- Full audit log at `~/.config/promptlix/command_log.json` (0600)
- System prompt locked in `/opt/promptlix/system_prompt.txt` (root-owned, no UI editor)

## Getting an API Key

| Provider | Sign-up URL |
|---|---|
| Anthropic (Claude) | [console.anthropic.com](https://console.anthropic.com) |
| OpenAI | [platform.openai.com](https://platform.openai.com) |
| DeepSeek | [platform.deepseek.com](https://platform.deepseek.com) |
| Google Gemini | [aistudio.google.com](https://aistudio.google.com) |

Or use a custom OpenAI-compatible endpoint (Ollama, LM Studio, OpenRouter, vLLM) — no sign-up needed for local models.

## License

MIT — Build freely, modify freely.

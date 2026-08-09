# ⚡ promptLi OS

**AI-powered Debian-based Linux distribution with system-level AI assistant.**

## Overview

promptLi OS is a work-focused Linux distro built on Debian 13 "Trixie" featuring:

- **i3** tiling window manager — fast, keyboard-driven workflow
- **promptLi Assistant** — Claude-powered AI with system-level control
- **locakHost** — local web hosting tool by c4mandry
- Tokyo Night dark theme throughout

## Architecture

```
promptLi OS
├── i3 WM                    # Keyboard-driven tiling workflow
├── promptLi Assistant       # Desktop AI chat app
│   ├── Claude API           # Anthropic's Claude for reasoning
│   ├── Command execution    # System commands with safety confirmations
│   ├── Audit logging        # All commands logged to ~/.config/promptli/
│   └── System daemon        # Background service for elevated access
├── locakHost                # Web development server
└── Debian 13 base           # Stable, well-tested foundation
```

## Directory Structure

```
promptli-os/
├── assistant/
│   ├── promptli_assistant.py    # Main AI chat desktop app
│   ├── promptli_daemon.py       # System daemon for elevated commands
│   ├── promptli.desktop         # Desktop entry for app launcher
│   ├── install.sh               # Installation script
│   ├── requirements.txt         # Python dependencies
│   └── assets/
│       └── wallpaper.svg        # Default wallpaper
├── config/
│   ├── i3/
│   │   ├── config               # i3 window manager config
│   │   └── i3status.conf        # Status bar configuration
│   ├── autostart/
│   │   └── autostart.sh         # Startup script
│   └── branding/                # (logos, icons)
├── tools/
│   ├── locakhost.py             # Local web hosting tool
│   └── locakhost.desktop        # Desktop entry
└── build/
    ├── build_iso.sh             # ISO builder (Docker-based)
    ├── live_build_inner.sh      # Inner build logic
    └── test.sh                  # Quick test runner
```

## Building the ISO

### Prerequisites
- **Docker** (recommended) — for containerized build
- Or **Debian/Ubuntu** with `live-build` installed

### Quick Build

```bash
cd build
bash build_iso.sh
```

This creates `build/output/promptli-os-1.0.0-amd64.iso` (takes 15–30 minutes).

### Testing

```bash
# Test with QEMU
qemu-system-x86_64 -m 4G -cdrom build/output/promptli-os-1.0.0-amd64.iso -boot d

# Test the assistant app locally (no ISO needed)
python3 assistant/promptli_assistant.py
```

## Default Credentials

Live session:
- **Username:** `promptli`
- **Password:** `promptli`

## Key Shortcuts (i3)

| Shortcut | Action |
|---|---|
| `Super + Enter` | Open terminal (Alacritty) |
| `Super + Space` | Launch promptLi Assistant |
| `Super + D` | Application launcher (dmenu) |
| `Super + 1-9` | Switch workspace |
| `Super + Shift + Q` | Close window |
| `Super + H/J/K/L` | Navigate windows |
| `Super + Shift + H/J/K/L` | Move windows |

## AI Assistant Features

- **Chat interface** — Communicate with Claude naturally
- **System commands** — Claude suggests bash commands, you approve them
- **Safety layer** — Dangerous commands get extra warnings, everything is logged
- **Command log** — Full audit trail at `~/.config/promptli/command_log.json`
- **Configurable** — Set your own API key, model, and system prompt

### Getting an API Key

1. Go to [console.anthropic.com](https://console.anthropic.com)
2. Create an account and generate an API key
3. Enter it in promptLi Assistant → Settings

## License

MIT — Build freely, modify freely.

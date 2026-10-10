#!/bin/bash
# ================================================================
#  promptLi OS — Native x86_64 Builder
#  Run this on a Debian/Ubuntu x86_64 machine.
#  All QEMU workarounds removed since we are native.
# ================================================================
set -euo pipefail

echo "================================================"
echo "  promptLi OS — Native x86_64 ISO Builder"
echo "================================================"
echo ""
echo "This script will:"
echo "  1. Install build dependencies (live-build etc.)"
echo "  2. Build a custom, minimal Debian live ISO (server-focused, no WM/DE):"
echo "     - promptLi AI Assistant (Claude API + system control)"
echo "     - locakHost web server (terminal: just type 'locakhost')"
echo "     - Rust TUI installer (promptli-install) + updater (promptli-update)"
echo "  3. Output: promptli-os-1.0.0-amd64.iso"
echo ""

ISO_NAME="promptli-os-1.0.0-amd64"
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
rm -rf "$BUILD_DIR" "$OUTPUT_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
cd "$BUILD_DIR"

echo "[*] Configuring live-build..."

# Configure
lb config noauto \
    --architecture amd64 \
    --distribution trixie \
    --archive-areas "main contrib non-free non-free-firmware" \
    --bootappend-live "boot=live components quiet" \
    --debian-installer none \
    --iso-application "promptLi OS" \
    --iso-publisher "promptLi" \
    --iso-volume "promptLi OS 1.0.0" \
    --linux-flavours amd64 \
    --memtest none \
    --binary-images iso-hybrid

# ── Package list ─────────────────────────────────────────
echo "[*] Setting package list..."
cat > config/package-lists/promptli.list.chroot << 'PACKAGES'
# promptLi OS — minimal, server-focused base.
# No window manager, no desktop environment, no Xorg — boots to a console TTY.

# Base system & boot
linux-image-amd64 live-boot live-config live-tools
systemd-sysv sudo adduser

# Shell: zsh with autosuggestions + syntax highlighting
zsh zsh-autosuggestions zsh-syntax-highlighting zsh-common

# Modern terminal tools
fastfetch fzf eza bat ripgrep fd-find zoxide btop tmux

# Console utilities
curl wget git vim htop unzip p7zip-full less
rsync ca-certificates

# Networking
network-manager wireless-tools wpasupplicant iproute2 iw

# Disk / provisioning (used by the Rust installer; sfdisk ships in util-linux)
parted fdisk util-linux dosfstools
squashfs-tools gdisk cryptsetup

# Bootloader (installed to disk by the installer; grub-pc-bin avoids the
# interactive device prompt that grub-pc's postinst would trigger in-chroot)
grub-pc-bin grub-efi-amd64 grub-efi-amd64-bin os-prober

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
mkdir -p "$PROJECT_DIR"/{assistant/assets,tools}

# --- promptLi Assistant ---
cat > "$PROJECT_DIR/assistant/promptli_assistant.py" << 'PYEOF'
#!/usr/bin/env python3
"""
promptLi Assistant — AI chat with system-level control.
Powered by Claude API. Built for promptLi OS.
"""

import json
import os
import re
import subprocess
import sys
import threading
import time
import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext
from pathlib import Path

CONFIG_DIR = Path.home() / ".config" / "promptli"
CONFIG_FILE = CONFIG_DIR / "config.json"
LOG_FILE = CONFIG_DIR / "command_log.json"
HISTORY_FILE = CONFIG_DIR / "chat_history.json"

DEFAULT_CONFIG = {
    "api_key": "",
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 4096,
    "system_prompt": (
        "You are promptLi, an AI assistant with system-level access on promptLi OS. "
        "You can help the user by running shell commands, managing files, installing packages, "
        "and configuring the system. When you want to run a command, wrap it in ```bash``` blocks. "
        "The user will be prompted to approve each command before execution. "
        "Be concise and helpful. Explain what each command does before suggesting it."
    ),
}

DANGEROUS_KEYWORDS = [
    "rm -rf /", "mkfs.", "dd if=", "format", "fdisk",
    "> /dev/sd", "chmod 777 /", ":(){ :|:& };:",
]

THEME = {
    "bg": "#1a1b26", "fg": "#c0caf5",
    "user_bubble": "#7aa2f7", "ai_bubble": "#3b4261",
    "accent": "#bb9af7", "danger": "#f7768e",
    "success": "#9ece6a", "warning": "#e0af68",
    "input_bg": "#24283b", "sidebar_bg": "#16161e",
    "border": "#3b4261",
}


def load_config():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    if CONFIG_FILE.exists():
        with open(CONFIG_FILE) as f:
            cfg = json.load(f)
            for k, v in DEFAULT_CONFIG.items():
                cfg.setdefault(k, v)
            return cfg
    return dict(DEFAULT_CONFIG)


def save_config(cfg):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2)


def log_command(command, approved, output="", error=""):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    entry = {"timestamp": time.strftime("%Y-%m-%d %H:%M:%S"), "command": command,
             "approved": approved, "output": output[:2000], "error": error[:2000]}
    logs = []
    if LOG_FILE.exists():
        with open(LOG_FILE) as f:
            try: logs = json.load(f)
            except: pass
    logs.append(entry)
    with open(LOG_FILE, "w") as f:
        json.dump(logs[-500:], f, indent=2)


def is_dangerous(command):
    cmd = command.lower().strip()
    return any(kw.lower() in cmd for kw in DANGEROUS_KEYWORDS)


def extract_commands(text):
    return [m.strip() for m in re.findall(r"```bash\n?(.*?)```", text, re.DOTALL) if m.strip()]


class AssistantApp:
    def __init__(self, root):
        self.root = root
        self.root.title("promptLi Assistant")
        self.root.geometry("900x650")
        self.root.minsize(700, 500)
        self.root.configure(bg=THEME["bg"])
        self.config = load_config()
        self.anthropic_client = None
        self.conversation = []
        self.streaming = False
        self._init_anthropic()
        self._build_ui()
        self._load_history()

    def _init_anthropic(self):
        api_key = self.config.get("api_key", "")
        if api_key:
            try:
                import anthropic
                self.anthropic_client = anthropic.Anthropic(api_key=api_key)
            except: pass

    def _build_ui(self):
        self.paned = tk.PanedWindow(self.root, bg=THEME["border"], sashwidth=2, orient=tk.HORIZONTAL)
        self.paned.pack(fill=tk.BOTH, expand=True)

        # Sidebar
        sidebar = tk.Frame(self.paned, bg=THEME["sidebar_bg"], width=220)
        self.paned.add(sidebar, minsize=180)
        tk.Label(sidebar, text="⚡ promptLi", font=("Helvetica", 18, "bold"),
                 fg=THEME["accent"], bg=THEME["sidebar_bg"]).pack(pady=(20, 5))
        tk.Label(sidebar, text="Claude-powered\nsystem assistant", font=("Helvetica", 10),
                 fg=THEME["fg"], bg=THEME["sidebar_bg"], justify=tk.CENTER).pack(pady=(0, 20))
        ttk.Separator(sidebar, orient=tk.HORIZONTAL).pack(fill=tk.X, padx=15)

        btn = {"font": ("Helvetica", 11), "bg": THEME["input_bg"], "fg": THEME["fg"],
               "activebackground": THEME["accent"], "activeforeground": "#000",
               "bd": 0, "cursor": "hand2", "relief": tk.FLAT}
        tk.Button(sidebar, text="＋ New Chat", command=self.new_chat, **btn).pack(fill=tk.X, padx=15, pady=(20, 5), ipady=8)
        tk.Button(sidebar, text="⚙ Settings", command=self.open_settings, **btn).pack(fill=tk.X, padx=15, pady=5, ipady=8)
        tk.Button(sidebar, text="📋 Command Log", command=self.show_log, **btn).pack(fill=tk.X, padx=15, pady=5, ipady=8)
        self.status_label = tk.Label(sidebar, text="● Ready", font=("Helvetica", 10),
                                      fg=THEME["success"], bg=THEME["sidebar_bg"])
        self.status_label.pack(side=tk.BOTTOM, pady=15)

        # Chat area
        chat_frame = tk.Frame(self.paned, bg=THEME["bg"])
        self.paned.add(chat_frame, minsize=400)
        self.chat_canvas = tk.Canvas(chat_frame, bg=THEME["bg"], highlightthickness=0, bd=0)
        self.chat_scrollbar = tk.Scrollbar(chat_frame, orient=tk.VERTICAL, command=self.chat_canvas.yview)
        self.chat_messages = tk.Frame(self.chat_canvas, bg=THEME["bg"])
        self.chat_messages.bind("<Configure>", lambda e: self.chat_canvas.configure(scrollregion=self.chat_canvas.bbox("all")))
        self.chat_window = self.chat_canvas.create_window((0, 0), window=self.chat_messages, anchor="nw", tags="messages")
        self.chat_canvas.configure(yscrollcommand=self.chat_scrollbar.set)
        self.chat_canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.chat_scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        self.chat_canvas.bind("<Configure>", lambda e: self.chat_canvas.itemconfig(self.chat_window, width=e.width))
        self.chat_canvas.bind_all("<MouseWheel>", lambda e: self.chat_canvas.yview_scroll(int(-1 * (e.delta / 120)), "units"))

        # Input
        input_frame = tk.Frame(self.root, bg=THEME["input_bg"], height=60)
        input_frame.pack(fill=tk.X, side=tk.BOTTOM)
        input_frame.pack_propagate(False)
        self.input_text = tk.Text(input_frame, font=("Helvetica", 12), bg=THEME["input_bg"],
                                   fg=THEME["fg"], insertbackground=THEME["fg"], bd=0,
                                   padx=15, pady=12, height=2, wrap=tk.WORD, relief=tk.FLAT)
        self.input_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(15, 5))
        self.send_btn = tk.Button(input_frame, text="▶", font=("Helvetica", 16, "bold"),
                                   bg=THEME["accent"], fg="#1a1b26", bd=0, cursor="hand2",
                                   command=self.send_message, width=3, relief=tk.FLAT)
        self.send_btn.pack(side=tk.RIGHT, padx=(5, 15), pady=12)
        self.input_text.bind("<Return>", self._on_enter)
        self.input_text.bind("<Shift-Return>", lambda e: self.input_text.insert(tk.INSERT, "\n") or "break")
        self.root.bind("<Control-l>", lambda e: self.input_text.focus_set())

    def _on_enter(self, event):
        if not event.state & 0x1:
            self.send_message()
            return "break"

    def _add_message(self, role, text):
        frame = tk.Frame(self.chat_messages, bg=THEME["bg"])
        frame.pack(fill=tk.X, padx=20, pady=(8, 2))
        label_text = "You" if role == "user" else "promptLi"
        bubble_bg = THEME["user_bubble"] if role == "user" else THEME["ai_bubble"]
        anchor = "e" if role == "user" else "w"
        tk.Label(frame, text=label_text, font=("Helvetica", 9, "bold"),
                 fg=THEME["accent"] if role == "assistant" else THEME["fg"],
                 bg=THEME["bg"], anchor=anchor).pack(fill=tk.X, padx=5)
        bubble = tk.Frame(frame, bg=bubble_bg)
        bubble.pack(anchor=anchor, padx=5, pady=(2, 0))
        tk.Label(bubble, text=text, font=("Helvetica", 11),
                 fg="#ffffff" if role == "user" else THEME["fg"],
                 bg=bubble_bg, justify=tk.LEFT, wraplength=550, padx=15, pady=10).pack()
        for cmd in extract_commands(text):
            if role == "assistant":
                tk.Button(frame, text=f"▶ Run: {cmd[:60]}{'...' if len(cmd) > 60 else ''}",
                          font=("Helvetica", 9), bg=THEME["input_bg"], fg=THEME["success"],
                          bd=0, cursor="hand2", relief=tk.FLAT,
                          command=lambda c=cmd: self.execute_command(c)).pack(anchor="w", pady=1)
        self.root.after(100, lambda: self.chat_canvas.yview_moveto(1.0))

    def send_message(self):
        if self.streaming: return
        text = self.input_text.get("1.0", "end-1c").strip()
        if not text: return
        if not self.anthropic_client:
            messagebox.showerror("No API Key", "Please set your Anthropic API key in Settings first.")
            return
        self._add_message("user", text)
        self.input_text.delete("1.0", tk.END)
        self.conversation.append({"role": "user", "content": text})
        self.streaming = True
        self.status_label.config(text="● Thinking...", fg=THEME["warning"])
        self.send_btn.config(state=tk.DISABLED)
        threading.Thread(target=self._call_claude, daemon=True).start()

    def _call_claude(self):
        try:
            model = self.config.get("model", DEFAULT_CONFIG["model"])
            max_tokens = self.config.get("max_tokens", DEFAULT_CONFIG["max_tokens"])
            system_prompt = self.config.get("system_prompt", DEFAULT_CONFIG["system_prompt"])
            messages = [{"role": m["role"], "content": m["content"]} for m in self.conversation[-20:]]
            response = self.anthropic_client.messages.create(
                model=model, max_tokens=max_tokens, system=system_prompt, messages=messages)
            reply = response.content[0].text
            self.conversation.append({"role": "assistant", "content": reply})
            self.root.after(0, lambda: self._add_message("assistant", reply))
            self.root.after(0, self._save_history)
        except Exception as e:
            self.root.after(0, lambda: self._add_message("assistant", f"Error: {e}"))
        finally:
            self.root.after(0, self._reset_status)

    def _reset_status(self):
        self.streaming = False
        self.status_label.config(text="● Ready", fg=THEME["success"])
        self.send_btn.config(state=tk.NORMAL)

    def execute_command(self, command):
        dangerous = is_dangerous(command)
        if dangerous:
            msg = f"⚠️ DANGEROUS COMMAND ⚠️\n\n{command}\n\nThis could damage your system. Continue?"
            if not messagebox.askyesno("⚠️ Dangerous", msg, icon="warning"):
                log_command(command, False, error="User declined dangerous command"); return
        else:
            if not messagebox.askyesno("Confirm", f"Execute?\n\n{command}"):
                log_command(command, False, error="User declined"); return
        try:
            result = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=120)
            output, error = result.stdout.strip(), result.stderr.strip()
            log_command(command, True, output, error)
            if result.returncode == 0:
                txt = f"✅ Done:\n```\n{output[:1500]}\n```" if output else "✅ Done (no output)."
            else:
                txt = f"❌ Failed:\n```\n{(error or output)[:1500]}\n```"
            self._add_message("assistant", txt)
        except subprocess.TimeoutExpired:
            log_command(command, True, error="Timeout")
            self._add_message("assistant", "⏱ Timed out (120s).")
        except Exception as e:
            log_command(command, True, error=str(e))
            self._add_message("assistant", f"❌ {e}")

    def open_settings(self):
        win = tk.Toplevel(self.root)
        win.title("Settings"); win.geometry("550x400")
        win.configure(bg=THEME["bg"]); win.transient(self.root); win.grab_set()
        tk.Label(win, text="⚡ Settings", font=("Helvetica", 16, "bold"),
                 fg=THEME["accent"], bg=THEME["bg"]).pack(pady=(20, 15))
        tk.Label(win, text="Anthropic API Key:", fg=THEME["fg"], bg=THEME["bg"],
                 font=("Helvetica", 11), anchor="w").pack(fill=tk.X, padx=30)
        key = tk.Entry(win, font=("Helvetica", 11), bg=THEME["input_bg"], fg=THEME["fg"],
                       insertbackground=THEME["fg"], show="•", relief=tk.FLAT)
        key.pack(fill=tk.X, padx=30, pady=(5, 10), ipady=6)
        key.insert(0, self.config.get("api_key", ""))
        tk.Label(win, text="Model:", fg=THEME["fg"], bg=THEME["bg"],
                 font=("Helvetica", 11), anchor="w").pack(fill=tk.X, padx=30)
        model_var = tk.StringVar(value=self.config.get("model", DEFAULT_CONFIG["model"]))
        ttk.Combobox(win, textvariable=model_var, state="readonly", font=("Helvetica", 11),
                     values=["claude-sonnet-4-20250514", "claude-3-5-sonnet-20241022",
                             "claude-3-opus-20240229", "claude-3-5-haiku-20241022"]
                     ).pack(fill=tk.X, padx=30, pady=(5, 10), ipady=4)
        def save():
            self.config["api_key"] = key.get().strip()
            self.config["model"] = model_var.get()
            save_config(self.config)
            self._init_anthropic()
            win.destroy()
        tk.Button(win, text="Save", command=save, font=("Helvetica", 12, "bold"),
                  bg=THEME["accent"], fg="#1a1b26", bd=0, cursor="hand2",
                  relief=tk.FLAT, padx=30, pady=8).pack(pady=10)

    def show_log(self):
        win = tk.Toplevel(self.root)
        win.title("Command Log"); win.geometry("700x500")
        win.configure(bg=THEME["bg"]); win.transient(self.root)
        tk.Label(win, text="📋 Command Log", font=("Helvetica", 14, "bold"),
                 fg=THEME["accent"], bg=THEME["bg"]).pack(pady=(15, 10))
        t = scrolledtext.ScrolledText(win, font=("Courier", 10), bg=THEME["input_bg"],
                                       fg=THEME["fg"], relief=tk.FLAT, padx=10, pady=10)
        t.pack(fill=tk.BOTH, expand=True, padx=15, pady=(0, 15))
        if LOG_FILE.exists():
            with open(LOG_FILE) as f:
                for entry in reversed(json.load(f)):
                    t.insert(tk.END, f"[{entry['timestamp']}] {'✅' if entry['approved'] else '❌'} {entry['command']}\n")
        else:
            t.insert(tk.END, "No commands executed yet.")
        t.config(state=tk.DISABLED)

    def new_chat(self):
        if self.conversation and not messagebox.askyesno("New Chat", "Start fresh?"): return
        self.conversation = []
        for w in self.chat_messages.winfo_children(): w.destroy()
        self._save_history()
        self._add_message("assistant", "Welcome to promptLi OS! ⚡\n\nI am your Claude-powered assistant with system access.\nAsk me anything — I will suggest commands for you to approve.")

    def _load_history(self):
        if HISTORY_FILE.exists():
            with open(HISTORY_FILE) as f:
                try:
                    self.conversation = json.load(f)
                    for m in self.conversation:
                        self._add_message(m["role"], m["content"])
                    return
                except: pass
        self._add_message("assistant", "Welcome to promptLi OS! ⚡\n\nI am your Claude-powered assistant with system access.\nAsk me anything — I will suggest commands for you to approve.")

    def _save_history(self):
        with open(HISTORY_FILE, "w") as f:
            json.dump(self.conversation, f, indent=2)


if __name__ == "__main__":
    tk.Tk()
    app = AssistantApp(tk._default_root or tk.Tk())
    tk.mainloop()
PYEOF
chmod +x "$PROJECT_DIR/assistant/promptli_assistant.py"

# --- promptLi Daemon ---
cat > "$PROJECT_DIR/assistant/promptli_daemon.py" << 'PYEOF'
#!/usr/bin/env python3
"""promptLi Daemon — elevated command execution via Unix socket."""
import json, os, subprocess, threading, socket
from pathlib import Path

SOCKET_PATH = "/tmp/promptli-daemon.sock"
DANGER = ["rm -rf /", "mkfs.", "dd if=", "> /dev/sd", "chmod 777 /"]

def execute(cmd, timeout=120):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return {"success": r.returncode == 0, "returncode": r.returncode,
                "stdout": r.stdout.strip()[-5000:], "stderr": r.stderr.strip()[-5000:]}
    except subprocess.TimeoutExpired:
        return {"success": False, "error": "Timeout"}
    except Exception as e:
        return {"success": False, "error": str(e)}

def handle(conn):
    try:
        data = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk: break
            data += chunk
            if b"\n" in data: break
        req = json.loads(data.decode().strip())
        cmd = req.get("command", "")
        if any(k in cmd.lower() for k in DANGER) and not req.get("force"):
            resp = {"success": False, "error": "DANGEROUS_COMMAND"}
        else:
            resp = execute(cmd)
            resp["command"] = cmd
        conn.sendall(json.dumps(resp).encode() + b"\n")
    except Exception as e:
        conn.sendall(json.dumps({"success": False, "error": str(e)}).encode() + b"\n")
    finally:
        conn.close()

if __name__ == "__main__":
    if os.path.exists(SOCKET_PATH): os.unlink(SOCKET_PATH)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o660)
    server.listen(5)
    try:
        while True:
            conn, _ = server.accept()
            threading.Thread(target=handle, args=(conn,), daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        server.close()
        if os.path.exists(SOCKET_PATH): os.unlink(SOCKET_PATH)
PYEOF

# --- Desktop entries ---
cat > "$PROJECT_DIR/assistant/promptli.desktop" << 'EOF'
[Desktop Entry]
Name=promptLi Assistant
Comment=AI-powered system assistant
Exec=python3 /opt/promptli/promptli_assistant.py
Icon=/opt/promptli/assets/promptli.png
Type=Application
Categories=System;Utility;
Terminal=false
Keywords=ai;assistant;claude;system;
EOF

cat > "$PROJECT_DIR/tools/locakhost.desktop" << 'EOF'
[Desktop Entry]
Name=LocakHost
Comment=Easy local web hosting for testing
Exec=python3 /opt/promptli/tools/locakhost.py
Type=Application
Categories=Development;Network;
Terminal=false
EOF

cat > "$PROJECT_DIR/assistant/requirements.txt" << 'EOF'
anthropic>=0.39.0
openai>=1.0.0
EOF

# --- locakHost ---
cat > "$PROJECT_DIR/tools/locakhost.py" << 'PYEOF'
#!/usr/bin/env python3
# locakHost by c4mandry — local web server for testing
import http.server, os, socketserver, subprocess, sys, threading, webbrowser, tkinter as tk
from tkinter import filedialog, messagebox
DEFAULT_PORT = 8080

class SPARequestHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        p = self.translate_path(self.path)
        if not os.path.exists(p) and "." not in os.path.basename(self.path):
            self.path = "/index.html"
        return super().do_GET()

class Server:
    def __init__(self): self.httpd = self.thread = self.proc = None
    def start(self, folder, port, spa=True):
        if self.running: raise RuntimeError("Already running")
        pkg = os.path.join(folder, "package.json")
        if os.path.exists(pkg):
            self.proc = subprocess.Popen(["npx", "vite", "--port", str(port), "--host"], cwd=folder, shell=sys.platform.startswith("win"))
        else:
            h = SPARequestHandler if spa else http.server.SimpleHTTPRequestHandler
            socketserver.TCPServer.allow_reuse_address = True
            self.httpd = socketserver.TCPServer(("0.0.0.0", port), lambda *a, **k: h(*a, directory=folder, **k))
            self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
            self.thread.start()
    def stop(self):
        if self.proc: self.proc.terminate(); self.proc = None
        if self.httpd: self.httpd.shutdown(); self.httpd.server_close(); self.httpd = self.thread = None
    @property
    def running(self): return self.httpd is not None or (self.proc and self.proc.poll() is None)

class App:
    def __init__(self, root):
        self.root = root; self.server = Server()
        self.fv = tk.StringVar(); self.pv = tk.StringVar(value=str(DEFAULT_PORT))
        self.sv = tk.StringVar(value="Not running")
        root.title("LocakHost"); root.resizable(False, False)
        p = {"padx": 10, "pady": 6}
        tk.Label(root, text="Folder:").grid(row=0, column=0, sticky="w", **p)
        tk.Entry(root, textvariable=self.fv, width=40).grid(row=0, column=1, **p)
        tk.Button(root, text="Browse...", command=lambda: (d := filedialog.askdirectory()) and self.fv.set(d)).grid(row=0, column=2, **p)
        tk.Label(root, text="Port:").grid(row=1, column=0, sticky="w", **p)
        tk.Entry(root, textvariable=self.pv, width=10).grid(row=1, column=1, sticky="w", **p)
        self.hb = tk.Button(root, text="Host", width=12, command=self.toggle); self.hb.grid(row=2, column=1, sticky="w", **p)
        self.ob = tk.Button(root, text="Open in Browser", command=lambda: webbrowser.open(f"http://localhost:{self.pv.get().strip() or DEFAULT_PORT}"), state="disabled")
        self.ob.grid(row=2, column=2, sticky="w", **p)
        tk.Label(root, textvariable=self.sv, fg="gray").grid(row=3, column=0, columnspan=3, sticky="w", **p)
        root.protocol("WM_DELETE_WINDOW", self.on_close)
    def toggle(self):
        if self.server.running: self.server.stop(); self.hb.config(text="Host"); self.ob.config(state="disabled"); self.sv.set("Not running"); return
        f = self.fv.get().strip()
        if not f: messagebox.showerror("Error", "Choose a folder."); return
        try: port = int(self.pv.get().strip() or DEFAULT_PORT)
        except: messagebox.showerror("Error", "Port must be a number."); return
        try: self.server.start(f, port)
        except Exception as e: messagebox.showerror("Error", str(e)); return
        self.hb.config(text="Stop"); self.ob.config(state="normal")
        self.sv.set(f"Hosting at http://localhost:{port}")
    def on_close(self): self.server.stop(); self.root.destroy()

if __name__ == "__main__":
    root = tk.Tk(); App(root); root.mainloop()
PYEOF

# ── Copy files into the live-build includes tree ────────
echo "[*] Copying files into chroot..."

INCLUDES="$BUILD_DIR/config/includes.chroot"
rm -rf "$INCLUDES"
mkdir -p "$INCLUDES"

# /opt/promptli
mkdir -p "$INCLUDES/opt/promptli"/{assets,tools}
cp "$PROJECT_DIR/assistant/promptli_assistant.py" "$INCLUDES/opt/promptli/"
cp "$PROJECT_DIR/assistant/promptli_daemon.py" "$INCLUDES/opt/promptli/"
cp "$PROJECT_DIR/assistant/requirements.txt" "$INCLUDES/opt/promptli/"
cp "$PROJECT_DIR/tools/locakhost.py" "$INCLUDES/opt/promptli/tools/"

# Desktop entries
mkdir -p "$INCLUDES/usr/share/applications"
cp "$PROJECT_DIR/assistant/promptli.desktop" "$INCLUDES/usr/share/applications/"
cp "$PROJECT_DIR/tools/locakhost.desktop" "$INCLUDES/usr/share/applications/"

# CLI wrappers: type 'promptli' or 'locakhost' in terminal
mkdir -p "$INCLUDES/usr/local/bin"
cat > "$INCLUDES/usr/local/bin/promptli" << 'X'; chmod +x "$INCLUDES/usr/local/bin/promptli"
#!/bin/sh
exec python3 /opt/promptli/promptli_assistant.py "$@"
X
cat > "$INCLUDES/usr/local/bin/locakhost" << 'X'; chmod +x "$INCLUDES/usr/local/bin/locakhost"
#!/bin/sh
exec python3 /opt/promptli/tools/locakhost.py "$@"
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
cat > "$INCLUDES/etc/os-release" << 'X'
PRETTY_NAME="promptLi OS 1.0.0 (L1-433)"
NAME="promptLi OS"
VERSION_ID="1.0.0"
VERSION="1.0.0 (L1-433)"
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
cat > "$INCLUDES/etc/motd" << 'X'

  ⚡ promptLi OS 1.0.0 (L1-433) — minimal server-focused Debian

  Assistant:  aido            AI:           aido chat
  AUR:        mist install X  Shell:        zsh
  Installer:  promptli-install      Update:  promptli-update --check
  Web server: locakhost       Docs:        https://webnotes.work/os

X
cat > "$INCLUDES/etc/issue" << 'X'
\S{PRETTY_NAME} \n \l

X

# ── fastfetch: custom promptLi logo + identity ───────────
mkdir -p "$INCLUDES/etc/fastfetch" "$INCLUDES/etc/skel/.config/fastfetch"
cat > "$INCLUDES/etc/fastfetch/config.jsonc" << 'X'
// promptLi OS fastfetch config — custom lightning-bolt logo + clean output.
// Named ANSI colors only: the fastfetch in Debian 13 (2.40) predates hex RGB.
{
    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
    "logo": {
        "type": "data",
        "source": "$1        ▄▄▄\n$1       █████\n$2      ███████\n$2     █████████\n$3    ███████████\n$4   █████████████\n$5  ███████████████\n$5  ▀██████████████\n$4   ▀████████████\n$3    ▀██████████\n$2     ▀████████\n$2      ▀██████\n$1       ▀████\n$1        ▀██",
        "color": {
            "1": "bright_magenta",
            "2": "bright_blue",
            "3": "bright_cyan",
            "4": "light_blue",
            "5": "light_cyan"
        },
        "padding": { "left": 2 }
    },
    "display": {
        "separator": " ➜ "
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

# ── Prompt (bold, git-aware, safe for 8/16-color ttys) ───
autoload -Uz vcs_info
precmd() { vcs_info }
zstyle ':vcs_info:git:*' formats '(%b)'
zstyle ':vcs_info:*' enable git
setopt PROMPT_SUBST
PROMPT='%B%F{magenta}⚡%f%b %B%F{cyan}%~%f%b %F{yellow}${vcs_info_msg_0_}%f%(!.%F{red}%n@%m.%F{green}❯)%f '

# ── Aliases (modern tools) ───────────────────────────────
alias ls='eza --icons=never --color=auto --group-directories-first'
alias ll='eza -lh --icons=never --color=auto --group-directories-first'
alias la='eza -lah --icons=never --color=auto --group-directories-first'
alias cat='batcat --paging=never --style=plain 2>/dev/null || cat'
alias grep='grep --color=auto'
alias tree='eza --tree --icons=never'
alias mkdir='mkdir -pv'
alias df='df -h'
alias free='free -h'
alias pacman='pacman --color auto'

# ── Keybindings ──────────────────────────────────────────
bindkey '^[[A' up-line-or-search
bindkey '^[[B' down-line-or-search
bindkey '^R' history-incremental-search-backward

# ── Plugin setup (Debian packages) ───────────────────────
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh 2>/dev/null
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh 2>/dev/null
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'

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

# ── Autostart config system ──────────────────────────────
mkdir -p "$INCLUDES/etc/promptli/autostart.d" "$INCLUDES/etc/skel/.config/promptli/autostart.d"
cat > "$INCLUDES/etc/promptli/autostart.d/10-welcome.sh" << 'X'
# promptLi autostart example — runs in zsh login shells.
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
    useradd -m -s /usr/bin/zsh -G sudo netdev promptli
    echo "promptli:promptli" | chpasswd
    cp -r /etc/skel/. /home/promptli/
    chown -R promptli:promptli /home/promptli
fi
chsh -s /usr/bin/zsh root 2>/dev/null || true
# promptLi assistant (Claude API) deps — aido's own light deps (PyYAML,
# requests) come from Debian packages, so no pip install is needed for it.
pip3 install --break-system-packages anthropic 2>/dev/null || true
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
    echo "  [✓] AUR ready: mist install <package>"
else
    echo "  [!] mist not available yet (makedeb repo offline) — run: aido \"install mist from AUR\" later, or check https://docs.makedeb.org"
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

# Hostname
echo "promptli" > "$INCLUDES/etc/hostname"

# ── Hooks ───────────────────────────────────────────────
mkdir -p config/hooks/normal
cat > config/hooks/normal/9999-promptli-customize.hook.chroot << 'HOOK'
#!/bin/bash
echo "⚡ Customizing promptLi OS..."

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

# ── Fast boot tweaks ────────────────────────────────────
echo "  [*] Applying boot-speed tweaks..."
# systemctl needs dbus, which doesn't exist inside a build chroot — masking
# is just a symlink to /dev/null, so do that directly.
for unit in systemd-networkd-wait-online.service \
            NetworkManager-wait-online.service \
            ModemManager.service \
            apt-daily.timer apt-daily-upgrade.timer \
            man-db.timer fstrim.timer; do
    ln -sf /dev/null "/etc/systemd/system/$unit"
done
# Raise systemd's default timeout (older/slow disks) and keep quiet boot.
mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\nDefaultTimeoutStartSec=45s\nDefaultTimeoutStopSec=20s\n' > /etc/systemd/system.conf.d/promptli.conf

# ── Default user: created at build time (not first boot) ──
echo "  [*] Creating default user 'promptli'..."
if ! id promptli >/dev/null 2>&1; then
    useradd -m -s /usr/bin/zsh -G sudo,netdev promptli
    echo 'promptli:promptli' | chpasswd
    cp -r /etc/skel/. /home/promptli/ 2>/dev/null || true
    chown -R promptli:promptli /home/promptli
fi
chsh -s /usr/bin/zsh root 2>/dev/null || true

# ── Permissions ─────────────────────────────────────────
echo "  [*] Fixing permissions..."
chown -R root:root /opt/promptli /opt/aido
chmod +x /usr/local/bin/promptli /usr/local/bin/locakhost /usr/local/bin/aido
chmod +x /opt/promptli/promptli_assistant.py /opt/promptli/promptli_daemon.py /opt/promptli/setup.sh
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
  "version": "1.0.0",
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
    "AUR support via mist (makedeb) + pacman",
    "zsh with autosuggestions, syntax highlighting, and a git-aware prompt",
    "Custom fastfetch identity with promptLi OS logo",
    "Rust TUI installer (promptli-install) + self-updater (promptli-update)",
    "Fast boot with quiet, minimal services",
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

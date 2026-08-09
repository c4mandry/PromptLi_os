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
echo "  2. Build a custom Debian live ISO with:"
echo "     - i3 window manager (Tokyo Night theme)"
echo "     - promptLi AI Assistant (Claude API + system control)"
echo "     - locakHost web server (terminal: just type 'locakhost')"
echo "     - Zen Browser (installed on first boot)"
echo "  3. Output: promptli-os-1.0.0-amd64.iso"
echo ""

ISO_NAME="promptli-os-1.0.0-amd64"
BUILD_DIR="/tmp/promptli-build"
OUTPUT_DIR="$HOME/promptli-os-output"

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
    --bootappend-live "boot=live components quiet splash" \
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
# Base
xorg xinit x11-xserver-utils xterm

# i3 Window Manager
i3-wm i3status i3lock dmenu suckless-tools

# Display & Compositing
picom feh xcompmgr

# Fonts
fonts-jetbrains-mono fonts-font-awesome fonts-noto fonts-noto-cjk

# Networking
network-manager network-manager-gnome wireless-tools wpasupplicant

# Audio
pulseaudio pavucontrol alsa-utils

# Utilities
curl wget git vim htop unzip p7zip-full
scrot xclip brightnessctl arandr lxappearance

# Python (for promptLi Assistant)
python3 python3-pip python3-tk python3-pil python3-pil.imagetk

# Terminal
alacritty

# File Manager
thunar gvfs gvfs-backends

# Login Manager
lightdm lightdm-gtk-greeter

# System
sudo polkitd pkexec
libasound2 libdbus-glib-1-2 libgtk-3-0 libfuse2 fuse
rsync
PACKAGES

# ── Create project files ─────────────────────────────────
echo "[*] Creating promptLi project files..."

PROJECT_DIR="$BUILD_DIR/promptli-project"
mkdir -p "$PROJECT_DIR"/{assistant/assets,config/i3,config/autostart,tools}

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

# --- i3 config ---
cat > "$PROJECT_DIR/config/i3/config" << 'EOF'
set $mod Mod4
font pango:JetBrains Mono 10
gaps inner 8; gaps outer 4

set $bg #1a1b26; set $fg #c0caf5; set $accent #bb9af7
set $red #f7768e; set $green #9ece6a; set $inactive #3b4261

client.focused $accent $bg $fg $accent $accent
client.unfocused $bg $bg $fg $bg $bg
client.urgent $red $red $fg $red $red

bindsym $mod+Return exec alacritty
bindsym $mod+space exec promptli
bindsym $mod+d exec "dmenu_run -fn 'JetBrains Mono-10' -nb '$bg' -nf '$fg' -sb '$accent' -sf '$bg'"
bindsym $mod+Shift+q kill
bindsym $mod+h focus left; bindsym $mod+j focus down
bindsym $mod+k focus up; bindsym $mod+l focus right
bindsym $mod+Shift+h move left; bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up; bindsym $mod+Shift+l move right
bindsym $mod+v split vertical; bindsym $mod+b split horizontal
bindsym $mod+f fullscreen toggle
bindsym $mod+Shift+space floating toggle

bindsym $mod+r mode "resize"
mode "resize" {
    bindsym h resize shrink width 10 px or 10 ppt
    bindsym j resize grow height 10 px or 10 ppt
    bindsym k resize shrink height 10 px or 10 ppt
    bindsym l resize grow width 10 px or 10 ppt
    bindsym Return mode "default"; bindsym Escape mode "default"
}

set $ws1 "1"; set $ws2 "2"; set $ws3 "3"; set $ws4 "4"; set $ws5 "5"
bindsym $mod+1 workspace $ws1; bindsym $mod+2 workspace $ws2
bindsym $mod+3 workspace $ws3; bindsym $mod+4 workspace $ws4
bindsym $mod+5 workspace $ws5
bindsym $mod+Shift+1 move container to workspace $ws1
bindsym $mod+Shift+2 move container to workspace $ws2
bindsym $mod+Shift+3 move container to workspace $ws3
bindsym $mod+Shift+4 move container to workspace $ws4
bindsym $mod+Shift+5 move container to workspace $ws5

bindsym $mod+Shift+c reload; bindsym $mod+Shift+r restart
bindsym $mod+Shift+e exec "i3-nagbar -t warning -m 'Exit i3?' -b 'Yes' 'i3-msg exit'"
bindsym XF86AudioRaiseVolume exec pactl set-sink-volume @DEFAULT_SINK@ +5%
bindsym XF86AudioLowerVolume exec pactl set-sink-volume @DEFAULT_SINK@ -5%
bindsym XF86AudioMute exec pactl set-sink-mute @DEFAULT_SINK@ toggle
bindsym Print exec "scrot '%Y-%m-%d_%H%M%S.png' -e 'mv $f ~/Pictures/'"

bar {
    position top; status_command i3status
    colors {
        background $bg; statusline $fg; separator $inactive
        focused_workspace $accent $accent $bg
        active_workspace $inactive $inactive $fg
        inactive_workspace $bg $bg $fg
        urgent_workspace $red $red $fg
    }
    font pango:JetBrains Mono 10
}

exec --no-startup-id feh --bg-fill /opt/promptli/assets/wallpaper.svg
exec --no-startup-id picom -b
exec --no-startup-id ~/.config/autostart.sh
for_window [class="promptli"] floating enable, resize set 900 650
for_window [class="LocakHost"] floating enable
EOF

# --- i3status config ---
cat > "$PROJECT_DIR/config/i3/i3status.conf" << 'EOF'
general { colors = true; color_good = "#9ece6a"; color_bad = "#f7768e"; color_degraded = "#e0af68"; interval = 5 }
order += "disk /"
order += "wireless _first_"
order += "ethernet _first_"
order += "battery all"
order += "load"
order += "memory"
order += "tztime local"
wireless _first_ { format_up = "W: %quality %essid"; format_down = "W: down" }
ethernet _first_ { format_up = "E: %ip"; format_down = "E: down" }
battery all { format = "%status %percentage %remaining" }
disk "/" { format = "💾 %avail" }
load { format = "⚡ %1min" }
memory { format = "🧠 %used/%total" }
tztime local { format = "📅 %Y-%m-%d %H:%M" }
EOF

# --- Autostart ---
cat > "$PROJECT_DIR/config/autostart/autostart.sh" << 'EOF'
#!/bin/sh
picom -b &
feh --bg-fill /opt/promptli/assets/wallpaper.svg &
nm-applet &
promptli &
EOF
chmod +x "$PROJECT_DIR/config/autostart/autostart.sh"

# --- Wallpaper SVG ---
cat > "$PROJECT_DIR/assistant/assets/wallpaper.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1920 1080">
  <defs>
    <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:#1a1b26"/>
      <stop offset="100%" style="stop-color:#16161e"/>
    </linearGradient>
    <linearGradient id="accent" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:#bb9af7"/>
      <stop offset="100%" style="stop-color:#7aa2f7"/>
    </linearGradient>
  </defs>
  <rect width="1920" height="1080" fill="url(#bg)"/>
  <g opacity="0.03" stroke="#c0caf5" stroke-width="0.5">
    <line x1="0" y1="0" x2="1920" y2="0"/><line x1="0" y1="60" x2="1920" y2="60"/>
    <line x1="0" y1="120" x2="1920" y2="120"/><line x1="0" y1="180" x2="1920" y2="180"/>
    <line x1="0" y1="240" x2="1920" y2="240"/><line x1="0" y1="300" x2="1920" y2="300"/>
    <line x1="0" y1="360" x2="1920" y2="360"/><line x1="0" y1="420" x2="1920" y2="420"/>
    <line x1="0" y1="480" x2="1920" y2="480"/><line x1="0" y1="540" x2="1920" y2="540"/>
    <line x1="0" y1="600" x2="1920" y2="600"/><line x1="0" y1="660" x2="1920" y2="660"/>
    <line x1="0" y1="720" x2="1920" y2="720"/><line x1="0" y1="780" x2="1920" y2="780"/>
    <line x1="0" y1="840" x2="1920" y2="840"/><line x1="0" y1="900" x2="1920" y2="900"/>
    <line x1="0" y1="960" x2="1920" y2="960"/><line x1="0" y1="1020" x2="1920" y2="1020"/>
  </g>
  <g transform="translate(960, 440)">
    <circle cx="0" cy="0" r="130" fill="none" stroke="url(#accent)" stroke-width="2" opacity="0.1"/>
    <circle cx="0" cy="0" r="110" fill="none" stroke="url(#accent)" stroke-width="1" opacity="0.15"/>
    <circle cx="0" cy="0" r="90" fill="none" stroke="url(#accent)" stroke-width="1" opacity="0.2"/>
    <polygon points="-18,-70 12,-12 0,-12 30,70 -12,12 0,12" fill="url(#accent)" opacity="0.9"/>
  </g>
  <text x="960" y="640" text-anchor="middle" font-family="monospace" font-size="48" font-weight="bold" fill="#bb9af7" opacity="0.9">promptLi OS</text>
  <text x="960" y="680" text-anchor="middle" font-family="monospace" font-size="16" fill="#565f89" opacity="0.7">AI-powered system assistant • Debian 13</text>
</svg>
EOF

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
cp "$PROJECT_DIR/assistant/assets/wallpaper.svg" "$INCLUDES/opt/promptli/assets/"
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

# i3 config
mkdir -p "$INCLUDES/etc/skel/.config/i3" "$INCLUDES/etc/skel/.config/i3status"
cp "$PROJECT_DIR/config/i3/config" "$INCLUDES/etc/skel/.config/i3/config"
cp "$PROJECT_DIR/config/i3/i3status.conf" "$INCLUDES/etc/skel/.config/i3status/config"

# Autostart
cp "$PROJECT_DIR/config/autostart/autostart.sh" "$INCLUDES/etc/skel/.config/autostart.sh"
chmod +x "$INCLUDES/etc/skel/.config/autostart.sh"

# picom config
mkdir -p "$INCLUDES/etc/skel/.config/picom"
cat > "$INCLUDES/etc/skel/.config/picom/picom.conf" << 'X'
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
X

# LightDM autologin
mkdir -p "$INCLUDES/etc/lightdm"
cat > "$INCLUDES/etc/lightdm/lightdm.conf" << 'X'
[Seat:*]
autologin-user=promptli
autologin-user-timeout=0
user-session=i3
greeter-session=lightdm-gtk-greeter
X

# First-boot setup service
cat > "$INCLUDES/opt/promptli/setup.sh" << 'X'; chmod +x "$INCLUDES/opt/promptli/setup.sh"
#!/bin/sh
if ! id promptli >/dev/null 2>&1; then
    useradd -m -s /bin/sh -G sudo,audio,video,netdev promptli
    echo "promptli:promptli" | chpasswd
    cp -r /etc/skel/. /home/promptli/
    chown -R promptli:promptli /home/promptli
fi
pip3 install --break-system-packages anthropic openai 2>/dev/null || true
# Zen Browser
if [ ! -f /opt/zen-browser/zen ]; then
    echo "Installing Zen Browser..."
    mkdir -p /opt/zen-browser
    wget -q "https://github.com/zen-browser/desktop/releases/latest/download/zen.linux-x86_64.tar.xz" -O /tmp/zen.tar.xz
    tar -xf /tmp/zen.tar.xz -C /opt/zen-browser/ --strip-components=1
    rm /tmp/zen.tar.xz
    ln -sf /opt/zen-browser/zen /usr/local/bin/zen-browser
    update-alternatives --install /usr/bin/x-www-browser x-www-browser /opt/zen-browser/zen 100
    update-alternatives --set x-www-browser /opt/zen-browser/zen
fi
cat > /usr/share/applications/zen-browser.desktop << "ZEN"
[Desktop Entry]
Name=Zen Browser
Exec=/opt/zen-browser/zen %u
Icon=/opt/zen-browser/browser/chrome/icons/default/default128.png
Type=Application
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
Terminal=false
ZEN
systemctl disable promptli-setup.service 2>/dev/null || true
X

# Systemd service
mkdir -p "$INCLUDES/etc/systemd/system/multi-user.target.wants"
cat > "$INCLUDES/etc/systemd/system/promptli-setup.service" << 'X'
[Unit]
Description=promptLi first boot setup
After=network.target network-online.target
Wants=network-online.target
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

# Enable LightDM
mkdir -p "$INCLUDES/etc/systemd/system"
ln -sf /lib/systemd/system/lightdm.service "$INCLUDES/etc/systemd/system/display-manager.service" 2>/dev/null || true

# ── Hooks ───────────────────────────────────────────────
mkdir -p config/hooks/normal
cat > config/hooks/normal/9999-promptli-customize.hook.chroot << 'HOOK'
#!/bin/bash
echo "⚡ Customizing promptLi OS..."
chown -R root:root /opt/promptli
chmod +x /usr/local/bin/promptli /usr/local/bin/locakhost
chmod +x /opt/promptli/promptli_assistant.py /opt/promptli/promptli_daemon.py /opt/promptli/setup.sh
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
if [ -f live-image-amd64.hybrid.iso ]; then
    cp live-image-amd64.hybrid.iso "$OUTPUT_DIR/$ISO_NAME.iso"
elif [ -f *.iso ]; then
    cp *.iso "$OUTPUT_DIR/$ISO_NAME.iso"
fi

echo ""
echo "================================================"
echo "  ✅ promptLi OS built successfully!"
echo "  📀 $OUTPUT_DIR/$ISO_NAME.iso"
echo "  📏 $(du -h "$OUTPUT_DIR/$ISO_NAME.iso" | cut -f1)"
echo "================================================"

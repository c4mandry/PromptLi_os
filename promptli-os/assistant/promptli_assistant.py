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

# --- Config paths ---
CONFIG_DIR = Path.home() / ".config" / "promptli"
CONFIG_FILE = CONFIG_DIR / "config.json"
LOG_FILE = CONFIG_DIR / "command_log.json"
HISTORY_FILE = CONFIG_DIR / "chat_history.json"
DAEMON_SOCKET = Path("/tmp/promptli-daemon.sock")

# --- Default config ---
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
    "dangerous_patterns": [
        r"rm\s+-rf\s+/",
        r"dd\s+if=",
        r"mkfs\.",
        r":\(\)\s*\{\s*:\|:&\s*\};:",
        r">\s*/dev/sda",
        r"chmod\s+777\s+/",
        r"sudo\s+rm\s+-rf\s+/",
    ],
}

# --- Safety ---
DANGEROUS_KEYWORDS = [
    "rm -rf /", "mkfs.", "dd if=", "format", "fdisk",
    "> /dev/sd", "chmod 777 /", ":(){ :|:& };:",
]


def load_config():
    """Load or create config."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    if CONFIG_FILE.exists():
        with open(CONFIG_FILE) as f:
            cfg = json.load(f)
            # Merge with defaults for any missing keys
            for k, v in DEFAULT_CONFIG.items():
                cfg.setdefault(k, v)
            return cfg
    return dict(DEFAULT_CONFIG)


def save_config(cfg):
    """Save config to disk."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2)


def log_command(command, approved, output="", error=""):
    """Log executed commands."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    log_entry = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "command": command,
        "approved": approved,
        "output": output[:2000],
        "error": error[:2000],
    }
    logs = []
    if LOG_FILE.exists():
        with open(LOG_FILE) as f:
            try:
                logs = json.load(f)
            except json.JSONDecodeError:
                logs = []
    logs.append(log_entry)
    with open(LOG_FILE, "w") as f:
        json.dump(logs[-500:], f, indent=2)  # Keep last 500 entries


def is_dangerous(command):
    """Check if a command looks dangerous."""
    cmd_lower = command.lower().strip()
    for kw in DANGEROUS_KEYWORDS:
        if kw.lower() in cmd_lower:
            return True
    return False


def extract_commands(text):
    """Extract bash code blocks from AI response."""
    pattern = r"```bash\n?(.*?)```"
    matches = re.findall(pattern, text, re.DOTALL)
    return [m.strip() for m in matches if m.strip()]


# --- Colors / Theme ---
THEME = {
    "bg": "#1a1b26",           # Tokyo Night dark
    "fg": "#c0caf5",
    "user_bubble": "#7aa2f7",
    "ai_bubble": "#3b4261",
    "accent": "#bb9af7",
    "danger": "#f7768e",
    "success": "#9ece6a",
    "warning": "#e0af68",
    "input_bg": "#24283b",
    "sidebar_bg": "#16161e",
    "border": "#3b4261",
}


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

    # ── API setup ──────────────────────────────────────────

    def _init_anthropic(self):
        api_key = self.config.get("api_key", "")
        if api_key:
            try:
                import anthropic
                self.anthropic_client = anthropic.Anthropic(api_key=api_key)
            except ImportError:
                self.anthropic_client = None
            except Exception:
                self.anthropic_client = None

    # ── UI ─────────────────────────────────────────────────

    def _build_ui(self):
        # Main paned window: sidebar | chat area
        self.paned = tk.PanedWindow(
            self.root, bg=THEME["border"], sashwidth=2, orient=tk.HORIZONTAL
        )
        self.paned.pack(fill=tk.BOTH, expand=True)

        # --- Sidebar ---
        self.sidebar = tk.Frame(self.paned, bg=THEME["sidebar_bg"], width=220)
        self.paned.add(self.sidebar, minsize=180)

        # Logo / title
        tk.Label(
            self.sidebar,
            text="⚡ promptLi",
            font=("Helvetica", 18, "bold"),
            fg=THEME["accent"],
            bg=THEME["sidebar_bg"],
        ).pack(pady=(20, 5))

        tk.Label(
            self.sidebar,
            text="Claude-powered\nsystem assistant",
            font=("Helvetica", 10),
            fg=THEME["fg"],
            bg=THEME["sidebar_bg"],
            justify=tk.CENTER,
        ).pack(pady=(0, 20))

        # Separator
        ttk.Separator(self.sidebar, orient=tk.HORIZONTAL).pack(fill=tk.X, padx=15)

        # Buttons
        btn_style = {
            "font": ("Helvetica", 11),
            "bg": THEME["input_bg"],
            "fg": THEME["fg"],
            "activebackground": THEME["accent"],
            "activeforeground": "#000",
            "bd": 0,
            "cursor": "hand2",
            "relief": tk.FLAT,
            "highlightthickness": 0,
        }

        tk.Button(
            self.sidebar, text="＋ New Chat", command=self.new_chat, **btn_style
        ).pack(fill=tk.X, padx=15, pady=(20, 5), ipady=8)

        tk.Button(
            self.sidebar, text="⚙ Settings", command=self.open_settings, **btn_style
        ).pack(fill=tk.X, padx=15, pady=5, ipady=8)

        tk.Button(
            self.sidebar, text="📋 Command Log", command=self.show_log, **btn_style
        ).pack(fill=tk.X, padx=15, pady=5, ipady=8)

        # Status indicator
        self.status_label = tk.Label(
            self.sidebar,
            text="● Ready",
            font=("Helvetica", 10),
            fg=THEME["success"],
            bg=THEME["sidebar_bg"],
        )
        self.status_label.pack(side=tk.BOTTOM, pady=15)

        # --- Chat Area ---
        self.chat_frame = tk.Frame(self.paned, bg=THEME["bg"])
        self.paned.add(self.chat_frame, minsize=400)

        # Chat display (canvas + scrollbar for smooth scrolling)
        self.chat_canvas = tk.Canvas(
            self.chat_frame,
            bg=THEME["bg"],
            highlightthickness=0,
            bd=0,
        )
        self.chat_scrollbar = tk.Scrollbar(
            self.chat_frame, orient=tk.VERTICAL, command=self.chat_canvas.yview
        )
        self.chat_messages = tk.Frame(self.chat_canvas, bg=THEME["bg"])

        self.chat_messages.bind("<Configure>", self._on_frame_configure)
        self.chat_window = self.chat_canvas.create_window(
            (0, 0), window=self.chat_messages, anchor="nw", tags="messages"
        )

        self.chat_canvas.configure(yscrollcommand=self.chat_scrollbar.set)
        self.chat_canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.chat_scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        # Make canvas resize with window
        self.chat_canvas.bind("<Configure>", self._on_canvas_configure)
        self.chat_canvas.bind_all("<MouseWheel>", self._on_mousewheel)

        # --- Input Area ---
        self.input_frame = tk.Frame(self.root, bg=THEME["input_bg"], height=60)
        self.input_frame.pack(fill=tk.X, side=tk.BOTTOM)
        self.input_frame.pack_propagate(False)

        self.input_text = tk.Text(
            self.input_frame,
            font=("Helvetica", 12),
            bg=THEME["input_bg"],
            fg=THEME["fg"],
            insertbackground=THEME["fg"],
            bd=0,
            padx=15,
            pady=12,
            height=2,
            wrap=tk.WORD,
            relief=tk.FLAT,
        )
        self.input_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(15, 5))

        self.send_btn = tk.Button(
            self.input_frame,
            text="▶",
            font=("Helvetica", 16, "bold"),
            bg=THEME["accent"],
            fg="#1a1b26",
            bd=0,
            cursor="hand2",
            command=self.send_message,
            width=3,
            relief=tk.FLAT,
            activebackground=THEME["accent"],
        )
        self.send_btn.pack(side=tk.RIGHT, padx=(5, 15), pady=12)

        # Bind Enter to send (Shift+Enter for newline)
        self.input_text.bind("<Return>", self._on_enter)
        self.input_text.bind("<Shift-Return>", self._on_shift_enter)

        # Shortcut: Ctrl+L to clear / focus input
        self.root.bind("<Control-l>", lambda e: self.input_text.focus_set())

    def _on_frame_configure(self, event=None):
        self.chat_canvas.configure(scrollregion=self.chat_canvas.bbox("all"))

    def _on_canvas_configure(self, event):
        self.chat_canvas.itemconfig(self.chat_window, width=event.width)

    def _on_mousewheel(self, event):
        self.chat_canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")

    # ── Chat display ───────────────────────────────────────

    def _add_message(self, role, text):
        """Add a message bubble to the chat."""
        frame = tk.Frame(self.chat_messages, bg=THEME["bg"])
        frame.pack(fill=tk.X, padx=20, pady=(8, 2))

        if role == "user":
            label_text = "You"
            bubble_bg = THEME["user_bubble"]
            anchor = "e"
        else:
            label_text = "promptLi"
            bubble_bg = THEME["ai_bubble"]
            anchor = "w"

        # Role label
        tk.Label(
            frame,
            text=label_text,
            font=("Helvetica", 9, "bold"),
            fg=THEME["accent"] if role == "assistant" else THEME["fg"],
            bg=THEME["bg"],
            anchor=anchor,
        ).pack(fill=tk.X, padx=5)

        # Message bubble
        bubble = tk.Frame(frame, bg=bubble_bg)
        bubble.pack(anchor=anchor, padx=5, pady=(2, 0))

        msg_label = tk.Label(
            bubble,
            text=text,
            font=("Helvetica", 11),
            fg="#ffffff" if role == "user" else THEME["fg"],
            bg=bubble_bg,
            justify=tk.LEFT,
            wraplength=550,
            padx=15,
            pady=10,
        )
        msg_label.pack()

        # Command buttons for assistant messages
        commands = extract_commands(text)
        if role == "assistant" and commands:
            btn_frame = tk.Frame(frame, bg=THEME["bg"])
            btn_frame.pack(anchor="w", padx=5, pady=(5, 0))
            for i, cmd in enumerate(commands):
                cmd_btn = tk.Button(
                    btn_frame,
                    text=f"▶ Run: {cmd[:60]}{'...' if len(cmd) > 60 else ''}",
                    font=("Helvetica", 9),
                    bg=THEME["input_bg"],
                    fg=THEME["success"],
                    bd=0,
                    cursor="hand2",
                    relief=tk.FLAT,
                    command=lambda c=cmd: self.execute_command(c),
                )
                cmd_btn.pack(anchor="w", pady=1)

        # Scroll to bottom
        self.root.after(100, self._scroll_bottom)

    def _scroll_bottom(self):
        self.chat_canvas.yview_moveto(1.0)

    # ── Chat logic ─────────────────────────────────────────

    def _on_enter(self, event):
        """Enter sends message (unless shift is held)."""
        if not event.state & 0x1:  # Shift not held
            self.send_message()
            return "break"
        return None

    def _on_shift_enter(self, event):
        """Shift+Enter inserts newline."""
        self.input_text.insert(tk.INSERT, "\n")
        return "break"

    def send_message(self):
        """Send user message to Claude."""
        if self.streaming:
            return

        text = self.input_text.get("1.0", "end-1c").strip()
        if not text:
            return

        if not self.anthropic_client:
            messagebox.showerror(
                "No API Key",
                "Please set your Anthropic API key in Settings first.",
            )
            return

        # Display user message
        self._add_message("user", text)
        self.input_text.delete("1.0", tk.END)
        self.conversation.append({"role": "user", "content": text})

        # Set status
        self.streaming = True
        self.status_label.config(text="● Thinking...", fg=THEME["warning"])
        self.send_btn.config(state=tk.DISABLED)

        # Call Claude in background thread
        thread = threading.Thread(target=self._call_claude, daemon=True)
        thread.start()

    def _call_claude(self):
        """Call Claude API and display response."""
        try:
            system_prompt = self.config.get("system_prompt", DEFAULT_CONFIG["system_prompt"])
            model = self.config.get("model", DEFAULT_CONFIG["model"])
            max_tokens = self.config.get("max_tokens", DEFAULT_CONFIG["max_tokens"])

            # Build messages
            messages = []
            for msg in self.conversation[-20:]:  # Last 20 messages for context
                messages.append({"role": msg["role"], "content": msg["content"]})

            response = self.anthropic_client.messages.create(
                model=model,
                max_tokens=max_tokens,
                system=system_prompt,
                messages=messages,
            )

            reply = response.content[0].text
            self.conversation.append({"role": "assistant", "content": reply})

            # Update UI on main thread
            self.root.after(0, self._display_assistant_reply, reply)
            self.root.after(0, self._save_history)

        except Exception as e:
            error_msg = f"Error: {str(e)}"
            self.root.after(0, self._display_assistant_reply, error_msg)
        finally:
            self.root.after(0, self._reset_status)

    def _display_assistant_reply(self, text):
        self._add_message("assistant", text)

    def _reset_status(self):
        self.streaming = False
        self.status_label.config(text="● Ready", fg=THEME["success"])
        self.send_btn.config(state=tk.NORMAL)

    # ── Command execution ──────────────────────────────────

    def execute_command(self, command):
        """Confirm and execute a system command."""
        # Danger check
        dangerous = is_dangerous(command)

        if dangerous:
            msg = (
                f"⚠️ DANGEROUS COMMAND DETECTED ⚠️\n\n"
                f"{command}\n\n"
                f"This command could damage your system.\n"
                f"Are you absolutely sure?"
            )
            confirm = messagebox.askyesno(
                "⚠️ Dangerous Command", msg, icon="warning"
            )
            if not confirm:
                log_command(command, approved=False, error="User declined dangerous command")
                return
        else:
            msg = f"Execute this command?\n\n{command}"
            confirm = messagebox.askyesno("Confirm Command", msg)
            if not confirm:
                log_command(command, approved=False, error="User declined")
                return

        # Execute
        try:
            result = subprocess.run(
                command,
                shell=True,
                capture_output=True,
                text=True,
                timeout=120,
                cwd=str(Path.home()),
            )
            output = result.stdout.strip()
            error = result.stderr.strip()

            log_command(command, approved=True, output=output, error=error)

            # Show result
            if result.returncode == 0 and output:
                self._add_message("assistant", f"✅ Command succeeded:\n```\n{output[:1500]}\n```")
            elif result.returncode == 0:
                self._add_message("assistant", "✅ Command executed successfully (no output).")
            else:
                err = error or f"Exit code: {result.returncode}"
                self._add_message("assistant", f"❌ Command failed:\n```\n{err[:1500]}\n```")

        except subprocess.TimeoutExpired:
            log_command(command, approved=True, error="Timeout")
            self._add_message("assistant", "⏱ Command timed out (120s limit).")
        except Exception as e:
            log_command(command, approved=True, error=str(e))
            self._add_message("assistant", f"❌ Error: {str(e)}")

    # ── Settings ────────────────────────────────────────────

    def open_settings(self):
        settings_win = tk.Toplevel(self.root)
        settings_win.title("promptLi Settings")
        settings_win.geometry("550x450")
        settings_win.configure(bg=THEME["bg"])
        settings_win.transient(self.root)
        settings_win.grab_set()

        cfg = dict(self.config)

        # Header
        tk.Label(
            settings_win,
            text="⚡ promptLi Settings",
            font=("Helvetica", 16, "bold"),
            fg=THEME["accent"],
            bg=THEME["bg"],
        ).pack(pady=(20, 15))

        # API Key
        tk.Label(settings_win, text="Anthropic API Key:", fg=THEME["fg"], bg=THEME["bg"],
                 font=("Helvetica", 11), anchor="w").pack(fill=tk.X, padx=30)
        api_entry = tk.Entry(
            settings_win,
            font=("Helvetica", 11),
            bg=THEME["input_bg"],
            fg=THEME["fg"],
            insertbackground=THEME["fg"],
            show="•",
            relief=tk.FLAT,
        )
        api_entry.pack(fill=tk.X, padx=30, pady=(5, 15), ipady=6)
        api_entry.insert(0, cfg.get("api_key", ""))

        # Model
        tk.Label(settings_win, text="Model:", fg=THEME["fg"], bg=THEME["bg"],
                 font=("Helvetica", 11), anchor="w").pack(fill=tk.X, padx=30)
        model_var = tk.StringVar(value=cfg.get("model", DEFAULT_CONFIG["model"]))
        model_combo = ttk.Combobox(
            settings_win,
            textvariable=model_var,
            values=[
                "claude-sonnet-4-20250514",
                "claude-3-5-sonnet-20241022",
                "claude-3-opus-20240229",
                "claude-3-5-haiku-20241022",
            ],
            state="readonly",
            font=("Helvetica", 11),
        )
        model_combo.pack(fill=tk.X, padx=30, pady=(5, 15), ipady=4)

        # Max tokens
        tk.Label(settings_win, text="Max Tokens:", fg=THEME["fg"], bg=THEME["bg"],
                 font=("Helvetica", 11), anchor="w").pack(fill=tk.X, padx=30)
        tokens_var = tk.StringVar(value=str(cfg.get("max_tokens", 4096)))
        tk.Entry(
            settings_win,
            textvariable=tokens_var,
            font=("Helvetica", 11),
            bg=THEME["input_bg"],
            fg=THEME["fg"],
            insertbackground=THEME["fg"],
            relief=tk.FLAT,
        ).pack(fill=tk.X, padx=30, pady=(5, 15), ipady=6)

        # System prompt
        tk.Label(settings_win, text="System Prompt:", fg=THEME["fg"], bg=THEME["bg"],
                 font=("Helvetica", 11), anchor="w").pack(fill=tk.X, padx=30)
        prompt_text = tk.Text(
            settings_win,
            font=("Helvetica", 10),
            bg=THEME["input_bg"],
            fg=THEME["fg"],
            insertbackground=THEME["fg"],
            height=6,
            wrap=tk.WORD,
            relief=tk.FLAT,
            padx=10,
            pady=8,
        )
        prompt_text.pack(fill=tk.X, padx=30, pady=(5, 15))
        prompt_text.insert("1.0", cfg.get("system_prompt", ""))

        def save():
            cfg["api_key"] = api_entry.get().strip()
            cfg["model"] = model_var.get()
            try:
                cfg["max_tokens"] = int(tokens_var.get())
            except ValueError:
                cfg["max_tokens"] = 4096
            cfg["system_prompt"] = prompt_text.get("1.0", "end-1c").strip()
            save_config(cfg)
            self.config = cfg
            self._init_anthropic()
            settings_win.destroy()
            messagebox.showinfo("Saved", "Settings saved successfully.")

        tk.Button(
            settings_win,
            text="Save",
            command=save,
            font=("Helvetica", 12, "bold"),
            bg=THEME["accent"],
            fg="#1a1b26",
            bd=0,
            cursor="hand2",
            relief=tk.FLAT,
            padx=30,
            pady=8,
        ).pack(pady=(5, 20))

    # ── Command log viewer ─────────────────────────────────

    def show_log(self):
        """Show command execution history."""
        log_win = tk.Toplevel(self.root)
        log_win.title("Command Log")
        log_win.geometry("700x500")
        log_win.configure(bg=THEME["bg"])
        log_win.transient(self.root)

        tk.Label(
            log_win,
            text="📋 Command Execution Log",
            font=("Helvetica", 14, "bold"),
            fg=THEME["accent"],
            bg=THEME["bg"],
        ).pack(pady=(15, 10))

        log_text = scrolledtext.ScrolledText(
            log_win,
            font=("Courier", 10),
            bg=THEME["input_bg"],
            fg=THEME["fg"],
            insertbackground=THEME["fg"],
            relief=tk.FLAT,
            padx=10,
            pady=10,
        )
        log_text.pack(fill=tk.BOTH, expand=True, padx=15, pady=(0, 15))

        if LOG_FILE.exists():
            with open(LOG_FILE) as f:
                logs = json.load(f)
                for entry in reversed(logs):
                    status = "✅" if entry["approved"] else "❌"
                    log_text.insert(
                        tk.END,
                        f"[{entry['timestamp']}] {status} {entry['command']}\n",
                    )
                    if entry.get("output"):
                        log_text.insert(tk.END, f"  Output: {entry['output'][:200]}\n")
                    if entry.get("error"):
                        log_text.insert(tk.END, f"  Error: {entry['error'][:200]}\n")
                    log_text.insert(tk.END, "\n")
        else:
            log_text.insert(tk.END, "No commands executed yet.")

        log_text.config(state=tk.DISABLED)

    # ── Chat management ────────────────────────────────────

    def new_chat(self):
        """Start a new conversation."""
        if self.conversation:
            if not messagebox.askyesno("New Chat", "Start a new conversation?"):
                return
        self.conversation = []
        for widget in self.chat_messages.winfo_children():
            widget.destroy()
        self._save_history()

        # Welcome message
        self._add_message(
            "assistant",
            "Welcome to **promptLi OS**! ⚡\n\n"
            "I'm your Claude-powered system assistant. I can help you:\n"
            "• Run shell commands\n"
            "• Manage files and packages\n"
            "• Configure your system\n"
            "• Debug issues\n\n"
            "Just ask me anything — I'll suggest commands and you approve them. "
            "What would you like to do?",
        )

    def _load_history(self):
        """Load previous chat history."""
        if HISTORY_FILE.exists():
            with open(HISTORY_FILE) as f:
                try:
                    history = json.load(f)
                    self.conversation = history
                    for msg in history:
                        self._add_message(msg["role"], msg["content"])
                    return
                except (json.JSONDecodeError, KeyError):
                    pass

        # Show welcome if no history
        self._add_message(
            "assistant",
            "Welcome to **promptLi OS**! ⚡\n\n"
            "I'm your Claude-powered system assistant. I can help you:\n"
            "• Run shell commands\n"
            "• Manage files and packages\n"
            "• Configure your system\n"
            "• Debug issues\n\n"
            "Just ask me anything — I'll suggest commands and you approve them. "
            "What would you like to do?",
        )

    def _save_history(self):
        """Save conversation to disk."""
        with open(HISTORY_FILE, "w") as f:
            json.dump(self.conversation, f, indent=2)


def main():
    root = tk.Tk()

    # Set icon if available
    icon_path = Path(__file__).parent / "assets" / "promptli.png"
    if icon_path.exists():
        try:
            img = tk.PhotoImage(file=str(icon_path))
            root.iconphoto(True, img)
        except Exception:
            pass

    app = AssistantApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()

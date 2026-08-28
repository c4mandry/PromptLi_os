#!/usr/bin/env python3
"""
PromptLix server — local AI assistant backend + web UI host.

Design:
  - Binds 127.0.0.1 only, on a hidden port (18437 by default).
  - Every /api/* endpoint requires the bearer token stored in
    ~/.config/promptlix/server_token (0600). The desktop webview reads
    that file and passes the token, so other local processes cannot use
    the assistant without it.
  - Serves the macOS-style web UI from /opt/promptlix/web/.
  - Executes shell commands with a danger check and audit logging.
  - Injects a live desktop reference (windows.jsonc) into the AI context
    so the model knows which windows are open, where they are, and how
    big they are.
  - The system prompt is LOCKED: /opt/promptlix/system_prompt.txt
    (shipped read-only, not editable from the UI).
  - Any model works: Anthropic, OpenAI, DeepSeek, Gemini, plus a custom
    OpenAI-compatible endpoint (Ollama, LM Studio, OpenRouter, ...).
"""

import json
import os
import secrets
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

APP_DIR = Path("/opt/promptlix")
WEB_DIR = APP_DIR / "web"
SYSTEM_PROMPT_FILE = APP_DIR / "system_prompt.txt"
CONFIG_DIR = Path.home() / ".config" / "promptlix"
CONFIG_FILE = CONFIG_DIR / "server_config.json"
TOKEN_FILE = CONFIG_DIR / "server_token"
LOG_FILE = CONFIG_DIR / "command_log.json"
WINDOWS_FILE = CONFIG_DIR / "windows.jsonc"

HOST = "127.0.0.1"
PORT = int(os.environ.get("PROMPTLIX_PORT", "18437"))

PROVIDERS = {
    "anthropic": {
        "name": "Anthropic (Claude)",
        "base_url": None,
        "models": [
            "claude-sonnet-4-20250514",
            "claude-3-5-sonnet",
            "claude-3-5-haiku",
            "claude-3-opus",
        ],
    },
    "openai": {
        "name": "OpenAI",
        "base_url": "https://api.openai.com/v1",
        "models": ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "o3-mini", "o1"],
    },
    "deepseek": {
        "name": "DeepSeek",
        "base_url": "https://api.deepseek.com",
        "models": ["deepseek-chat", "deepseek-reasoner"],
    },
    "gemini": {
        "name": "Google Gemini",
        "base_url": "https://generativelanguage.googleapis.com/v1beta/openai/",
        "models": ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash", "gemini-1.5-pro"],
    },
    "custom": {
        "name": "Custom (OpenAI-compatible)",
        "base_url": "http://localhost:11434/v1",
        "models": [],
    },
}

DEFAULT_CONFIG = {
    "provider": "anthropic",
    "api_key": "",
    "base_url": "",
    "model": "claude-sonnet-4-20250514",
}

DANGEROUS_KEYWORDS = [
    "rm -rf /", "rm -rf /*", "mkfs.", "dd if=", "> /dev/sd",
    "chmod 777 /", ":(){ :|:& };:", "rm -rf --no-preserve-root",
    "fdisk", "parted", "shutdown", "reboot", "systemctl poweroff",
    "format c:", "diskutil erase",
]

HISTORY_LIMIT = 40


# ── Token & config ─────────────────────────────────────────────

def ensure_token():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_DIR.chmod(0o700)
    if not TOKEN_FILE.exists():
        TOKEN_FILE.write_text(secrets.token_hex(32), encoding="utf-8")
        TOKEN_FILE.chmod(0o600)
    return TOKEN_FILE.read_text(encoding="utf-8").strip()


def load_config():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_DIR.chmod(0o700)
    if CONFIG_FILE.exists():
        try:
            cfg = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
            for k, v in DEFAULT_CONFIG.items():
                cfg.setdefault(k, v)
            return cfg
        except Exception:
            pass
    return dict(DEFAULT_CONFIG)


def save_config(cfg):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_DIR.chmod(0o700)
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    CONFIG_FILE.chmod(0o600)


def log_command(command, approved, returncode=None, output="", error=""):
    entry = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "command": command,
        "approved": approved,
        "returncode": returncode,
        "output": (output or "")[-2000:],
        "error": (error or "")[-2000:],
    }
    logs = []
    if LOG_FILE.exists():
        try:
            logs = json.loads(LOG_FILE.read_text(encoding="utf-8"))
        except Exception:
            logs = []
    logs.append(entry)
    LOG_FILE.write_text(json.dumps(logs[-500:], indent=2), encoding="utf-8")
    LOG_FILE.chmod(0o600)


def is_dangerous(command):
    cmd = command.lower().strip()
    return any(k.lower() in cmd for k in DANGEROUS_KEYWORDS)


# ── System prompt (locked) + desktop reference ─────────────────

def locked_system_prompt():
    if SYSTEM_PROMPT_FILE.exists():
        return SYSTEM_PROMPT_FILE.read_text(encoding="utf-8").strip()
    return "You are PromptLix, an AI assistant with system-level access."


def read_windows():
    try:
        return WINDOWS_FILE.read_text(encoding="utf-8")
    except Exception:
        return ""


def build_system_prompt():
    base = locked_system_prompt()
    windows = read_windows()
    if windows:
        base += (
            "\n\n## Desktop state (windows.jsonc)\n"
            "The following is the live state of the user's desktop, refreshed "
            "every 2 seconds. Use it when the user asks about open windows, "
            "window positions, sizes, or fullscreen state. Coordinates are in "
            "pixels from the top-left of the screen.\n\n"
            + windows
        )
    return base


# ── Model backends ────────────────────────────────────────────

def clean_messages(messages):
    """Keep only user/assistant turns; first message must be from the user."""
    out = []
    for m in messages:
        role = m.get("role")
        content = (m.get("content") or "").strip()
        if role in ("user", "assistant") and content:
            out.append({"role": role, "content": content})
    while out and out[0]["role"] != "user":
        out.pop(0)
    return out[-HISTORY_LIMIT:]


def stream_anthropic(api_key, model, sys_prompt, messages, emit):
    import anthropic
    client = anthropic.Anthropic(api_key=api_key)
    with client.messages.stream(
        model=model,
        max_tokens=4096,
        system=sys_prompt,
        messages=messages,
    ) as stream:
        for text in stream.text_stream:
            emit({"delta": text})


def stream_openai_compat(api_key, base_url, model, sys_prompt, messages, emit):
    from openai import OpenAI
    kwargs = {"api_key": api_key}
    if base_url:
        kwargs["base_url"] = base_url
    client = OpenAI(**kwargs)
    payload = [{"role": "system", "content": sys_prompt}] + messages
    resp = client.chat.completions.create(model=model, messages=payload, stream=True)
    for chunk in resp:
        if chunk.choices:
            delta = chunk.choices[0].delta
            content = getattr(delta, "content", None)
            if content:
                emit({"delta": content})


# ── HTTP handler ──────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "PromptLix/1.0"

    def log_message(self, format, *args):
        pass  # keep the terminal quiet

    # -- plumbing --

    def send_json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            return {}

    def authorized(self):
        token = self.headers.get("X-Promptlix-Token", "")
        return bool(token) and token == ensure_token()

    # -- static web UI --

    def serve_static(self, path):
        rel = urllib.parse.unquote(path)
        if rel == "/":
            rel = "/index.html"
        target = (WEB_DIR / rel.lstrip("/")).resolve()
        if not str(target).startswith(str(WEB_DIR.resolve())) or not target.is_file():
            self.send_json(404, {"error": "not found"})
            return
        body = target.read_bytes()
        ctype = "text/html" if target.suffix == ".html" else (
            "text/css" if target.suffix == ".css" else (
                "application/javascript" if target.suffix == ".js" else
                "application/octet-stream"))
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # -- routes --

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path.startswith("/api/"):
            if not self.authorized():
                self.send_json(401, {"error": "unauthorized"})
                return
            if parsed.path == "/api/health":
                self.send_json(200, {"ok": True})
            elif parsed.path == "/api/config":
                out = dict(load_config())
                out["providers"] = PROVIDERS
                self.send_json(200, out)
            elif parsed.path == "/api/windows":
                self.send_json(200, {"windows": read_windows()})
            elif parsed.path == "/api/log":
                try:
                    self.send_json(200, json.loads(LOG_FILE.read_text(encoding="utf-8")))
                except Exception:
                    self.send_json(200, [])
            elif parsed.path == "/api/system-prompt":
                self.send_json(200, {"system_prompt": locked_system_prompt(), "locked": True})
            else:
                self.send_json(404, {"error": "not found"})
            return
        self.serve_static(parsed.path)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if not parsed.path.startswith("/api/"):
            self.send_json(404, {"error": "not found"})
            return
        if not self.authorized():
            self.send_json(401, {"error": "unauthorized"})
            return

        if parsed.path == "/api/config":
            payload = self.read_body()
            cfg = load_config()
            for k in ("provider", "api_key", "base_url", "model"):
                if k in payload:
                    cfg[k] = str(payload[k]).strip()
            if cfg["provider"] not in PROVIDERS:
                cfg["provider"] = "anthropic"
            save_config(cfg)
            out = dict(cfg)
            out["providers"] = PROVIDERS
            self.send_json(200, out)

        elif parsed.path == "/api/run":
            payload = self.read_body()
            command = (payload.get("command") or "").strip()
            force = bool(payload.get("force"))
            if not command:
                self.send_json(200, {"ok": False, "error": "empty command"})
                return
            if is_dangerous(command) and not force:
                log_command(command, False, error="blocked: dangerous")
                self.send_json(200, {
                    "ok": False,
                    "blocked": True,
                    "error": "Blocked: this command is potentially dangerous. Re-run with force to override.",
                })
                return
            try:
                r = subprocess.run(
                    command, shell=True, capture_output=True, text=True, timeout=120
                )
                log_command(command, True, r.returncode, r.stdout, r.stderr)
                self.send_json(200, {
                    "ok": r.returncode == 0,
                    "returncode": r.returncode,
                    "stdout": r.stdout[-4000:],
                    "stderr": r.stderr[-4000:],
                })
            except subprocess.TimeoutExpired:
                log_command(command, True, error="timed out (120s)")
                self.send_json(200, {"ok": False, "error": "Command timed out (120s limit)."})
            except Exception as e:
                self.send_json(200, {"ok": False, "error": str(e)})

        elif parsed.path == "/api/chat":
            self.handle_chat()

        else:
            self.send_json(404, {"error": "not found"})

    # -- chat with SSE streaming --

    def handle_chat(self):
        payload = self.read_body()
        cfg = load_config()
        provider = payload.get("provider") or cfg["provider"]
        if provider not in PROVIDERS:
            provider = "anthropic"
        model = payload.get("model") or cfg["model"]
        api_key = payload.get("api_key") or cfg["api_key"]
        base_url = payload.get("base_url") or cfg["base_url"]
        messages = clean_messages(payload.get("messages") or [])

        if not api_key and provider != "custom":
            self.send_json(200, {"error": "No API key set. Open Settings."})
            return
        if not messages:
            self.send_json(200, {"error": "Empty message."})
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        def emit(obj):
            try:
                self.wfile.write(("data: " + json.dumps(obj) + "\n\n").encode("utf-8"))
                self.wfile.flush()
            except Exception:
                pass

        sys_prompt = build_system_prompt()
        info = PROVIDERS[provider]
        if not model:
            model = (info["models"] or [""])[0] if info["models"] else ""

        try:
            if provider == "anthropic":
                stream_anthropic(api_key, model, sys_prompt, messages, emit)
            else:
                stream_openai_compat(api_key, base_url or info["base_url"], model, sys_prompt, messages, emit)
        except Exception as e:
            emit({"error": f"{type(e).__name__}: {e}"})
        finally:
            emit({"done": True})


# ── Windows loop + main ───────────────────────────────────────

def start_windows_loop():
    try:
        import promptlix_windowd as windowd
    except Exception:
        try:
            sys.path.insert(0, str(APP_DIR))
            import promptlix_windowd as windowd
        except Exception:
            return
    t = threading.Thread(target=windowd.run_loop, daemon=True)
    t.start()


def main():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_DIR.chmod(0o700)
    token = ensure_token()
    print(f"PromptLix server: http://{HOST}:{PORT}  (token {token[:8]}... in {TOKEN_FILE})")
    start_windows_loop()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

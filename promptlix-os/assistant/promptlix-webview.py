#!/usr/bin/env python3
"""
PromptLix webview — the desktop app shell.

It ensures the local PromptLix server is running, then opens the
assistant web UI in a GTK WebKit2 window. The web UI is the app;
this file is just the native frame around it.

The server token is read from ~/.config/promptlix/server_token and
passed in the URL (never on the command line), so it does not appear
in process listings.
"""

import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gtk, WebKit2

APP_DIR = Path("/opt/promptlix")
SERVER_SCRIPT = APP_DIR / "promptlix-server.py"
CONFIG_DIR = Path.home() / ".config" / "promptlix"
TOKEN_FILE = CONFIG_DIR / "server_token"
HOST = "127.0.0.1"
PORT = int(os.environ.get("PROMPTLIX_PORT", "18437"))


def read_token():
    try:
        return TOKEN_FILE.read_text(encoding="utf-8").strip()
    except Exception:
        return ""


def server_up(token):
    url = f"http://{HOST}:{PORT}/api/health"
    req = urllib.request.Request(url, headers={"X-Promptlix-Token": token})
    try:
        with urllib.request.urlopen(req, timeout=1) as resp:
            return resp.status == 200
    except Exception:
        return False


def ensure_server():
    token = read_token()
    if token and server_up(token):
        return token
    # Server not running: start it detached, then wait for it.
    subprocess.Popen(
        [sys.executable, str(SERVER_SCRIPT)],
        start_new_session=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for _ in range(30):
        time.sleep(0.5)
        token = read_token()
        if token and server_up(token):
            return token
    return token


def main():
    token = ensure_server()
    if not token:
        print("error: could not start the PromptLix server", file=sys.stderr)
        sys.exit(1)

    window = Gtk.Window(title="PromptLix")
    window.set_default_size(1280, 800)
    window.set_position(Gtk.WindowPosition.CENTER)
    window.connect("destroy", Gtk.main_quit)

    webview = WebKit2.WebView()
    webview.load_uri(f"http://{HOST}:{PORT}/?token={token}")
    window.add(webview)
    window.show_all()
    Gtk.main()


if __name__ == "__main__":
    main()

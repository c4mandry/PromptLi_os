#!/usr/bin/env python3
# locakHost — easy local web hosting for testing
# Originally by c4mandry (github.com/c4mandry/locakHost)
# Included in PromptLix OS

import http.server
import os
import socketserver
import subprocess
import sys
import threading
import webbrowser
import tkinter as tk
from tkinter import filedialog, messagebox

DEFAULT_PORT = 8080


class SPARequestHandler(http.server.SimpleHTTPRequestHandler):
    """Fallback handler for pre-built static SPAs."""

    def do_GET(self):
        requested_path = self.translate_path(self.path)
        if not os.path.exists(requested_path) and "." not in os.path.basename(
            self.path
        ):
            self.path = "/index.html"
        return super().do_GET()


class Server:
    def __init__(self):
        self.httpd = None
        self.thread = None
        self.proc = None

    def start(self, folder: str, port: int, spa_mode: bool = True):
        if self.running:
            raise RuntimeError("Server already running")

        package_json = os.path.join(folder, "package.json")

        # 1. AUTO-VITE MODE: If package.json exists, launch npx vite automatically
        if os.path.exists(package_json):
            cmd = ["npx", "vite", "--port", str(port), "--host"]
            use_shell = sys.platform.startswith("win")
            try:
                self.proc = subprocess.Popen(cmd, cwd=folder, shell=use_shell)
            except Exception as e:
                raise OSError(f"Could not launch Vite background process:\n{e}")

        # 2. PYTHON MODE: Standard static folder hosting
        else:
            handler_cls = (
                SPARequestHandler if spa_mode else http.server.SimpleHTTPRequestHandler
            )
            handler = lambda *args, **kwargs: handler_cls(
                *args, directory=folder, **kwargs
            )

            socketserver.TCPServer.allow_reuse_address = True
            self.httpd = socketserver.TCPServer(("0.0.0.0", port), handler)
            self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
            self.thread.start()

    def stop(self):
        # Stop background Node/Vite process if active
        if self.proc is not None:
            self.proc.terminate()
            self.proc = None

        # Stop Python HTTP server if active
        if self.httpd is not None:
            self.httpd.shutdown()
            self.httpd.server_close()
            self.httpd = None
            self.thread = None

    @property
    def running(self):
        return self.httpd is not None or (
            self.proc is not None and self.proc.poll() is None
        )


class App:
    def __init__(self, root):
        self.root = root
        self.server = Server()
        self.folder_var = tk.StringVar(value="")
        self.port_var = tk.StringVar(value=str(DEFAULT_PORT))
        self.status_var = tk.StringVar(value="Not running")

        root.title("LocakHost")
        root.resizable(False, False)
        pad = {"padx": 10, "pady": 6}

        # Folder row
        tk.Label(root, text="Folder:").grid(row=0, column=0, sticky="w", **pad)
        tk.Entry(root, textvariable=self.folder_var, width=40).grid(
            row=0, column=1, **pad
        )
        tk.Button(root, text="Browse...", command=self.browse).grid(
            row=0, column=2, **pad
        )

        # Port row
        tk.Label(root, text="Port:").grid(row=1, column=0, sticky="w", **pad)
        tk.Entry(root, textvariable=self.port_var, width=10).grid(
            row=1, column=1, sticky="w", **pad
        )

        # Buttons row
        self.host_btn = tk.Button(root, text="Host", width=12, command=self.toggle_host)
        self.host_btn.grid(row=2, column=1, sticky="w", **pad)

        self.open_btn = tk.Button(
            root, text="Open in Browser", command=self.open_browser, state="disabled"
        )
        self.open_btn.grid(row=2, column=2, sticky="w", **pad)

        # Status row
        tk.Label(root, textvariable=self.status_var, fg="gray").grid(
            row=3, column=0, columnspan=3, sticky="w", **pad
        )

        root.protocol("WM_DELETE_WINDOW", self.on_close)

    def browse(self):
        folder = filedialog.askdirectory()
        if folder:
            self.folder_var.set(folder)

    def toggle_host(self):
        if self.server.running:
            self.server.stop()
            self.host_btn.config(text="Host")
            self.open_btn.config(state="disabled")
            self.status_var.set("Not running")
            return

        folder = self.folder_var.get().strip()
        if not folder:
            messagebox.showerror("Error", "Please choose a folder first.")
            return

        port_str = self.port_var.get().strip() or str(DEFAULT_PORT)
        try:
            port = int(port_str)
        except ValueError:
            messagebox.showerror("Error", "Port must be a number.")
            return

        try:
            self.server.start(folder, port)
        except Exception as e:
            messagebox.showerror("Error", f"Could not start server:\n{e}")
            return

        self.host_btn.config(text="Stop")
        self.open_btn.config(state="normal")

        if os.path.exists(os.path.join(folder, "package.json")):
            self.status_var.set(f"Running Vite project at http://localhost:{port}")
        else:
            self.status_var.set(f"Hosting {folder} at http://localhost:{port}")

    def open_browser(self):
        port = self.port_var.get().strip() or str(DEFAULT_PORT)
        webbrowser.open(f"http://localhost:{port}")

    def on_close(self):
        self.server.stop()
        self.root.destroy()


if __name__ == "__main__":
    root = tk.Tk()
    App(root)
    root.mainloop()

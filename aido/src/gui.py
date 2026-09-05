"""Tkinter chat GUI (AIDO Phase 2).

A small desktop chat window for talking to AIDO. Tkinter ships with CPython,
so no Python packages are needed — on Debian/Ubuntu install the system
binding with: sudo apt install python3-tk

Run with: aido --gui
"""

from __future__ import annotations

import queue
import threading
from typing import Any

import utils


def _require_tkinter():
    try:
        import tkinter as tk
        from tkinter import messagebox, scrolledtext

        return tk, scrolledtext, messagebox
    except ImportError:
        raise utils.AidoError(
            "Tkinter is not available. Install it with: sudo apt install python3-tk"
        ) from None


def launch_gui(agent: Any, assume_yes: bool = False, verbose: bool = False, title: str = "AIDO — AI Desktop Operator") -> None:
    """Open the chat window and run its event loop (blocks until closed)."""
    tk, scrolledtext, messagebox = _require_tkinter()

    root = tk.Tk()
    root.title(title)
    root.geometry("680x520")

    output = scrolledtext.ScrolledText(root, wrap=tk.WORD, state=tk.DISABLED, font=("monospace", 11))
    output.pack(fill=tk.BOTH, expand=True, padx=8, pady=(8, 4))

    entry = tk.Entry(root, font=("sans-serif", 13))
    entry.pack(fill=tk.X, padx=8, pady=(0, 8))
    entry.focus_set()

    outbox: queue.Queue = queue.Queue()
    busy = False

    def append(text: str) -> None:
        output.config(state=tk.NORMAL)
        output.insert(tk.END, text + "\n\n")
        output.see(tk.END)
        output.config(state=tk.DISABLED)

    def send(_event=None) -> None:
        nonlocal busy
        if busy:
            return
        text = entry.get().strip()
        if not text:
            return
        entry.delete(0, tk.END)
        busy = True
        append(f"🧑 {text}")

        def worker() -> None:
            try:
                result = agent.chat(text, interactive=False, assume_yes=assume_yes)
                outbox.put(("answer", result))
            except Exception as exc:  # noqa: BLE001 — deliberate: any agent error must not kill the GUI
                outbox.put(("error", exc))

        threading.Thread(target=worker, daemon=True).start()

    def poll() -> None:
        nonlocal busy
        try:
            kind, payload = outbox.get_nowait()
        except queue.Empty:
            root.after(100, poll)
            return
        if kind == "answer":
            if verbose:
                for call in payload["tool_calls"]:
                    append(f"  ⚙️  {call.get('tool')} {call.get('arguments')}")
            append(f"🤖 {payload['answer']}")
        else:
            append(f"⚠️  {payload}")
        busy = False
        root.after(100, poll)

    # Destructive tools ask for approval through a dialog instead of stdin.
    agent.confirm = lambda name, arguments: bool(  # type: ignore[attr-defined]
        messagebox.askyesno(
            "Confirm action",
            f"Allow '{name}' with arguments {arguments}?",
            parent=root,
        )
    )

    append("🤖 AIDO ready! Type a command below (e.g. \"Open Firefox\").")
    entry.bind("<Return>", send)
    root.protocol("WM_DELETE_WINDOW", root.destroy)
    root.after(100, poll)
    root.mainloop()

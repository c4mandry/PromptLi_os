#!/usr/bin/env python3
"""AIDO TUI — full-screen terminal chat interface (curses, stdlib only).

Runs the AIDO agent in a worker thread and renders a chat UI with streaming
replies, tool-call notifications, destructive-action confirmation, and a
first-run setup wizard that writes ~/.aido/aido.yaml — no manual config
editing needed.

Design notes
------------
* curses runs in the main thread; the agent (llama-cpp) runs in a worker
  thread and communicates through two queues: events (tokens/results) and
  confirm_results (the user's y/n answer to a risky tool call).
* The confirmation callback blocks the worker thread until the user answers,
  which keeps tool execution synchronous while the UI stays responsive.
"""

from __future__ import annotations

import curses
import queue
import sys
import textwrap
import threading
import time
from pathlib import Path
from typing import Any, Callable

import utils

USER_CONFIG_PATH = Path.home() / ".aido" / "aido.yaml"

# ── curses colors ────────────────────────────────────────────────────────

_C_HEADER = 1
_C_USER = 2
_C_AIDO = 3
_C_SYS = 4
_C_ERR = 5


def _init_colors() -> None:
    try:
        curses.start_color()
        curses.use_default_colors()
    except curses.error:
        pass  # monochrome terminal
    curses.init_pair(_C_HEADER, curses.COLOR_CYAN, -1)
    curses.init_pair(_C_USER, curses.COLOR_GREEN, -1)
    curses.init_pair(_C_AIDO, curses.COLOR_YELLOW, -1)
    curses.init_pair(_C_SYS, curses.COLOR_MAGENTA, -1)
    curses.init_pair(_C_ERR, curses.COLOR_RED, -1)


def _attr(color: int, bold: bool = False) -> int:
    attr = curses.color_pair(color)
    if bold:
        attr |= curses.A_BOLD
    return attr


# ── first-run setup wizard ───────────────────────────────────────────────


def _ask_line(stdscr, row: int, prompt: str, default: str) -> str:
    """Inline single-line input with a default. Enter = accept, Esc = default."""
    stdscr.move(row, 1)
    stdscr.clrtoeol()
    stdscr.addstr(row, 1, f"{prompt} [{default}]", _attr(_C_HEADER))
    stdscr.refresh()
    buf = ""
    while True:
        stdscr.move(row, 1 + len(prompt) + 2 + len(default) + 1 + len(buf) + 1)
        stdscr.refresh()
        try:
            ch = stdscr.get_wch()
        except curses.error:
            continue
        if isinstance(ch, str):
            if ch == "\n":
                return buf.strip() or default
            if ch == "\x1b":
                return default
            if ch in ("\x7f", "\x08"):
                buf = buf[:-1]
                stdscr.move(row, 1)
                stdscr.clrtoeol()
                stdscr.addstr(row, 1, f"{prompt} [{default}] {buf}", _attr(_C_HEADER))
            elif ch.isprintable() and len(buf) < 120:
                buf += ch
                stdscr.addstr(ch, _attr(_C_HEADER) | curses.A_BOLD)


def _wizard(stdscr, user_path: Path) -> None:
    """Ask the minimum questions and write the user config file."""
    _init_colors()
    h, w = stdscr.getmaxyx()
    stdscr.erase()
    title = " AIDO — first run setup "
    stdscr.addstr(max(0, h // 2 - 4), max(0, w // 2 - len(title) // 2), title, _attr(_C_HEADER) | curses.A_BOLD)
    row = max(0, h // 2 - 2)
    stdscr.addstr(row, 1, "One-time setup — this writes ~/.aido/aido.yaml so you", _attr(_C_SYS))
    stdscr.addstr(row + 1, 1, "never have to edit config files by hand.", _attr(_C_SYS))
    row += 3
    model = _ask_line(stdscr, row, "Local model (.gguf path)", "~/.aido/models/granite.gguf")
    row += 1
    confirm = _ask_line(stdscr, row, "Ask before risky actions? [Y/n]", "y")
    user_path.parent.mkdir(parents=True, exist_ok=True)
    import yaml

    data = {
        "model": {"path": model},
        "safety": {"confirm_destructive": confirm.strip().lower() not in ("n", "no")},
    }
    user_path.write_text(yaml.safe_dump(data, sort_keys=False))
    stdscr.move(row + 2, 1)
    stdscr.clrtoeol()
    stdscr.addstr(row + 2, 1, f"✓ Saved {user_path}", _attr(_C_AIDO))
    stdscr.refresh()
    time.sleep(0.8)


def ensure_config(explicit: str | None = None) -> dict:
    """Merged config; runs the first-run wizard when the user config is missing."""
    config = utils.load_config(explicit)
    if explicit or USER_CONFIG_PATH.is_file():
        return config
    if not (hasattr(sys, "stdin") and sys.stdin.isatty()):
        return config  # headless: rely on defaults, don't block
    curses.wrapper(_wizard, USER_CONFIG_PATH)
    return utils.load_config(explicit)


# ── the chat TUI ─────────────────────────────────────────────────────────


class ChatTui:
    def __init__(self, agent: Any, config: dict) -> None:
        self.agent = agent
        self.config = config or {}
        self.model_name = Path(str(config.get("model", {}).get("path", "?"))).name
        self.events: queue.Queue = queue.Queue()
        self.confirm_results: queue.Queue = queue.Queue()
        self.messages: list[dict[str, str]] = []
        self.input_buf = ""
        self.input_history: list[str] = []
        self.hist_idx = 0
        self.scroll = 0
        self.busy = False
        self.status = "Say hello! /help for commands"
        self.confirming: dict | None = None
        self.quit = False
        self.exit_code = 0
        self.worker: Any = None

    # -- worker-thread side ----------------------------------------------

    def _on_token(self, token: str) -> None:
        self.events.put(("token", token))

    def _on_confirm(self, name: str, arguments: dict) -> bool:
        self.events.put(("confirm", name, arguments))
        return bool(self.confirm_results.get())

    def _worker(self, text: str) -> None:
        try:
            self.agent.confirm = self._on_confirm
            result = self.agent.chat(text, interactive=True, assume_yes=False, stream_callback=self._on_token)
            self.events.put(("done", result))
        except utils.AidoError as exc:
            self.events.put(("fatal", str(exc)))
        except Exception as exc:  # keep the TUI alive on unexpected errors
            self.events.put(("fatal", f"{exc}"))

    # -- main thread -------------------------------------------------------

    def _send(self, text: str) -> None:
        text = text.strip()
        if not text:
            return
        if text.startswith("/"):
            self._command(text[1:].strip())
            return
        self.input_history.append(text)
        self.hist_idx = len(self.input_history)
        self.messages.append({"role": "user", "text": text})
        self.messages.append({"role": "aido", "text": ""})
        self.busy = True
        self.status = "thinking…"
        self.worker = threading.Thread(target=self._worker, args=(text,), daemon=True)
        self.worker.start()

    def _command(self, cmd: str) -> None:
        name = cmd.split()[0].lower()
        if name in ("help", "?"):
            self.messages.append({
                "role": "sys",
                "text": (
                    "/help  this list   /clear  forget history   /tools  list tools\n"
                    "/model  show model   /exit  quit\n"
                    "Press Ctrl+C twice or Ctrl+D to quit. Arrow keys scroll the log."
                ),
            })
        elif name == "clear":
            self.agent.reset()
            self.messages.clear()
            self.status = "history cleared"
        elif name == "tools":
            from tools import TOOL_REGISTRY

            lines = ["AIDO tools:"]
            for tool in TOOL_REGISTRY:
                flag = " (confirm)" if tool.get("dangerous") else ""
                lines.append(f"  {tool['name']} — {tool['description']}{flag}")
            self.messages.append({"role": "sys", "text": "\n".join(lines)})
        elif name == "model":
            path = self.config.get("model", {}).get("path", "?")
            self.messages.append({"role": "sys", "text": f"model: {path}"})
        elif name == "exit":
            self.quit = True
        else:
            self.messages.append({"role": "sys", "text": f"unknown command /{name} — try /help"})

    def _handle_event(self, ev: tuple) -> None:
        kind = ev[0]
        if kind == "token":
            self.messages[-1]["text"] += ev[1]
        elif kind == "done":
            result = ev[1]
            if not self.messages[-1]["text"]:
                self.messages[-1]["text"] = "(no reply)"
            for call in result.get("tool_calls", []):
                self.messages.append({
                    "role": "sys",
                    "text": f"⚙ {call.get('tool')} {call.get('arguments')}",
                })
            self.busy = False
            self.status = ""
        elif kind == "confirm":
            _, name, args = ev
            self.confirming = {"name": name, "args": args}
            self.status = ""
        elif kind == "fatal":
            self.messages.append({"role": "sys", "text": f"❌ {ev[1]}"})
            self.busy = False
            self.status = "error — see above"

    def _handle_key(self, stdscr: Any, ch: Any) -> bool:
        """Return False to quit the TUI."""
        # Confirmation mode: y/n only.
        if self.confirming is not None:
            if isinstance(ch, str):
                key = ch.lower()
                if key in ("y", "\n"):
                    self.confirm_results.put(True)
                    self.messages.append({
                        "role": "sys",
                        "text": f"⚙ {self.confirming['name']} {self.confirming['args']} — allowed",
                    })
                    self.confirming = None
                    return True
                if key in ("n", "\x1b", "q"):
                    self.confirm_results.put(False)
                    self.messages.append({
                        "role": "sys",
                        "text": f"⚙ {self.confirming['name']} — rejected",
                    })
                    self.confirming = None
                    return True
            return True

        if isinstance(ch, str):
            if ch in ("\n", "\r"):  # Enter (LF/CR both arrive depending on terminal)
                self._send(self.input_buf)
                self.input_buf = ""
                self.scroll = 0
                return True
            if ch in ("\x7f", "\x08"):  # backspace
                self.input_buf = self.input_buf[:-1]
                return True
            if ch == "\x1b":  # Esc clears the input line
                self.input_buf = ""
                return True
            if ch == "\x04":  # Ctrl+D quits
                return False
            if ch == "\x03":  # Ctrl+C
                if self.busy:
                    self.status = "Ctrl+C again to quit"
                    return True
                return False
            if ch.isprintable() and len(self.input_buf) < 500:
                self.input_buf += ch
                return True
            return True

        # Special keys (curses.KEY_*)
        if ch in (curses.KEY_ENTER, 10, 13):  # Enter as a special key
            self._send(self.input_buf)
            self.input_buf = ""
            self.scroll = 0
            return True
        if ch == curses.KEY_UP:
            if self.input_history:
                self.hist_idx = max(0, self.hist_idx - 1)
                self.input_buf = self.input_history[self.hist_idx]
            else:
                self.scroll += 1
        elif ch == curses.KEY_DOWN:
            if self.input_history and self.hist_idx < len(self.input_history):
                self.hist_idx += 1
                self.input_buf = (
                    self.input_history[self.hist_idx] if self.hist_idx < len(self.input_history) else ""
                )
            else:
                self.scroll = max(0, self.scroll - 1)
        elif ch == curses.KEY_PPAGE:
            self.scroll += 5
        elif ch == curses.KEY_NPAGE:
            self.scroll = max(0, self.scroll - 5)
        elif ch == curses.KEY_RESIZE:
            pass
        elif ch in (curses.KEY_BACKSPACE, curses.KEY_DC):
            self.input_buf = self.input_buf[:-1]
        return True

    # -- rendering ----------------------------------------------------------

    def _render_lines(self, width: int) -> list[tuple[int, str]]:
        out: list[tuple[int, str]] = []
        inner = max(10, width - 4)
        for msg in self.messages:
            role = msg["role"]
            if role == "user":
                prefix, color = "You> ", _C_USER
            elif role == "aido":
                prefix, color = "AIDO> ", _C_AIDO
            else:
                prefix, color = "  •  ", _C_SYS
            wrapped = textwrap.wrap(msg["text"], inner) or [""]
            for i, line in enumerate(wrapped):
                out.append((color, (prefix if i == 0 else "     ") + line))
        return out

    def _draw(self, stdscr: Any) -> None:
        stdscr.erase()
        h, w = stdscr.getmaxyx()
        if h < 6 or w < 20:
            stdscr.addstr(0, 0, "terminal too small")
            stdscr.refresh()
            return

        header = f" AIDO — {self.model_name} "
        busy = " ●" if self.busy else ""
        right = f"/help  Ctrl+C quit{busy}"
        stdscr.addstr(0, 0, header.ljust(w)[:w], _attr(_C_HEADER) | curses.A_BOLD)
        stdscr.addstr(0, max(0, w - len(right)), right[:w], _attr(_C_HEADER))

        lines = self._render_lines(w)
        body_h = h - 3
        start = max(0, len(lines) - body_h - self.scroll)
        visible = lines[start : start + body_h]
        for i, (color, text) in enumerate(visible):
            stdscr.addstr(1 + i, 0, text[:w], _attr(color))

        # Status / confirmation line
        if self.confirming is not None:
            c = self.confirming
            prompt = f"⚠ allow tool '{c['name']}' with {c['args']}? [y/N] "
            stdscr.addstr(h - 2, 0, prompt[:w], _attr(_C_ERR) | curses.A_BOLD)
        elif self.status:
            stdscr.addstr(h - 2, 0, self.status[:w], _attr(_C_SYS))

        # Input line
        label = "You> "
        shown = self.input_buf
        avail = w - len(label) - 2
        if len(shown) > avail:
            shown = shown[-avail:]
        stdscr.addstr(h - 1, 0, label, _attr(_C_USER) | curses.A_BOLD)
        stdscr.addstr(h - 1, len(label), shown + "▌", _attr(_C_USER))
        stdscr.refresh()

    def _main(self, stdscr: Any) -> int:
        curses.curs_set(1)
        stdscr.keypad(True)
        stdscr.nodelay(True)
        while not self.quit:
            # Drain worker events.
            try:
                while True:
                    self._handle_event(self.events.get_nowait())
            except queue.Empty:
                pass
            self._draw(stdscr)
            try:
                ch = stdscr.get_wch()
            except curses.error:
                ch = None
            if ch is not None and not self._handle_key(stdscr, ch):
                self.quit = True
            time.sleep(0.02)
        return self.exit_code


def _message_screen(stdscr: Any, title: str, message: str, tip: str) -> int:
    _init_colors()
    h, w = stdscr.getmaxyx()
    stdscr.erase()
    row = max(0, h // 2 - 3)
    stdscr.addstr(row, max(0, w // 2 - len(title) // 2), title, _attr(_C_ERR) | curses.A_BOLD)
    for i, line in enumerate(textwrap.wrap(message, w - 4)[:12]):
        stdscr.addstr(row + 2 + i, 2, line, _attr(_C_USER))
    if tip:
        stdscr.addstr(row + 14, 2, tip, _attr(_C_SYS))
    stdscr.addstr(h - 2, 2, "press any key to exit", _attr(_C_HEADER))
    stdscr.refresh()
    stdscr.nodelay(False)
    stdscr.get_wch()
    return 1


def run_tui(agent_factory: Callable[[], Any], config: dict, model_path: str) -> int:
    """Create the agent (showing a loading screen) and run the chat TUI."""
    def _run(stdscr: Any) -> int:
        _init_colors()
        h, w = stdscr.getmaxyx()
        stdscr.addstr(h // 2, max(0, w // 2 - 12), "  Loading model…  ", _attr(_C_HEADER) | curses.A_BOLD)
        stdscr.refresh()
        try:
            agent = agent_factory()
        except utils.AidoError as exc:
            return _message_screen(
                stdscr,
                "AIDO cannot start",
                str(exc),
                "Tip: run `aido setup` to download the local model, or `aido --model PATH`.",
            )
        except Exception as exc:
            return _message_screen(stdscr, "AIDO cannot start", f"{exc}", "")
        tui = ChatTui(agent, config)
        try:
            return tui._main(stdscr)
        finally:
            agent.close()

    return curses.wrapper(_run)

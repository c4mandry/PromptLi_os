"""AIDO REPL — an aichat-style chat experience.

Same shape as the de-facto standard TUI AI client: a line REPL with
persistent input history, streaming answers, markdown rendering with code
highlighting, dot-commands (``.help``, ``.info``, ``.model``, ``.role``,
``.session``, ``.file``, ``.editor``, ``.exit``), auto-saved sessions and
switchable roles. Runs in any terminal (no curses), so scrolling,
copy/paste and terminal emulator features all work normally.

Start:

    aido            start chatting (default session)
    aido -s dev     resume/switch to the 'dev' session
    aido -r         resume the most recent session
    aido tui        the full-screen curses chat (classic mode)
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Callable

import session as session_mod
import roles as roles_mod
import utils
from agent import Agent

try:
    import readline  # noqa: F401 — stdlib history + line editing
except ImportError:
    readline = None  # type: ignore[assignment]

HISTORY_FILE = Path.home() / ".aido" / "history"
_BOLD = "\033[1m"
_DIM = "\033[2m"
_CYAN = "\033[36m"
_GREEN = "\033[32m"
_YELLOW = "\033[33m"
_RESET = "\033[0m"

if sys.stdout.isatty():
    _HAS_COLOR = True
else:
    _HAS_COLOR = False


def _c(code: str, text: str) -> str:
    return f"{code}{text}{_RESET}" if _HAS_COLOR else text


def prompt_char() -> str:
    if os.environ.get("TERM") == "linux":
        return _c(_GREEN, "> ")
    return _c(_GREEN, "❯ ")


# ── markdown rendering ───────────────────────────────────────────────────


def _highlight_block(lang: str, code: str) -> str:
    """Syntax-highlight a fenced code block via bat when available."""
    try:
        proc = subprocess.run(
            ["bat", "--language", lang or "txt", "--style=plain", "--paging=never", "--color=always"],
            input=code,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if proc.returncode == 0 and proc.stdout:
            return proc.stdout.rstrip("\n")
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass
    return _c(_DIM, code)


def render_markdown(text: str) -> str:
    """Render markdown to ANSI for the terminal (headings, bold, inline code,
    fenced code blocks with syntax highlighting)."""
    out: list[str] = []
    in_fence = False
    fence_lang = ""
    fence_buf: list[str] = []
    for line in text.splitlines():
        fence = re.match(r"^\s*(```+|~~~+)\s*(\S*)", line)
        if fence:
            if not in_fence:
                in_fence = True
                fence_lang = fence.group(2)
                fence_buf = []
                continue
            in_fence = False
            out.append(_highlight_block(fence_lang, "\n".join(fence_buf)))
            continue
        if in_fence:
            fence_buf.append(line)
            continue
        # Headings
        h = re.match(r"^\s*(#{1,6})\s+(.*)$", line)
        if h:
            out.append(_c(_BOLD, h.group(2)))
            continue
        # Inline formatting: **bold**, *italic*, `code`
        rendered = line
        rendered = re.sub(r"\*\*(.+?)\*\*", lambda m: _c(_BOLD, m.group(1)), rendered)
        rendered = re.sub(r"`([^`]+)`", lambda m: _c(_CYAN, m.group(1)), rendered)
        out.append(rendered)
    if in_fence:
        out.append(_highlight_block(fence_lang, "\n".join(fence_buf)))
    return "\n".join(out)


class _LineRenderer:
    """Incremental markdown renderer for streaming output.

    Complete lines are rendered as they arrive (headings, bold, inline code);
    fenced code blocks are buffered until their closing fence and then
    syntax-highlighted with bat.
    """

    def __init__(self) -> None:
        self.partial = ""
        self.in_fence = False
        self.fence_lang = ""
        self.fence_buf: list[str] = []

    def feed(self, token: str) -> None:
        self.partial += token
        while "\n" in self.partial:
            line, self.partial = self.partial.split("\n", 1)
            self._line(line)

    def _line(self, line: str) -> None:
        fence = re.match(r"^\s*(```+|~~~+)\s*(\S*)", line)
        if fence:
            if not self.in_fence:
                self.in_fence = True
                self.fence_lang = fence.group(2)
                self.fence_buf = []
            else:
                self.in_fence = False
                sys.stdout.write(_highlight_block(self.fence_lang, "\n".join(self.fence_buf)) + "\n")
            return
        if self.in_fence:
            self.fence_buf.append(line)
            return
        sys.stdout.write(render_markdown(line) + "\n")

    def flush(self) -> None:
        if self.in_fence:
            sys.stdout.write(_highlight_block(self.fence_lang, "\n".join(self.fence_buf)) + "\n")
            self.in_fence = False
        elif self.partial:
            sys.stdout.write(render_markdown(self.partial))
        self.partial = ""


# ── the REPL ─────────────────────────────────────────────────────────────


class Repl:
    def __init__(
        self,
        agent_factory: Callable[[], Agent],
        config: dict,
        model_path: str,
        session_name: str | None = None,
        resume_last: bool = False,
    ) -> None:
        self.agent_factory = agent_factory
        self.config = config or {}
        self.model_path = str(model_path)
        self.model_name = Path(self.model_path).name
        self.sudo_on = False
        self.auto_approve = False
        self.attached_file: str | None = None
        self.attached_name: str | None = None
        self.session = session_name or "default"
        if resume_last and not session_name:
            last = session_mod.last_session()
            if last:
                self.session = last
        self._load_session()

    def _load_session(self) -> None:
        self.agent = self.agent_factory()
        self.messages: list[dict[str, str]] = []
        history = session_mod.load_session(self.session)
        if history:
            self.agent.load_history(history)
            self.messages = list(history)

    # -- io ---------------------------------------------------------------

    def _load_readline(self) -> None:
        if readline is None:
            return
        HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
        try:
            readline.read_history_file(str(HISTORY_FILE))
        except OSError:
            pass
        readline.set_history_length(2000)

    def _save_readline(self) -> None:
        if readline is None:
            return
        try:
            readline.write_history_file(str(HISTORY_FILE))
        except OSError:
            pass

    def _input(self) -> str | None:
        try:
            return input(prompt_char())
        except (EOFError, KeyboardInterrupt):
            return None

    # -- agent plumbing ---------------------------------------------------

    def _confirm(self, name: str, arguments: dict) -> bool:
        # Full autonomy: .auto mode, or sudo mode (the user gave the root
        # password — aido may act freely).
        if self.auto_approve:
            print(_c(_DIM, f"  ⚙ {name} {arguments} — auto-approved (.auto)"))
            return True
        if self.sudo_on:
            print(_c(_DIM, f"  ⚙ {name} {arguments} — auto-approved (sudo)"))
            return True
        try:
            answer = input(_c(_YELLOW, f"  ⚠ allow tool '{name}' with {arguments}? [y/N] ")).strip().lower()
        except (EOFError, KeyboardInterrupt):
            return False
        return answer in ("y", "yes")

    def _ask_sudo_password(self) -> None:
        import getpass

        password = getpass.getpass("sudo password: ")
        if password:
            self.agent.sudo["password"] = password
            self.sudo_on = True
            print(_c(_YELLOW, "sudo mode ON — commands run as root (.sudo to turn off)"))
        else:
            print(_c(_DIM, "sudo mode cancelled (empty password)"))

    # -- chat -------------------------------------------------------------

    def _exchange(self, text: str) -> None:
        if self.attached_file:
            text = f"Here is the file {self.attached_name} :\n\n{self.attached_file}\n\n{text}"
            self.attached_file = None
            self.attached_name = None
        self.messages.append({"role": "user", "content": text})
        self.agent.confirm = self._confirm
        buffer: list[str] = []
        renderer = _LineRenderer()
        printed_stream = False

        def on_token(token: str) -> None:
            nonlocal printed_stream
            buffer.append(token)
            buf = "".join(buffer)
            # Stream live only when the output looks like a plain answer
            # (not a JSON tool call) — tool-call JSON stays hidden.
            if not buf.lstrip().startswith("{") and '"tool"' not in buf:
                printed_stream = True
                renderer.feed(token)
                sys.stdout.flush()

        t0 = time.time()
        try:
            result = self.agent.chat(text, interactive=True, assume_yes=False, stream_callback=on_token)
        except KeyboardInterrupt:
            # Ctrl+C during a reply: cancel gracefully, keep the REPL alive.
            renderer.flush()
            sys.stdout.write("\n")
            sys.stdout.flush()
            print(_c(_DIM, "  (interrupted)"))
            self.messages.append({"role": "assistant", "content": "(interrupted)"})
            self._autosave()
            return
        except utils.AidoError as exc:
            print(_c("\033[31m", f"❌ {exc}"))
            return
        except Exception as exc:
            print(_c("\033[31m", f"❌ {exc}"))
            return

        if printed_stream:
            renderer.flush()
            sys.stdout.write("\n")
            sys.stdout.flush()
        answer = str(result.get("answer", "")).strip()
        if answer and not printed_stream:
            print(render_markdown(answer))
        for call in result.get("tool_calls", []):
            print(_c(_DIM, f"  ⚙ {call.get('tool')} {call.get('arguments')}"))
        self.messages.append({"role": "assistant", "content": answer})
        self._autosave()
        elapsed = time.time() - t0
        if elapsed > 0.5:
            print(_c(_DIM, f"  ({elapsed:.1f}s)"))

    def _autosave(self) -> None:
        if not self.config.get("save_session", True):
            return
        try:
            session_mod.save_session(self.session, self.messages)
        except Exception:
            pass

    # -- dot commands -----------------------------------------------------

    def _command(self, line: str) -> bool:
        """Handle a dot command; returns False when the REPL should exit."""
        parts = line.split()
        name = parts[0].lstrip(".").lower()
        args = parts[1:]

        if name in ("help", "?"):
            print(
                "\n".join(
                    [
                        _c(_BOLD, "AIDO commands"),
                        "  .help                this help",
                        "  .info                model, role, session, key status",
                        "  .model <path>        switch the local model",
                        "  .role <name>         switch role (list with no name)",
                        "  .role --create <n>   create a new role in $EDITOR",
                        "  .session <name>      switch session (list with no name)",
                        "  .file <path>         attach a file to the next message",
                        "  .editor              compose a long message in $EDITOR",
                        "  .sudo                toggle sudo mode (commands as root, auto-approves)",
                        "  .auto                toggle auto mode (no confirmations at all)",
                        "  .tools               list available tools",
                        "  .exit / .quit        quit (session is saved)",
                        "",
                        "Type anything else and AIDO answers it.",
                    ]
                )
            )
            return True
        if name == "info":
            key_status = "not set"
            try:
                from secrets import SECRET_PATH

                if SECRET_PATH.is_file():
                    key_status = "set (encrypted)"
            except Exception:
                pass
            print(f"model:    {self.model_path}")
            print(f"session:  {self.session}")
            print(f"role:     {getattr(self, 'current_role', None) or 'agent (built-in)'}")
            print(f"sudo:     {'ON' if self.sudo_on else 'OFF'}")
            print(f"auto:     {'ON' if self.auto_approve else 'OFF'}")
            print(f"API key:  {key_status}")
            return True
        if name == "model":
            if not args:
                print(f"model: {self.model_path}")
                return True
            new_path = Path(args[0]).expanduser()
            if not new_path.is_file():
                print(_c("\033[31m", f"model not found: {new_path}"))
                return True
            self.model_path = str(new_path)
            self.model_name = new_path.name
            old_agent = self.agent
            try:
                self.agent = self.agent_factory()
                history = list(self.messages)
                if history:
                    self.agent.load_history(history)
                old_agent.close()
            except utils.AidoError as exc:
                self.agent = old_agent
                print(_c("\033[31m", f"could not load model: {exc}"))
                return True
            print(_c(_GREEN, f"model → {self.model_name}"))
            return True
        if name == "role":
            if args and args[0] == "--create":
                role_name = args[1] if len(args) > 1 else None
                if not role_name:
                    print("usage: .role --create <name>")
                    return True
                path = roles_mod.create_role(role_name)
                if path and self._open_editor(path):
                    print(_c(_GREEN, f"role '{role_name}' created"))
                return True
            if not args:
                names = roles_mod.list_roles()
                print(_c(_BOLD, "roles:"))
                for n in names:
                    mark = "  " if n != getattr(self, "current_role", None) else "→ "
                    print(f"  {mark}{n}")
                print("\n.role <name> to switch · .role --create <name> for a new one")
                return True
            name = args[0]
            text = roles_mod.load_role(name)
            if text is None and name != "agent":
                print(_c("\033[31m", f"no role '{name}' — .role to list"))
                return True
            self.current_role = None if name == "agent" else name
            self.agent.set_role_file(text)
            print(_c(_GREEN, f"role → {name if name != 'agent' else 'agent (built-in)'}"))
            return True
        if name == "session":
            if not args:
                names = session_mod.list_sessions()
                print(_c(_BOLD, "sessions:"))
                for n in names:
                    mark = "→ " if n == self.session else "  "
                    print(f"  {mark}{n}")
                print("\n.session <name> to switch")
                return True
            self._autosave()
            self.session = args[0]
            self._load_session()
            print(_c(_GREEN, f"session → {self.session}"))
            return True
        if name == "file":
            if not args:
                print("usage: .file <path>")
                return True
            path = Path(args[0]).expanduser()
            try:
                content = path.read_text(encoding="utf-8", errors="replace")
            except OSError as exc:
                print(_c("\033[31m", f"cannot read {path}: {exc}"))
                return True
            self.attached_file = content if len(content) <= 20000 else content[:20000]
            self.attached_name = str(path)
            print(_c(_GREEN, f"attached {path} to the next message"))
            return True
        if name == "editor":
            text = self._compose_in_editor()
            if text:
                self._exchange(text)
            return True
        if name == "sudo":
            if self.sudo_on:
                self.agent.sudo["password"] = None
                self.sudo_on = False
                print(_c(_DIM, "sudo mode OFF"))
            else:
                self._ask_sudo_password()
            return True
        if name == "auto":
            self.auto_approve = not self.auto_approve
            state = "ON" if self.auto_approve else "OFF"
            print(_c(_YELLOW if self.auto_approve else _DIM, f"auto mode {state} — aido acts without confirmations"))
            return True
        if name == "tools":
            from tools import TOOL_REGISTRY

            for tool in TOOL_REGISTRY:
                flag = " (confirm)" if tool.get("dangerous") else ""
                print(f"  {tool['name']:<18} {tool['description']}{flag}")
            return True
        if name in ("exit", "quit"):
            return False
        print(_c("\033[31m", f"unknown command .{name} — try .help"))
        return True

    def _compose_in_editor(self) -> str | None:
        editor = os.environ.get("EDITOR", os.environ.get("VISUAL", "nano"))
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as fh:
            fh.write("# Type your message, save and exit.\n\n")
            tmp = fh.name
        try:
            subprocess.run([editor, tmp], check=False)
            return Path(tmp).read_text(encoding="utf-8").strip()
        except OSError:
            print(_c("\033[31m", f"editor '{editor}' not found — set $EDITOR"))
            return None
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass

    def _open_editor(self, path: Path) -> bool:
        editor = os.environ.get("EDITOR", os.environ.get("VISUAL", "nano"))
        try:
            subprocess.run([editor, str(path)], check=False)
            return True
        except OSError:
            print(_c("\033[31m", f"editor '{editor}' not found"))
            return False

    # -- main loop --------------------------------------------------------

    def run(self) -> int:
        self._load_readline()
        try:
            print(_c(_BOLD, f"AIDO") + _c(_DIM, f" · model {self.model_name} · session '{self.session}'"))
            print(_c(_DIM, "Type your question, or .help for commands. Ctrl+D to exit."))
            while True:
                try:
                    line = self._input()
                except KeyboardInterrupt:
                    print()
                    continue
                if line is None:
                    print()
                    break
                line = line.strip()
                if not line:
                    continue
                if line.startswith("."):
                    if not self._command(line):
                        break
                    continue
                self._exchange(line)
        finally:
            self._autosave()
            self._save_readline()
            try:
                self.agent.close()
            except Exception:
                pass
        print(_c(_DIM, f"session saved → ~/.aido/sessions/{self.session}.yaml"))
        return 0


def run_repl(
    agent_factory: Callable[[], Agent],
    config: dict,
    model_path: str,
    session_name: str | None = None,
    resume_last: bool = False,
) -> int:
    return Repl(agent_factory, config, model_path, session_name, resume_last).run()

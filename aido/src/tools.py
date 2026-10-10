"""Tool implementations for AIDO.

Every tool is a plain function that returns a JSON-serializable dict and
raises :class:`utils.AidoError` with a user-friendly message on failure.
Tools never print, and they never ask for confirmation themselves — the
agent layer handles interactivity and safety checks centrally.

The optional heavy dependencies (Playwright, requests, PyYAML) are imported
lazily inside the functions that need them, so the rest of AIDO works even
when they are not installed.
"""

from __future__ import annotations

import configparser
import datetime
import fnmatch
import json
import os
import platform
import re
import shlex
import shutil
import signal
import subprocess
import sys
from pathlib import Path
from typing import Any

import utils

USER_AGENT = "AIDO/0.1.0"

#: Config file extensions AIDO understands, mapped to their format name.
CONFIG_FORMATS = {
    ".json": "json",
    ".yaml": "yaml",
    ".yml": "yaml",
    ".ini": "ini",
    ".cfg": "ini",
    ".conf": "ini",
}


# ---------------------------------------------------------------------------
# File tools
# ---------------------------------------------------------------------------

def _resolve(path: Any, allowed_dirs: list[str] | None = None) -> Path:
    """Resolve *path* and enforce the allowed-directory sandbox."""
    return utils.restrict_to_allowed(path, allowed_dirs)


def _local_iso(ts: float) -> str:
    """Format an epoch timestamp as a local ISO-8601 string."""
    return datetime.datetime.fromtimestamp(ts, tz=datetime.timezone.utc).astimezone().isoformat(timespec="seconds")


def _describe_path(p: Path) -> dict[str, Any]:
    try:
        stat = p.stat()
    except OSError:
        stat = None
    if p.is_symlink():
        kind = "symlink"
    elif p.is_dir():
        kind = "directory"
    else:
        kind = "file"
    return {
        "name": p.name,
        "type": kind,
        "size": stat.st_size if stat is not None and kind == "file" else None,
        "modified": _local_iso(stat.st_mtime) if stat is not None else None,
    }


def list_files(path: str = ".", include_hidden: bool = False, allowed_dirs: list[str] | None = None) -> dict[str, Any]:
    """List the contents of *path* with size, type and modification date."""
    target = _resolve(path, allowed_dirs)
    if not target.is_dir():
        raise utils.AidoError(f"Not a directory: {path}")
    entries = []
    for item in sorted(target.iterdir(), key=lambda p: p.name.lower()):
        if not include_hidden and item.name.startswith("."):
            continue
        entries.append(_describe_path(item))
    return {"path": str(target), "count": len(entries), "entries": entries}


def find_files(
    root: str = ".",
    name: str | None = None,
    pattern: str | None = None,
    max_results: int = 50,
    allowed_dirs: list[str] | None = None,
) -> dict[str, Any]:
    """Recursively search *root* for files matching *name* and/or glob *pattern*."""
    base = _resolve(root, allowed_dirs)
    if not base.is_dir():
        raise utils.AidoError(f"Not a directory: {root}")
    matches: list[str] = []
    for p in sorted(base.rglob("*")):
        if any(part.startswith(".") for part in p.relative_to(base).parts):
            continue
        if name and name.lower() not in p.name.lower():
            continue
        if pattern:
            rel = str(p.relative_to(base))
            if not (
                fnmatch.fnmatch(p.name, pattern)
                or fnmatch.fnmatch(rel, pattern)
                or pattern.lower() in p.name.lower()
            ):
                continue
        matches.append(str(p.relative_to(base)))
        if len(matches) >= max_results:
            break
    return {"root": str(base), "name": name, "pattern": pattern, "count": len(matches), "matches": matches}


def file_info(path: str, allowed_dirs: list[str] | None = None) -> dict[str, Any]:
    """Get detailed properties of a file or directory."""
    p = _resolve(path, allowed_dirs)
    if not p.exists():
        raise utils.AidoError(f"File not found: {path}")
    stat = p.stat()
    try:
        owner = p.owner()
    except (AttributeError, KeyError, NotImplementedError, OSError):
        owner = None
    if p.is_symlink():
        kind = "symlink"
    elif p.is_dir():
        kind = "directory"
    else:
        kind = "file"
    return {
        "path": str(p),
        "name": p.name,
        "type": kind,
        "size": stat.st_size if kind == "file" else None,
        "modified": _local_iso(stat.st_mtime),
        "permissions": oct(stat.st_mode & 0o777),
        "owner": owner,
    }


# ---------------------------------------------------------------------------
# Window tools (Linux/X11, wmctrl + xdotool)
# ---------------------------------------------------------------------------

def _window_backend() -> str:
    """Verify we are on Linux with wmctrl available, else raise a helpful error."""
    if sys.platform != "linux":
        raise utils.AidoError(
            "Window control requires Linux with an X11/Wayland desktop (wmctrl/xdotool)."
        )
    if shutil.which("wmctrl") is None:
        raise utils.AidoError(
            "wmctrl is not installed. Install it with: sudo apt install wmctrl xdotool"
        )
    return "wmctrl"


def _wmctrl(*args: str) -> subprocess.CompletedProcess:
    return utils.run_command(["wmctrl", *args])


def list_windows() -> dict[str, Any]:
    """List all windows managed by the window manager."""
    _window_backend()
    proc = _wmctrl("-lp")
    windows = []
    for line in proc.stdout.splitlines():
        fields = line.split(None, 4)
        if len(fields) < 5:
            continue
        windows.append(
            {
                "id": fields[0],
                "desktop": int(fields[1]) if fields[1].isdigit() else fields[1],
                "pid": fields[2],
                "host": fields[3],
                "title": fields[4],
            }
        )
    return {"count": len(windows), "windows": windows}


def _find_window(ref: Any) -> dict[str, Any]:
    """Resolve a window reference to its id and current geometry.

    *ref* may be a wmctrl window id (``0x...``), a title substring, or
    ``None``/``""`` for the active window (requires xdotool).
    """
    _window_backend()
    ref_text = str(ref).strip() if ref not in (None, "") else ""
    if ref_text == "":
        if shutil.which("xdotool") is None:
            raise utils.AidoError("No window specified and xdotool is not installed.")
        win_id = utils.run_command(["xdotool", "getactivewindow"]).stdout.strip()
    elif re.fullmatch(r"0x[0-9a-fA-F]+", ref_text):
        win_id = ref_text
    else:
        matches = [line for line in _wmctrl("-l").stdout.splitlines() if ref_text.lower() in line.lower()]
        if not matches:
            raise utils.AidoError(
                f"No window matching '{ref_text}' was found. Use list_windows to see open windows."
            )
        win_id = matches[0].split()[0]
    # wmctrl -lG adds geometry columns: id desktop x y w h host title
    for line in _wmctrl("-lG").stdout.splitlines():
        fields = line.split(None, 7)
        if len(fields) >= 8 and fields[0] == win_id:
            return {
                "id": win_id,
                "x": fields[2],
                "y": fields[3],
                "width": fields[4],
                "height": fields[5],
                "title": fields[7],
            }
    return {"id": win_id, "x": None, "y": None, "width": None, "height": None, "title": ""}


def move_window(ref: Any, x: int, y: int, width: int | None = None, height: int | None = None) -> dict[str, Any]:
    """Move a window to position (x, y), optionally resizing it too."""
    win = _find_window(ref)
    w = int(width) if width is not None else (int(win["width"]) if win["width"] else 800)
    h = int(height) if height is not None else (int(win["height"]) if win["height"] else 600)
    _wmctrl("-i", "-r", win["id"], "-e", f"0,{int(x)},{int(y)},{w},{h}")
    return {"window": win["id"], "title": win["title"], "position": [int(x), int(y)], "size": [w, h], "status": "moved"}


def resize_window(ref: Any, width: int, height: int) -> dict[str, Any]:
    """Resize a window, keeping its current position."""
    win = _find_window(ref)
    x = int(win["x"]) if win["x"] is not None else 0
    y = int(win["y"]) if win["y"] is not None else 0
    _wmctrl("-i", "-r", win["id"], "-e", f"0,{x},{y},{int(width)},{int(height)}")
    return {"window": win["id"], "size": [int(width), int(height)], "status": "resized"}


def minimize_window(ref: Any) -> dict[str, Any]:
    """Minimize a window (requires xdotool; wmctrl cannot minimize)."""
    win = _find_window(ref)
    if shutil.which("xdotool") is None:
        raise utils.AidoError("Minimizing requires xdotool. Install it with: sudo apt install xdotool")
    utils.run_command(["xdotool", "windowminimize", win["id"]])
    return {"window": win["id"], "status": "minimized"}


def maximize_window(ref: Any) -> dict[str, Any]:
    """Maximize a window."""
    win = _find_window(ref)
    _wmctrl("-i", "-r", win["id"], "-b", "add,maximized_vert,maximized_horz")
    return {"window": win["id"], "status": "maximized"}


def focus_window(ref: Any) -> dict[str, Any]:
    """Focus (raise) a window."""
    win = _find_window(ref)
    _wmctrl("-i", "-a", win["id"])
    return {"window": win["id"], "status": "focused"}


def close_window(ref: Any) -> dict[str, Any]:
    """Ask a window to close gracefully (its application may prompt to save)."""
    win = _find_window(ref)
    _wmctrl("-i", "-c", win["id"])
    return {"window": win["id"], "title": win["title"], "status": "close requested"}


def get_screen_size() -> dict[str, Any]:
    """Return the screen resolution in pixels."""
    _window_backend()
    if shutil.which("xdotool"):
        try:
            width, height = utils.run_command(["xdotool", "getdisplaygeometry"]).stdout.split()
            return {"width": int(width), "height": int(height)}
        except utils.AidoError:
            pass
    if shutil.which("xdpyinfo"):
        try:
            out = utils.run_command(["xdpyinfo"]).stdout
        except utils.AidoError:
            out = ""
        match = re.search(r"dimensions:\s+(\d+)x(\d+)", out)
        if match:
            return {"width": int(match.group(1)), "height": int(match.group(2))}
    raise utils.AidoError("Could not determine the screen size (needs xdotool or xdpyinfo).")


def screenshot(destination: str | None = None, allowed_dirs: list[str] | None = None) -> dict[str, Any]:
    """Capture the screen to a PNG file (Phase 2).

    Uses the first available tool: ``scrot`` or ImageMagick ``import`` on
    Linux, ``screencapture`` on macOS. Defaults to ``~/Pictures/``.
    """
    if destination:
        dest = _resolve(destination, allowed_dirs)
    else:
        dest = Path.home() / "Pictures" / f"aido-screenshot-{utils.timestamp()}.png"
    dest.parent.mkdir(parents=True, exist_ok=True)
    if sys.platform == "darwin":
        cmd = ["screencapture", "-x", str(dest)]
    elif shutil.which("scrot"):
        cmd = ["scrot", str(dest)]
    elif shutil.which("import"):  # ImageMagick
        cmd = ["import", "-window", "root", str(dest)]
    elif shutil.which("gnome-screenshot"):
        cmd = ["gnome-screenshot", "-f", str(dest)]
    else:
        raise utils.AidoError(
            "No screenshot tool found. Install one of: scrot, imagemagick, gnome-screenshot."
        )
    utils.run_command(cmd)
    if not dest.is_file():
        raise utils.AidoError(f"The screenshot tool ran but produced no file at {dest}")
    return {"destination": str(dest), "size": dest.stat().st_size, "status": "captured"}


# ---------------------------------------------------------------------------
# Process tools
# ---------------------------------------------------------------------------

def launch_app(command: str, cwd: str | None = None) -> dict[str, Any]:
    """Launch an application in the background and return its PID."""
    if not command or not isinstance(command, str):
        raise utils.AidoError("launch_app needs a command string, e.g. 'firefox'.")
    try:
        proc = subprocess.Popen(
            shlex.split(command),
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except FileNotFoundError:
        raise utils.AidoError(f"Could not launch '{command}': command not found.") from None
    return {"command": command, "pid": proc.pid, "status": "running"}


def list_processes(filter_text: str | None = None, limit: int = 25) -> dict[str, Any]:
    """List running processes, optionally filtered by name/command substring."""
    proc = utils.run_command(["ps", "-axo", "pid=,comm=,args="])
    processes = []
    for line in proc.stdout.splitlines():
        fields = line.split(None, 2)
        if len(fields) < 2:
            continue
        pid, comm = fields[0], fields[1]
        args = fields[2] if len(fields) == 3 else ""
        if filter_text and filter_text.lower() not in f"{comm} {args}".lower():
            continue
        try:
            processes.append({"pid": int(pid), "name": comm, "command": args})
        except ValueError:
            continue
        if len(processes) >= limit:
            break
    return {"count": len(processes), "processes": processes}


def terminate_process(pid: int, force: bool = False) -> dict[str, Any]:
    """Terminate a process by PID (SIGTERM, or SIGKILL when *force* is set)."""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        raise utils.AidoError(f"Invalid PID: {pid!r}") from None
    try:
        os.kill(pid, signal.SIGKILL if force else signal.SIGTERM)
    except ProcessLookupError:
        raise utils.AidoError(f"No process with PID {pid}.") from None
    except PermissionError:
        raise utils.AidoError(f"Permission denied terminating process {pid}.") from None
    return {"pid": pid, "signal": "SIGKILL" if force else "SIGTERM", "status": "terminated"}


def _memory_info() -> dict[str, Any] | None:
    """Read memory totals from /proc/meminfo on Linux; None elsewhere."""
    if sys.platform != "linux":
        return None
    meminfo = Path("/proc/meminfo")
    if not meminfo.is_file():
        return None
    values: dict[str, str] = {}
    for line in meminfo.read_text(encoding="utf-8").splitlines():
        key, _, rest = line.partition(":")
        values[key.strip()] = rest.strip()

    def kilobytes(name: str) -> int:
        return int(values.get(name, "0 kB").split()[0]) * 1024

    return {"total": kilobytes("MemTotal"), "available": kilobytes("MemAvailable")}


def system_info() -> dict[str, Any]:
    """Return basic system stats: CPU count, load, memory and disk usage (Phase 2)."""
    disk = shutil.disk_usage(Path.home())
    info: dict[str, Any] = {
        "platform": platform.platform(),
        "cpu_count": os.cpu_count(),
        "disk_usage": {
            "path": str(Path.home()),
            "total": disk.total,
            "used": disk.used,
            "free": disk.free,
        },
        "memory": _memory_info(),
    }
    try:
        info["load_average"] = list(os.getloadavg())
    except (AttributeError, OSError):
        pass
    return info


# ---------------------------------------------------------------------------
# Config tools (JSON / YAML / INI)
# ---------------------------------------------------------------------------

def _config_format(path: Path) -> str:
    fmt = CONFIG_FORMATS.get(path.suffix.lower())
    if fmt is None:
        raise utils.AidoError(
            f"Unsupported config format: '{path.suffix}'. "
            f"Supported: json, yaml, ini (extensions: .json, .yaml, .yml, .ini, .cfg, .conf)."
        )
    return fmt


def _load_config(path: Path) -> tuple[str, Any]:
    fmt = _config_format(path)
    with open(path, encoding="utf-8") as fh:
        if fmt == "json":
            data = json.load(fh)
        elif fmt == "yaml":
            import yaml

            data = yaml.safe_load(fh) or {}
        else:
            parser = configparser.ConfigParser()
            parser.read(path, encoding="utf-8")
            data = {section: dict(parser.items(section)) for section in parser.sections()}
    return fmt, data


def _save_config(path: Path, data: Any, fmt: str) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        if fmt == "json":
            json.dump(data, fh, indent=2)
            fh.write("\n")
        elif fmt == "yaml":
            import yaml

            yaml.safe_dump(data, fh, sort_keys=False, default_flow_style=False)
        else:
            parser = configparser.ConfigParser()
            for section, items in data.items():
                parser[section] = {str(key): str(value) for key, value in items.items()}
            parser.write(fh)


def _set_nested(data: dict[str, Any], dotted_key: str, value: Any) -> Any:
    """Set ``a.b.c`` inside a nested dict; returns the previous value."""
    parts = dotted_key.split(".")
    node = data
    for part in parts[:-1]:
        if not isinstance(node.get(part), dict):
            node[part] = {}
        node = node[part]
    old = node.get(parts[-1])
    node[parts[-1]] = value
    return old


def read_config(path: str, allowed_dirs: list[str] | None = None) -> dict[str, Any]:
    """Read a JSON, YAML or INI config file."""
    p = _resolve(path, allowed_dirs)
    if not p.is_file():
        raise utils.AidoError(f"Config file not found: {path}")
    fmt, data = _load_config(p)
    return {"path": str(p), "format": fmt, "data": data}


def backup_config(path: str, allowed_dirs: list[str] | None = None) -> dict[str, Any]:
    """Copy a config file to a timestamped backup next to the original."""
    p = _resolve(path, allowed_dirs)
    if not p.is_file():
        raise utils.AidoError(f"Config file not found: {path}")
    backup = p.with_name(f"{p.name}.backup-{utils.timestamp()}")
    shutil.copy2(p, backup)
    return {"path": str(p), "backup": str(backup), "status": "backed up"}


def restore_config(path: str, backup: str, allowed_dirs: list[str] | None = None) -> dict[str, Any]:
    """Restore a config file from a backup copy."""
    p = _resolve(path, allowed_dirs)
    b = _resolve(backup, allowed_dirs)
    if not b.is_file():
        raise utils.AidoError(f"Backup file not found: {backup}")
    shutil.copy2(b, p)
    return {"path": str(p), "restored_from": str(b), "status": "restored"}


def edit_config(
    path: str,
    changes: dict[str, Any],
    auto_backup: bool = True,
    allowed_dirs: list[str] | None = None,
) -> dict[str, Any]:
    """Apply *changes* (dotted keys → values) to a JSON/YAML/INI config file.

    A timestamped backup is created first unless *auto_backup* is False, so
    every edit can be undone with :func:`restore_config`.
    """
    p = _resolve(path, allowed_dirs)
    if not p.is_file():
        raise utils.AidoError(f"Config file not found: {path}")
    if not isinstance(changes, dict) or not changes:
        raise utils.AidoError("edit_config needs a 'changes' object, e.g. {'theme': 'dark'}.")
    fmt, data = _load_config(p)
    backup = backup_config(str(p))["backup"] if auto_backup else None
    applied = []
    for key, value in changes.items():
        old = _set_nested(data, key, value)
        applied.append({"key": key, "old": old, "new": value})
    _save_config(p, data, fmt)
    return {"path": str(p), "format": fmt, "changes": applied, "backup": backup, "status": "updated"}


# ---------------------------------------------------------------------------
# Web tools
# ---------------------------------------------------------------------------

def _import_requests():
    try:
        import requests

        return requests
    except ImportError:
        raise utils.AidoError("requests is not installed. Run: pip install requests") from None


def fetch_url(url: str, timeout: int = 15) -> dict[str, Any]:
    """GET a URL and return its status, headers and (truncated) text content."""
    requests = _import_requests()
    try:
        resp = requests.get(url, timeout=timeout, headers={"User-Agent": USER_AGENT})
        resp.raise_for_status()
    except requests.RequestException as exc:
        raise utils.AidoError(f"Request to {url} failed: {exc}") from None
    return {
        "url": resp.url,
        "status": resp.status_code,
        "content_type": resp.headers.get("Content-Type"),
        "length": len(resp.content),
        "text": utils.truncate(resp.text or "", 4000),
    }


def download_file(
    url: str,
    destination: str | None = None,
    downloads_dir: str = "~/Downloads",
    timeout: int = 120,
) -> dict[str, Any]:
    """Download *url* to *destination* (default: downloads dir + URL filename).

    Data is streamed to a ``.part`` file first, so an interrupted download
    never leaves a corrupt file behind.
    """
    requests = _import_requests()
    if destination:
        dest = _resolve(destination)
    else:
        filename = Path(url.split("?", 1)[0]).name or "download"
        dest = Path(downloads_dir).expanduser().resolve() / filename
    dest.parent.mkdir(parents=True, exist_ok=True)
    partial = dest.with_name(dest.name + ".part")
    try:
        with requests.get(url, stream=True, timeout=timeout, headers={"User-Agent": USER_AGENT}) as resp:
            if resp.status_code >= 400:
                raise utils.AidoError(f"Download failed with HTTP {resp.status_code} for {url}")
            with open(partial, "wb") as fh:
                for chunk in resp.iter_content(chunk_size=65536):
                    if chunk:
                        fh.write(chunk)
        partial.replace(dest)
    except requests.RequestException as exc:
        partial.unlink(missing_ok=True)
        raise utils.AidoError(f"Download of {url} failed: {exc}") from None
    return {"url": url, "destination": str(dest), "size": dest.stat().st_size, "status": "complete"}


def browse_page(url: str, headless: bool = True, timeout: int = 30, max_text: int = 4000) -> dict[str, Any]:
    """Open *url* in a (by default headless) Chromium browser and extract
    the page title and the main body text, suitable for summarization."""
    try:
        from playwright.sync_api import Error as PlaywrightError
        from playwright.sync_api import sync_playwright
    except ImportError:
        raise utils.AidoError(
            "Playwright is not installed. Run:\n  pip install playwright\n  playwright install chromium"
        ) from None
    try:
        with sync_playwright() as pw:
            browser = pw.chromium.launch(headless=headless)
            try:
                page = browser.new_page()
                page.goto(url, timeout=timeout * 1000, wait_until="domcontentloaded")
                title = page.title()
                paragraphs = page.eval_on_selector_all(
                    "p", "els => els.map(e => e.textContent.trim()).filter(t => t.length > 40)"
                )
                link_count = page.eval_on_selector_all("a[href]", "els => els.length")
            finally:
                browser.close()
    except PlaywrightError as exc:
        raise utils.AidoError(f"Browsing {url} failed: {exc}") from None
    return {
        "url": url,
        "title": title,
        "text": utils.truncate("\n".join(paragraphs[:25]), max_text),
        "links": link_count,
        "status": "ok",
    }


# ---------------------------------------------------------------------------
# Tool registry (consumed by the agent's system prompt)
# ---------------------------------------------------------------------------

TOOL_REGISTRY: list[dict[str, Any]] = [
    {
        "name": "list_files",
        "description": "List the files and folders in a directory with size, type and modification date.",
        "parameters": {"path": "directory path (default: current directory)", "include_hidden": "optional bool, show hidden files"},
        "dangerous": False,
    },
    {
        "name": "find_files",
        "description": "Recursively find files by name substring or glob pattern.",
        "parameters": {"root": "directory to search (default: current directory)", "name": "optional substring matched against file names", "pattern": "optional glob pattern, e.g. *.pdf"},
        "dangerous": False,
    },
    {
        "name": "file_info",
        "description": "Get detailed properties (size, permissions, dates) of a file or directory.",
        "parameters": {"path": "the exact path the user asked about (e.g. 'README.md')"},
        "dangerous": False,
    },
    {
        "name": "list_windows",
        "description": "List all open windows with id, title, desktop and pid.",
        "parameters": {},
        "dangerous": False,
    },
    {
        "name": "move_window",
        "description": "Move a window to a screen position, optionally resizing it.",
        "parameters": {"ref": "window id (0x...) or title substring", "x": "target x position in pixels", "y": "target y position in pixels", "width": "optional new width", "height": "optional new height"},
        "dangerous": False,
    },
    {
        "name": "resize_window",
        "description": "Resize a window, keeping its current position.",
        "parameters": {"ref": "window id (0x...) or title substring", "width": "new width in pixels", "height": "new height in pixels"},
        "dangerous": False,
    },
    {
        "name": "minimize_window",
        "description": "Minimize a window.",
        "parameters": {"ref": "window id (0x...) or title substring"},
        "dangerous": False,
    },
    {
        "name": "maximize_window",
        "description": "Maximize a window.",
        "parameters": {"ref": "window id (0x...) or title substring"},
        "dangerous": False,
    },
    {
        "name": "focus_window",
        "description": "Focus (raise) a window.",
        "parameters": {"ref": "window id (0x...) or title substring"},
        "dangerous": False,
    },
    {
        "name": "close_window",
        "description": "Ask a window to close gracefully (its application may prompt to save).",
        "parameters": {"ref": "window id (0x...) or title substring"},
        "dangerous": True,
    },
    {
        "name": "get_screen_size",
        "description": "Get the screen resolution in pixels.",
        "parameters": {},
        "dangerous": False,
    },
    {
        "name": "screenshot",
        "description": "Capture the screen to a PNG file.",
        "parameters": {"destination": "optional absolute destination path (default: ~/Pictures)"},
        "dangerous": False,
    },
    {
        "name": "launch_app",
        "description": "Launch an application or command in the background.",
        "parameters": {"command": "command line to run, e.g. 'firefox' or 'gnome-terminal'"},
        "dangerous": False,
    },
    {
        "name": "list_processes",
        "description": "List running processes, optionally filtered by name or command.",
        "parameters": {"filter_text": "optional substring to filter by", "limit": "optional max number of results (default 25)"},
        "dangerous": False,
    },
    {
        "name": "terminate_process",
        "description": "Terminate a process by PID.",
        "parameters": {"pid": "process id (integer)", "force": "optional bool, use SIGKILL instead of SIGTERM"},
        "dangerous": True,
    },
    {
        "name": "system_info",
        "description": "Get system stats: CPU count, load average, memory and disk usage.",
        "parameters": {},
        "dangerous": False,
    },
    {
        "name": "read_config",
        "description": "Read a JSON, YAML or INI config file.",
        "parameters": {"path": "config file path"},
        "dangerous": False,
    },
    {
        "name": "edit_config",
        "description": "Edit a JSON/YAML/INI config file. Keys use dot notation for nesting (e.g. 'window.width'). A backup is created first.",
        "parameters": {"path": "config file path", "changes": "object mapping dotted keys to new values"},
        "dangerous": False,
    },
    {
        "name": "backup_config",
        "description": "Create a timestamped backup of a config file.",
        "parameters": {"path": "config file path"},
        "dangerous": False,
    },
    {
        "name": "restore_config",
        "description": "Restore a config file from a backup copy.",
        "parameters": {"path": "config file path", "backup": "backup file path"},
        "dangerous": False,
    },
    {
        "name": "fetch_url",
        "description": "Fetch a URL and return its text content (e.g. for APIs or plain text pages).",
        "parameters": {"url": "http(s) URL"},
        "dangerous": False,
    },
    {
        "name": "browse_page",
        "description": "Open a web page in a browser and extract its title and main text for summarization.",
        "parameters": {"url": "http(s) URL"},
        "dangerous": False,
    },
    {
        "name": "download_file",
        "description": "Download a file from a URL to disk.",
        "parameters": {"url": "http(s) URL", "destination": "optional absolute destination path (default: Downloads folder)"},
        "dangerous": False,
    },
]

TOOL_FUNCTIONS: dict[str, Any] = {
    "list_files": list_files,
    "find_files": find_files,
    "file_info": file_info,
    "list_windows": list_windows,
    "move_window": move_window,
    "resize_window": resize_window,
    "minimize_window": minimize_window,
    "maximize_window": maximize_window,
    "focus_window": focus_window,
    "close_window": close_window,
    "get_screen_size": get_screen_size,
    "screenshot": screenshot,
    "launch_app": launch_app,
    "list_processes": list_processes,
    "terminate_process": terminate_process,
    "system_info": system_info,
    "read_config": read_config,
    "edit_config": edit_config,
    "backup_config": backup_config,
    "restore_config": restore_config,
    "fetch_url": fetch_url,
    "browse_page": browse_page,
    "download_file": download_file,
}

# Safety net: every registered tool must have an implementation, and vice versa.
assert set(TOOL_FUNCTIONS) == {tool["name"] for tool in TOOL_REGISTRY}, (
    "TOOL_REGISTRY and TOOL_FUNCTIONS are out of sync"
)

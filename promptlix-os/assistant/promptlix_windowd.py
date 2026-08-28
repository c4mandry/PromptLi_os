#!/usr/bin/env python3
"""
PromptLix window daemon — keeps a live desktop reference for the AI.

Every 2 seconds it scans the visible windows (via xdotool, so this
requires an X11 session — PromptLix forces X11 for this feature) and
writes a JSONC file:

    ~/.config/promptlix/windows.jsonc

The PromptLix server injects that file into the AI's context so the
model knows which windows are open, where they are, how big they are,
whether they are fullscreen, and which one is focused.
"""

import json
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

WINDOWS_FILE = Path.home() / ".config" / "promptlix" / "windows.jsonc"


def _run(args, timeout=3):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ""


def _xprop(window_id, prop):
    out = _run(["xprop", "-id", window_id, prop])
    return out


def _window_class(window_id):
    # 'WM_CLASS(STRING) = "promptlix", "PromptLix"'
    out = _xprop(window_id, "WM_CLASS")
    try:
        return out.split("=", 1)[1].strip().split(",")[0].strip().strip('"')
    except Exception:
        return ""


def _window_state(window_id):
    out = _xprop(window_id, "_NET_WM_STATE")
    return out


def collect_windows():
    """Return a dict describing the visible desktop, or {"error": ...}."""
    if not shutil.which("xdotool") or not shutil.which("xprop"):
        return {"error": "xdotool/xprop not installed (window tracking unavailable)"}

    screen = _run(["xdotool", "getdisplaygeometry"]).split()
    try:
        screen_w, screen_h = int(screen[0]), int(screen[1])
    except Exception:
        screen_w, screen_h = 1920, 1080

    ids = _run(["xdotool", "search", "--onlyvisible", "--name", ".*"]).split()
    focused = _run(["xdotool", "getactivewindow"])

    windows = []
    for wid in ids:
        name = _run(["xdotool", "getwindowname", wid])
        geom = _run(["xdotool", "getwindowgeometry", "--shell", wid])
        g = {}
        for line in geom.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                g[k.strip()] = v.strip()
        try:
            x = int(g.get("X", 0))
            y = int(g.get("Y", 0))
            w = int(g.get("WIDTH", 0))
            h = int(g.get("HEIGHT", 0))
        except Exception:
            continue
        state = _window_state(wid)
        windows.append({
            "id": wid,
            "name": name,
            "class": _window_class(wid),
            "x": x,
            "y": y,
            "width": w,
            "height": h,
            "fullscreen": "_NET_WM_STATE_FULLSCREEN" in state,
            "focused": wid == focused,
            "on_screen": (x < screen_w and y < screen_h and x + w > 0 and y + h > 0),
        })

    return {
        "updated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "screen": {"width": screen_w, "height": screen_h},
        "windows": windows,
    }


def to_jsonc(data):
    """Serialize the desktop snapshot as JSONC (JSON with comments)."""
    if "error" in data:
        lines = [
            "{",
            '  // Desktop reference unavailable.',
            f'  "error": {json.dumps(data["error"])},',
            f'  "updated_at": {json.dumps(data.get("updated_at", ""))},',
            "}",
        ]
        return "\n".join(lines)

    screen = data["screen"]
    lines = [
        "{",
        "  // Live desktop reference for PromptLix AI.",
        "  // Refreshed every 2 seconds. Coordinates are pixels from the top-left.",
        "  // 'class' is the program, 'focused' marks the active window.",
        f'  "updated_at": {json.dumps(data["updated_at"])},',
        f'  "screen": {{ "width": {screen["width"]}, "height": {screen["height"]} }},',
        '  "windows": [',
    ]
    for i, w in enumerate(data["windows"]):
        comma = "," if i < len(data["windows"]) - 1 else ""
        lines.append(
            "    { "
            f'"id": {json.dumps(w["id"])}, '
            f'"name": {json.dumps(w["name"])}, '
            f'"class": {json.dumps(w["class"])}, '
            f'"x": {w["x"]}, "y": {w["y"]}, '
            f'"width": {w["width"]}, "height": {w["height"]}, '
            f'"fullscreen": {str(w["fullscreen"]).lower()}, '
            f'"focused": {str(w["focused"]).lower()}, '
            f'"on_screen": {str(w["on_screen"]).lower()}'
            " }" + comma
        )
    lines.append("  ]")
    lines.append("}")
    return "\n".join(lines)


def write_snapshot():
    WINDOWS_FILE.parent.mkdir(parents=True, exist_ok=True)
    WINDOWS_FILE.parent.chmod(0o700)
    data = collect_windows()
    text = to_jsonc(data)
    tmp = WINDOWS_FILE.with_suffix(".jsonc.tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(WINDOWS_FILE)
    try:
        WINDOWS_FILE.chmod(0o600)
    except Exception:
        pass


def run_loop(interval=2.0):
    """Refresh the snapshot forever (runs as a daemon thread in the server)."""
    while True:
        try:
            write_snapshot()
        except Exception:
            pass
        time.sleep(interval)


if __name__ == "__main__":
    write_snapshot()
    print("windowd: snapshot written to", WINDOWS_FILE)
    run_loop()

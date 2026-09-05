"""System tray icon (AIDO Phase 2).

Requires the optional "tray" extra (pystray + Pillow, both MIT):
    pip install "aido[tray]"

On Linux, pystray needs a GTK or AppIndicator backend — see the pystray
documentation. Run with: aido --tray
"""

from __future__ import annotations

import threading
from typing import Any

import utils


def _import_tray():
    try:
        import pystray
        from PIL import Image, ImageDraw

        return pystray, Image, ImageDraw
    except ImportError:
        raise utils.AidoError(
            'System tray support needs the "tray" extra: pip install "aido[tray]"'
        ) from None


def _icon_image(Image: Any, ImageDraw: Any) -> Any:
    """Draw a simple robot-face icon in memory."""
    image = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.ellipse((4, 4, 60, 60), fill=(45, 120, 200, 255))
    draw.ellipse((22, 24, 28, 30), fill=(255, 255, 255, 255))
    draw.ellipse((36, 24, 42, 30), fill=(255, 255, 255, 255))
    draw.rectangle((18, 40, 46, 44), fill=(255, 255, 255, 255))
    return image


def run_tray(agent: Any = None, assume_yes: bool = False) -> None:
    """Run the AIDO system-tray icon (blocks until the user chooses Quit)."""
    pystray, Image, ImageDraw = _import_tray()

    import gui

    def open_gui() -> None:
        gui.launch_gui(agent, assume_yes=assume_yes)

    def voice_command() -> None:
        import voice

        try:
            text = voice.listen()
        except utils.AidoError as exc:
            icon.notify(f"⚠️  {exc}", "AIDO")
            return
        icon.notify(f"🎤 {text}", "AIDO")
        result = agent.chat(text, interactive=False, assume_yes=assume_yes)
        icon.notify(f"🤖 {result['answer']}", "AIDO")

    menu = pystray.Menu(
        pystray.MenuItem(
            "Open GUI",
            lambda: threading.Thread(target=open_gui, daemon=True).start(),
        ),
        pystray.MenuItem(
            "Voice command",
            lambda: threading.Thread(target=voice_command, daemon=True).start(),
        ),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Quit", lambda: icon.stop()),
    )
    icon = pystray.Icon("aido", _icon_image(Image, ImageDraw), "AIDO", menu)
    icon.run()

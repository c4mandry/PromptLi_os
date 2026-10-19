"""Session persistence for AIDO — aichat-style.

Sessions are YAML files under ``~/.aido/sessions/<name>.yaml`` with the same
shape aichat uses:

    messages:
      - role: user
        content: ...
      - role: assistant
        content: ...

``load_session`` returns the message list; ``save_session`` writes it back.
Sessions are what make the REPL feel like a real chat client — conversations
survive restarts and can be resumed with `aido -s <name>` / `aido -r`.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

SESSIONS_DIR = Path.home() / ".aido" / "sessions"


def _sessions() -> Path:
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
    return SESSIONS_DIR


def list_sessions() -> list[str]:
    """Session names (sorted), without the .yaml suffix."""
    if not SESSIONS_DIR.is_dir():
        return []
    return sorted(p.stem for p in SESSIONS_DIR.glob("*.yaml"))


def session_path(name: str) -> Path:
    safe = "".join(c for c in name if c.isalnum() or c in "-_.") or "session"
    return _sessions() / f"{safe}.yaml"


def load_session(name: str) -> list[dict[str, str]]:
    """Messages of a saved session, or [] when it does not exist."""
    path = session_path(name)
    if not path.is_file():
        return []
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        messages = data.get("messages") or []
        return [
            {"role": str(m.get("role", "user")), "content": str(m.get("content", ""))}
            for m in messages
            if isinstance(m, dict) and m.get("content")
        ]
    except Exception:
        return []


def save_session(name: str, messages: list[dict[str, str]]) -> Path:
    """Write the conversation to disk (aichat-compatible YAML shape)."""
    path = session_path(name)
    path.parent.mkdir(parents=True, exist_ok=True)
    cleaned: list[dict[str, Any]] = []
    for m in messages:
        role = m.get("role", "user")
        if role in ("system",):
            continue  # system prompts are regenerated from roles, not saved
        cleaned.append({"role": role, "content": m.get("content", "")})
    path.write_text(
        yaml.safe_dump({"messages": cleaned}, sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )
    return path


def last_session() -> str | None:
    """Name of the most recently modified session (for `aido -r`)."""
    sessions = list_sessions()
    if not sessions:
        return None
    return max(sessions, key=lambda n: session_path(n).stat().st_mtime)

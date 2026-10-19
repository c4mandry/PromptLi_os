"""Named roles for AIDO — aichat-style.

A role is a markdown file containing the system prompt. Built-in roles ship
with the package (``/usr/share/aido/roles``); users can add their own under
``~/.aido/roles`` — a user role with the same name shadows a built-in one.

    .role            list available roles
    .role coder      switch to the coder role
    .role            (no name) → built-in agent role
"""

from __future__ import annotations

from pathlib import Path

USER_ROLES_DIR = Path.home() / ".aido" / "roles"
BUILTIN_ROLES_DIR = Path("/usr/share/aido/roles")
# Fallback for source-tree development (repo checkout).
SRC_ROLES_DIR = Path(__file__).resolve().parent.parent / "roles"


def _dirs() -> list[Path]:
    return [USER_ROLES_DIR, BUILTIN_ROLES_DIR, SRC_ROLES_DIR]


def list_roles() -> list[str]:
    """Role names (user roles shadow built-ins with the same name)."""
    seen: dict[str, bool] = {}
    for directory in _dirs():
        if not directory.is_dir():
            continue
        for path in directory.glob("*.md"):
            seen[path.stem] = True
    return sorted(seen)


def load_role(name: str | None) -> str | None:
    """Return the role's markdown text, or None when not found."""
    if not name:
        return None
    for directory in _dirs():
        path = directory / f"{name}.md"
        if path.is_file():
            try:
                return path.read_text(encoding="utf-8")
            except OSError:
                return None
    return None


def create_role(name: str, template: str | None = None) -> Path | None:
    """Create a new user role from a template (default template when None)."""
    safe = "".join(c for c in name if c.isalnum() or c in "-_.") or "role"
    USER_ROLES_DIR.mkdir(parents=True, exist_ok=True)
    path = USER_ROLES_DIR / f"{safe}.md"
    if not path.is_file():
        path.write_text(
            template
            or (
                f"# Role: {safe}\n\n"
                "You are AIDO, a helpful assistant that controls a Linux computer.\n"
                "You can call tools to look at files, run commands and answer questions.\n"
            ),
            encoding="utf-8",
        )
    return path

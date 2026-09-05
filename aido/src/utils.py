"""Shared helpers for AIDO.

Everything in this module is dependency-free (standard library only) so the
tool layer stays importable and testable even when the heavy optional
dependencies (llama-cpp-python, Playwright, requests) are not installed.
"""

from __future__ import annotations

import datetime
import json
import logging
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any

logger = logging.getLogger("aido")

#: Default GGUF model (IBM Granite 4.0 H 1B, Apache-2.0).
MODEL_URL = "https://huggingface.co/ibm-granite/granite-4.0-h-1b-GGUF/resolve/main/granite-4.0-h-1b-Q4_K_M.gguf"


class AidoError(Exception):
    """Fatal-but-expected error whose message is shown directly to the user."""


# ---------------------------------------------------------------------------
# Defaults & configuration
# ---------------------------------------------------------------------------

DEFAULT_CONFIG: dict[str, Any] = {
    "model": {
        "path": "~/.aido/models/granite.gguf",
        "context_size": 2048,
        "max_tokens": 512,
        "temperature": 0.2,
        "top_p": 0.9,
    },
    "agent": {
        "max_tool_iterations": 5,
        "max_history_messages": 12,
    },
    "safety": {
        "confirm_destructive": True,
        "allowed_dirs": ["~"],
        "auto_backup_configs": True,
    },
    "web": {
        "browser_headless": True,
        "download_dir": "~/Downloads",
        "download_timeout": 120,
        "user_agent": "AIDO/0.1.0",
    },
    "logging": {"dir": "~/.aido/logs", "level": "INFO"},
}


def merge_configs(defaults: dict[str, Any], overrides: dict[str, Any]) -> dict[str, Any]:
    """Deep-merge *overrides* into a copy of *defaults* (nested dicts only)."""
    merged = {key: dict(value) if isinstance(value, dict) else value for key, value in defaults.items()}
    for key, value in (overrides or {}).items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = merge_configs(merged[key], value)
        else:
            merged[key] = value
    return merged


def load_config(path: str | None = None) -> dict[str, Any]:
    """Load user configuration from YAML, merged over :data:`DEFAULT_CONFIG`.

    Lookup order: *path* argument, ``$AIDO_CONFIG``, ``./config/aido.yaml``,
    ``~/.aido/aido.yaml``. Missing files are ignored; the result always
    contains every default key.
    """
    candidates: list[str | None] = []
    if path:
        candidates.append(path)
    else:
        candidates += [
            os.environ.get("AIDO_CONFIG"),
            str(Path.cwd() / "config" / "aido.yaml"),
            str(Path.home() / ".aido" / "aido.yaml"),
        ]
    user_config: dict[str, Any] = {}
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            try:
                import yaml  # local import: PyYAML is only needed for config loading
            except ImportError:
                raise AidoError(
                    "PyYAML is required to load the configuration. Run: pip install pyyaml"
                ) from None
            with open(candidate, encoding="utf-8") as fh:
                user_config = yaml.safe_load(fh) or {}
            logger.info("Loaded configuration from %s", candidate)
            break
    return merge_configs(DEFAULT_CONFIG, user_config)


# ---------------------------------------------------------------------------
# Paths & safety
# ---------------------------------------------------------------------------

def expand_path(path: Any) -> Path:
    """Expand ``~`` and environment variables in *path* and resolve it."""
    return Path(os.path.expandvars(os.path.expanduser(str(path)))).resolve()


def restrict_to_allowed(path: Any, allowed_dirs: list[str] | None = None) -> Path:
    """Return the resolved path if it lives inside one of *allowed_dirs*.

    This is the sandbox for file tools: with the default configuration only
    the user's home directory is reachable. Raises :class:`AidoError` when
    the path escapes the allowed directories.
    """
    resolved = expand_path(path)
    if not allowed_dirs:
        return resolved
    for allowed in allowed_dirs:
        root = expand_path(allowed)
        try:
            resolved.relative_to(root)
            return resolved
        except ValueError:
            continue
    raise AidoError(
        f"Access denied: '{path}' is outside the allowed directories: {', '.join(allowed_dirs)}."
    )


def resolve_model_path(explicit: str | None = None, config: dict[str, Any] | None = None) -> Path:
    """Find the GGUF model file to load, in order of precedence:

    *explicit* flag → configured path → first ``*.gguf`` in the default
    model directory. Raises :class:`AidoError` with download instructions
    when nothing is found.
    """
    candidates: list[Path] = []
    if explicit:
        candidates.append(expand_path(explicit))
    configured = (config or {}).get("model", {}).get("path")
    if configured:
        candidates.append(expand_path(configured))
    default_dir = Path(DEFAULT_CONFIG["model"]["path"]).expanduser().parent
    if default_dir.is_dir():
        candidates.extend(sorted(default_dir.glob("*.gguf")))
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise AidoError(
        "No model file found. Download the Granite 1B GGUF (~700MB) first:\n\n"
        f"  mkdir -p {default_dir}\n"
        f"  wget -O {default_dir / 'granite.gguf'} \\\n"
        f"    {MODEL_URL}\n\n"
        "Or run scripts/download_model.sh, or pass --model /path/to/your/model.gguf."
    )


# ---------------------------------------------------------------------------
# Formatting & JSON
# ---------------------------------------------------------------------------

def human_size(num_bytes: int | None) -> str:
    """Format a byte count for humans, e.g. ``2457600`` → ``"2.3MB"``."""
    if num_bytes is None:
        return "unknown"
    size = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(size) < 1024 or unit == "TB":
            return f"{int(size)}B" if unit == "B" else f"{size:.1f}{unit}"
        size /= 1024
    return f"{size:.1f}TB"


def truncate(text: Any, limit: int = 4000) -> str:
    """Truncate *text* to *limit* characters, noting when it was cut."""
    text = str(text)
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n… (truncated, {len(text)} characters total)"


def timestamp() -> str:
    """Return a compact timestamp used for config backups."""
    return datetime.datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")


def repair_json(text: str) -> str:
    """Apply best-effort repairs for the JSON mistakes small models make.

    Handles trailing commas, unquoted keys, single-quoted strings and
    unterminated containers. The result may still be invalid — callers must
    catch :class:`json.JSONDecodeError`.
    """
    text = text.strip()
    # Trailing commas before } or ]
    text = re.sub(r",(\s*[}\]])", r"\1", text)
    # Unquoted keys: {"key": ...} or {key: ...}
    text = re.sub(r'([{,]\s*)([A-Za-z_][\w.-]*)(\s*:)', r'\1"\2"\3', text)
    # Single-quoted keys and values
    text = re.sub(r"([{,]\s*)'([^']*)'(\s*:)", r'\1"\2"\3', text)
    text = re.sub(r"(:\s*)'([^']*)'", r'\1"\2"', text)
    # Close unterminated containers
    for open_ch, close_ch in (("{", "}"), ("[", "]")):
        missing = text.count(open_ch) - text.count(close_ch)
        if missing > 0:
            text += close_ch * missing
    return text


def extract_json(text: str | None) -> dict[str, Any] | None:
    """Extract the first JSON object from model output, repairing if needed.

    Returns ``None`` when no object could be recovered — callers should then
    treat the raw text as a plain-language answer.
    """
    if not text:
        return None
    text = re.sub(r"^```(?:json)?\s*", "", text.strip(), flags=re.IGNORECASE)
    text = re.sub(r"\s*```\s*$", "", text)
    start = text.find("{")
    if start == -1:
        return None
    end = text.rfind("}")
    if end <= start:
        # No closing brace at all — hand the remainder to repair_json, which
        # balances unterminated containers.
        raw = text[start:]
    else:
        raw = text[start : end + 1]
    candidates = [raw]
    repaired = repair_json(raw)
    if repaired != raw:
        candidates.append(repaired)
    for candidate in candidates:
        try:
            value = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            return value
    return None


# ---------------------------------------------------------------------------
# Processes, confirmation & logging
# ---------------------------------------------------------------------------

def run_command(command: Any, timeout: int = 30, check: bool = True) -> subprocess.CompletedProcess:
    """Run a shell command (string or list) and return the CompletedProcess.

    Raises :class:`AidoError` with a friendly message when the command is
    missing, times out, or exits non-zero.
    """
    args = shlex.split(command) if isinstance(command, str) else list(command)
    try:
        proc = subprocess.run(
            args, capture_output=True, text=True, timeout=timeout, check=False
        )
    except FileNotFoundError:
        raise AidoError(
            f"Required command not found: '{args[0]}'. Please install it and try again."
        ) from None
    except subprocess.TimeoutExpired:
        raise AidoError(f"Command timed out after {timeout}s: {' '.join(args)}") from None
    if check and proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise AidoError(f"Command failed ({proc.returncode}): {detail or ' '.join(args)}")
    return proc


def ask_confirmation(prompt: str, assume_yes: bool = False, interactive: bool | None = None) -> bool:
    """Confirm a risky action.

    Returns ``True`` immediately when *assume_yes* is set, and ``False`` in
    non-interactive contexts (piped stdin, scripts) unless *assume_yes* was
    given explicitly.
    """
    if assume_yes:
        return True
    if interactive is None:
        interactive = sys.stdin.isatty()
    if not interactive:
        return False
    try:
        answer = input(f"{prompt} [y/N] ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        return False
    return answer in ("y", "yes")


def setup_logging(log_dir: str | None = None, level: str = "INFO") -> Path:
    """Configure the audit log file and return its path.

    Every tool call and agent action is written there, giving users an audit
    trail of everything AIDO did (see the security section of the README).
    """
    directory = Path(log_dir).expanduser() if log_dir else Path(DEFAULT_CONFIG["logging"]["dir"]).expanduser()
    directory.mkdir(parents=True, exist_ok=True)
    log_file = directory / "aido.log"
    handler = logging.FileHandler(log_file, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)-7s %(name)s: %(message)s"))
    aido_logger = logging.getLogger("aido")
    aido_logger.setLevel(getattr(logging, str(level).upper(), logging.INFO))
    if not any(isinstance(h, logging.FileHandler) for h in aido_logger.handlers):
        aido_logger.addHandler(handler)
    return log_file

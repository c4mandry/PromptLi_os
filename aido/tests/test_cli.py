"""Smoke tests for the CLI entry point (no model or optional deps needed).

AIDO is terminal-only: the GUI/tray/voice flags are gone, and running bare
``aido`` opens the full-screen chat TUI (falling back to the line REPL when
no tty is available).
"""

import sys
from pathlib import Path

import aido


class FakeAgent:
    """Stand-in for the model-backed Agent used by the CLI."""

    def __init__(self, **kwargs):
        pass

    def close(self):
        pass


def _patch_cli_env(monkeypatch):
    """Point the CLI at fakes so it reaches the dispatch logic without a model."""
    monkeypatch.setattr(aido.utils, "setup_logging", lambda **kwargs: Path("fake.log"))
    monkeypatch.setattr(aido.utils, "resolve_model_path", lambda **kwargs: Path("fake.gguf"))
    monkeypatch.setattr(aido, "Agent", FakeAgent)


def test_bare_aido_opens_repl(monkeypatch):
    """Running `aido` with no arguments starts the aichat-style REPL."""
    _patch_cli_env(monkeypatch)
    import repl as repl_mod

    monkeypatch.setattr(repl_mod, "run_repl", lambda *a, **k: 0)
    assert aido.main([]) == 0


def test_aido_tui_subcommand(monkeypatch):
    """`aido tui` still routes to the classic curses TUI."""
    _patch_cli_env(monkeypatch)
    monkeypatch.setattr(aido, "_run_tui", lambda *a, **k: 0)
    assert aido.main(["tui"]) == 0


def test_help_flag_prints_help(capsys):
    import pytest as _pytest

    # argparse prints help and raises SystemExit(0) — standard behavior.
    try:
        aido.main(["--help"])
    except SystemExit as exc:
        assert exc.code == 0
    out = capsys.readouterr().out
    assert "usage: aido" in out


def test_list_tools(capsys):
    assert aido.main(["--list-tools"]) == 0
    out = capsys.readouterr().out
    assert "list_files" in out
    assert "screenshot" in out


def test_tools_subcommand(capsys):
    assert aido.main(["tools"]) == 0
    out = capsys.readouterr().out
    assert "list_files" in out


def test_one_shot(monkeypatch, capsys):
    """`aido "question"` runs the agent once and prints the answer."""
    _patch_cli_env(monkeypatch)

    class AnsweringAgent(FakeAgent):
        def chat(self, *args, **kwargs):
            return {"tool_calls": [], "answer": "hello from aido"}

    monkeypatch.setattr(aido, "Agent", AnsweringAgent)
    assert aido.main(["what is up"]) == 0
    assert "hello from aido" in capsys.readouterr().out


def test_chat_without_model_is_friendly(monkeypatch, capsys):
    """Missing model → friendly error + `aido setup` tip, not a traceback."""
    monkeypatch.setattr(aido.utils, "setup_logging", lambda **kwargs: Path("fake.log"))

    def raise_missing(**kwargs):
        raise aido.utils.AidoError("No model file found.")

    monkeypatch.setattr(aido.utils, "resolve_model_path", raise_missing)
    assert aido.main(["chat"]) == 1
    captured = capsys.readouterr()
    assert "No model file found" in captured.err
    assert "aido setup" in captured.out


def test_setup_without_network_fails_cleanly(monkeypatch, capsys):
    """`aido setup` fails with a clean error when pip is unavailable."""

    import subprocess

    class Boom:
        def __init__(self, *a, **kw):
            pass

        def __call__(self, *a, **kw):
            raise subprocess.CalledProcessError(1, "pip")

    monkeypatch.setattr(subprocess, "run", Boom())
    assert aido.main(["setup"]) == 1
    assert "llama-cpp-python install failed" in capsys.readouterr().err

"""Smoke tests for the CLI entry point (no model or optional deps needed)."""

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


def test_list_tools(capsys):
    assert aido.main(["--list-tools"]) == 0
    out = capsys.readouterr().out
    assert "list_files" in out
    assert "screenshot" in out


def test_gui_without_tkinter(monkeypatch, capsys):
    _patch_cli_env(monkeypatch)
    monkeypatch.setitem(sys.modules, "tkinter", None)
    assert aido.main(["--gui"]) == 1
    assert "Tkinter" in capsys.readouterr().err


def test_voice_without_speech_recognition(monkeypatch, capsys):
    _patch_cli_env(monkeypatch)
    monkeypatch.setitem(sys.modules, "speech_recognition", None)
    assert aido.main(["hello", "--voice"]) == 1
    assert "voice" in capsys.readouterr().err

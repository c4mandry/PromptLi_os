"""Unit tests for the Tkinter GUI (no display needed)."""

import sys

import pytest

import gui
import utils


def test_missing_tkinter_raises(monkeypatch):
    monkeypatch.setitem(sys.modules, "tkinter", None)
    with pytest.raises(utils.AidoError, match="Tkinter"):
        gui.launch_gui(agent=None)

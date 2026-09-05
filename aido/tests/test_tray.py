"""Unit tests for the system tray module (no display needed)."""

import sys

import pytest

import tray
import utils


def test_missing_pystray_raises(monkeypatch):
    monkeypatch.setitem(sys.modules, "pystray", None)
    with pytest.raises(utils.AidoError, match="tray"):
        tray.run_tray(agent=None)

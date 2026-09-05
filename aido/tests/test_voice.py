"""Unit tests for the voice input module (no microphone needed)."""

import sys

import pytest

import utils
import voice


def test_unknown_engine_raises():
    with pytest.raises(utils.AidoError, match="Unknown voice engine"):
        voice.listen(engine="telepathy")


def test_missing_speech_recognition(monkeypatch):
    monkeypatch.setitem(sys.modules, "speech_recognition", None)
    with pytest.raises(utils.AidoError, match='extra'):
        voice.listen(engine="sphinx")

"""Voice input helpers (AIDO Phase 2).

Uses SpeechRecognition (MIT). The default engine is PocketSphinx, which
transcribes fully offline to preserve AIDO's privacy guarantees. The
``google`` engine is available as an explicit opt-in but sends audio to
Google's speech API — it is off by default.

Install with: pip install "aido[voice]"
"""

from __future__ import annotations

import utils

ENGINES = ("sphinx", "google")
DEFAULT_LANGUAGE = "en-US"


def _import_sr():
    try:
        import speech_recognition as sr
    except ImportError:
        raise utils.AidoError(
            'Voice control needs the "voice" extra: pip install "aido[voice]"'
        ) from None
    return sr


def listen(timeout: int = 5, engine: str = "sphinx", language: str = DEFAULT_LANGUAGE) -> str:
    """Capture one utterance from the microphone and return its transcription.

    *engine* ``"sphinx"`` (default) transcribes offline; ``"google"`` uses
    Google's cloud API and requires network access.
    """
    if engine not in ENGINES:
        raise utils.AidoError(f"Unknown voice engine '{engine}'. Choose from: {', '.join(ENGINES)}.")
    sr = _import_sr()
    recognizer = sr.Recognizer()
    try:
        with sr.Microphone() as source:
            recognizer.adjust_for_ambient_noise(source, duration=0.5)
            audio = recognizer.listen(source, timeout=timeout, phrase_time_limit=10)
    except OSError as exc:
        raise utils.AidoError(f"No microphone available: {exc}") from None
    if engine == "sphinx":
        try:
            __import__("pocketsphinx")  # availability check for a helpful error
        except ImportError:
            raise utils.AidoError(
                "The sphinx engine needs pocketsphinx: pip install pocketsphinx"
            ) from None
    try:
        if engine == "sphinx":
            text = recognizer.recognize_sphinx(audio, language=language)
        else:
            text = recognizer.recognize_google(audio, language=language)
    except sr.UnknownValueError:
        raise utils.AidoError("Could not understand the audio — please try again.") from None
    except sr.RequestError as exc:
        raise utils.AidoError(f"Speech recognition failed: {exc}") from None
    return text.strip()

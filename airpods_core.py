"""Gemini speech for AirPods Approvals: the only part of the plugin that runs beside Hermes.

Approvals and gestures never pass through here. This turns one sentence into WAV audio, using a key
read through Hermes' secret scope. The key stays in this process; the client only receives audio.
"""

from __future__ import annotations

import base64
import json
import logging
import urllib.error
import urllib.request
from collections import OrderedDict
from typing import Any

logger = logging.getLogger(__name__)

PLUGIN_ID = "airpods-approvals"
VERSION = "1.0.0"
API_BASE = "https://generativelanguage.googleapis.com/v1beta"
KEY_ENV_NAMES = ("AIRPODS_APPROVALS_GEMINI_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY", "GEMINI_LIVE_API_KEY")
MODELS = ("gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts")
VOICES = ("Kore", "Puck", "Charon", "Fenrir", "Aoede", "Leda", "Orus", "Zephyr", "Laomedeia", "Sulafat")
DEFAULT_SETTINGS = {"tts_model": MODELS[0], "voice": VOICES[0]}
MAX_TEXT = 700
HTTP_TIMEOUT = 20
CACHE_SIZE = 16

_cache: OrderedDict[tuple[str, str, str], str] = OrderedDict()


class SpeechError(Exception):
    """A failure safe to show: it never contains the key."""

    def __init__(self, message: str, status: int = 502):
        super().__init__(message)
        self.status = status


def load_settings() -> dict[str, str]:
    raw: dict[str, Any] = {}
    try:
        from hermes_cli.config import load_config_readonly

        config = load_config_readonly() or {}
        raw = (((config.get("plugins") or {}).get("entries") or {}).get(PLUGIN_ID) or {}).get("settings") or {}
    except Exception as exc:
        logger.debug("airpods-approvals: settings unreadable, using defaults (%s)", type(exc).__name__)
    settings = dict(DEFAULT_SETTINGS)
    if raw.get("tts_model") in MODELS:
        settings["tts_model"] = raw["tts_model"]
    if raw.get("voice") in VOICES:
        settings["voice"] = raw["voice"]
    return settings


def resolve_api_key() -> tuple[str, str]:
    """``(key, env_name)`` for the active profile, or ``("", "")``. Never logged."""
    from agent.secret_scope import get_secret

    for name in KEY_ENV_NAMES:
        try:
            value = (get_secret(name) or "").strip()
        except Exception as exc:
            logger.debug("airpods-approvals: secret %s unreadable (%s)", name, type(exc).__name__)
            value = ""
        if value:
            return value, name
    return "", ""


def status() -> dict[str, Any]:
    key, source = resolve_api_key()
    settings = load_settings()
    return {"version": VERSION, "ready": bool(key), "key_source": source, "model": settings["tts_model"], "voice": settings["voice"]}


def _post(url: str, key: str, body: dict[str, Any]) -> dict[str, Any]:
    request = urllib.request.Request(
        url, data=json.dumps(body).encode("utf-8"), headers={"x-goog-api-key": key, "Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        raise SpeechError(f"Gemini returned {exc.code}", exc.code if 400 <= exc.code < 600 else 502) from None
    except (urllib.error.URLError, TimeoutError, ValueError) as exc:
        raise SpeechError(f"Could not reach Gemini ({type(exc).__name__})") from None


def speak(text: str) -> dict[str, str]:
    """Return ``{"audio": <base64 WAV>, "mime": ...}`` for one sentence."""
    text = " ".join(str(text or "").split())
    if not text:
        raise SpeechError("Nothing to say", 400)
    if len(text) > MAX_TEXT:
        raise SpeechError("Text too long", 413)

    key, _ = resolve_api_key()
    if not key:
        raise SpeechError("No Gemini API key", 503)

    settings = load_settings()
    entry = (settings["tts_model"], settings["voice"], text)
    if entry in _cache:
        _cache.move_to_end(entry)
        return {"audio": _cache[entry], "mime": "audio/wav"}

    reply = _post(
        f"{API_BASE}/models/{settings['tts_model']}:generateContent",
        key,
        {
            "contents": [{"parts": [{"text": text}]}],
            "generationConfig": {
                "responseModalities": ["AUDIO"],
                "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": settings["voice"]}}},
            },
        },
    )
    for candidate in reply.get("candidates") or []:
        for part in (candidate.get("content") or {}).get("parts") or []:
            inline = part.get("inlineData") or {}
            data = inline.get("data")
            if not data:
                continue
            # The player needs a real WAV file. Anything else falls back to the Mac's voice.
            if base64.b64decode(data[:8] + "==")[:4] != b"RIFF":
                raise SpeechError("Gemini did not return WAV audio")
            _cache[entry] = data
            while len(_cache) > CACHE_SIZE:
                _cache.popitem(last=False)
            return {"audio": data, "mime": "audio/wav"}
    raise SpeechError("Gemini returned no audio")

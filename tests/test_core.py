"""Backend tests. Run by scripts/test.sh with Hermes' interpreter; no network calls."""

from __future__ import annotations

import base64
import importlib.util
import io
import json
import os
import sys
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.environ["AGENT_ROOT"])
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("airpods_core_under_test", ROOT / "airpods_core.py")
core = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = core
spec.loader.exec_module(core)

WAV = base64.b64encode(b"RIFF" + b"\0" * 40).decode()
SECRET = "test-value-not-a-real-key"


def reply(data):
    payload = {"candidates": [{"content": {"parts": [{"inlineData": {"mimeType": "audio/wav", "data": data}}]}}]}
    return io.BytesIO(json.dumps(payload).encode())


class Speak(unittest.TestCase):
    def setUp(self):
        core._cache.clear()
        patcher = mock.patch.object(core, "resolve_api_key", return_value=(SECRET, "GEMINI_API_KEY"))
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_returns_wav(self):
        with mock.patch("urllib.request.urlopen", return_value=reply(WAV)):
            self.assertEqual(core.speak("Hello there")["audio"], WAV)

    def test_key_goes_in_a_header_not_the_url(self):
        with mock.patch("urllib.request.urlopen", return_value=reply(WAV)) as call:
            core.speak("Hello")
        request = call.call_args[0][0]
        self.assertNotIn(SECRET, request.full_url)
        self.assertEqual(request.get_header("X-goog-api-key"), SECRET)

    def test_repeated_text_makes_one_call(self):
        with mock.patch("urllib.request.urlopen", side_effect=lambda *a, **k: reply(WAV)) as call:
            core.speak("Same line")
            core.speak("Same line")
        self.assertEqual(call.call_count, 1)

    def test_rejects_empty_and_long_text(self):
        with self.assertRaises(core.SpeechError):
            core.speak("   ")
        with self.assertRaises(core.SpeechError):
            core.speak("x" * (core.MAX_TEXT + 1))

    def test_non_wav_audio_is_refused(self):
        raw = base64.b64encode(b"\0" * 40).decode()
        with mock.patch("urllib.request.urlopen", return_value=reply(raw)):
            with self.assertRaises(core.SpeechError):
                core.speak("Hello")

    def test_errors_never_contain_the_key(self):
        failure = urllib.error.HTTPError("u", 429, "quota", {}, io.BytesIO(SECRET.encode()))
        self.addCleanup(failure.close)
        with mock.patch("urllib.request.urlopen", side_effect=failure):
            with self.assertRaises(core.SpeechError) as caught:
                core.speak("Hello")
        self.assertNotIn(SECRET, str(caught.exception))
        self.assertEqual(caught.exception.status, 429)


class NoKey(unittest.TestCase):
    def test_no_key_is_a_clean_failure(self):
        with mock.patch.object(core, "resolve_api_key", return_value=("", "")):
            core._cache.clear()
            with self.assertRaises(core.SpeechError) as caught:
                core.speak("Hello")
            self.assertEqual(caught.exception.status, 503)
            self.assertFalse(core.status()["ready"])


class Manifest(unittest.TestCase):
    def test_versions_agree(self):
        plugin = (ROOT / "plugin.yaml").read_text()
        dashboard = json.loads((ROOT / "dashboard" / "manifest.json").read_text())
        self.assertIn(f"\nversion: {core.VERSION}\n", plugin)
        self.assertEqual(dashboard["version"], core.VERSION)
        self.assertIn(f"choices: [{', '.join(core.MODELS)}]", plugin)
        self.assertIn(f"choices: [{', '.join(core.VOICES)}]", plugin)


if __name__ == "__main__":
    unittest.main(verbosity=1)

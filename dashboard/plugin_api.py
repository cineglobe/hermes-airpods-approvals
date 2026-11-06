"""AirPods Approvals routes, mounted at ``/api/plugins/airpods-approvals/``.

Two routes for optional Gemini speech. Neither can answer an approval.
"""

from __future__ import annotations

import asyncio
import importlib.util
import sys
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

_CORE_PATH = Path(__file__).resolve().parent.parent / "airpods_core.py"
_CORE_NAME = "hermes_airpods_approvals_core"


def _core():
    module = sys.modules.get(_CORE_NAME)
    if module is not None and getattr(module, "__file__", None) == str(_CORE_PATH):
        return module
    spec = importlib.util.spec_from_file_location(_CORE_NAME, _CORE_PATH)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {_CORE_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[_CORE_NAME] = module
    spec.loader.exec_module(module)
    return module


router = APIRouter()


class SpeakRequest(BaseModel):
    text: str


@router.get("/status")
async def get_status() -> dict[str, Any]:
    return await asyncio.to_thread(_core().status)


@router.post("/speak")
async def post_speak(body: SpeakRequest) -> dict[str, str]:
    core = _core()
    try:
        return await asyncio.to_thread(core.speak, body.text)
    except core.SpeechError as exc:
        raise HTTPException(status_code=exc.status, detail=str(exc)) from None

#!/usr/bin/env python3
"""Generate desktop/plugin.js from src/ (no Node toolchain needed).

    python3 scripts/build.py          # write desktop/plugin.js
    python3 scripts/build.py --check  # exit 1 if it is stale

The Desktop loader takes one uncompiled ESM file, so the engine and styles are inlined. The output
stays plain, readable source.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGET = ROOT / "desktop" / "plugin.js"


def output() -> str:
    source = (ROOT / "src" / "desktop.js").read_text(encoding="utf-8")
    engine = (ROOT / "src" / "engine.mjs").read_text(encoding="utf-8")
    css = (ROOT / "src" / "ui.css").read_text(encoding="utf-8")
    assert "/*@ENGINE@*/" in source and "/*@CSS@*/ ''" in source, "placeholders missing"
    engine = re.sub(r"^export ", "", engine, flags=re.M).rstrip() + "\n"
    return source.replace("/*@ENGINE@*/\n", engine).replace("/*@CSS@*/ ''", json.dumps(css))


def main() -> int:
    content = output()
    current = TARGET.read_text(encoding="utf-8") if TARGET.exists() else None
    if current == content:
        return 0
    if "--check" in sys.argv[1:]:
        print("desktop/plugin.js is stale; run python3 scripts/build.py")
        return 1
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    TARGET.write_text(content, encoding="utf-8")
    print("wrote desktop/plugin.js")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

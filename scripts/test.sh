#!/usr/bin/env bash
# Run every test. Nothing here starts Hermes or makes a network call.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

python3 "$here/scripts/build.py" --check
node "$here/tests/engine.test.mjs"

if [[ "$(uname)" == "Darwin" ]]; then
  swift test --package-path "$here/desktop/helper" --scratch-path "${TMPDIR:-/tmp}/hermes-airpods-build-test"
fi

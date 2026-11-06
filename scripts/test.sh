#!/usr/bin/env bash
# Run every test. Python runs with Hermes' own interpreter and import path, so the real
# agent.secret_scope is used. It never starts a Hermes server and makes no network calls.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

python3 "$here/scripts/build.py" --check
node "$here/tests/engine.test.mjs"

if command -v hermes >/dev/null; then
  cmd_json="$(hermes --print-runtime-command)"
  python="$(printf '%s' "$cmd_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])')"
  agent_root="$(printf '%s' "$cmd_json" | python3 -c 'import json,re,sys; print(re.search(r"sys.path.insert\(0, .([^\x27]+)", json.load(sys.stdin)[-1]).group(1))')"
  env -u AIRPODS_APPROVALS_GEMINI_KEY -u GEMINI_LIVE_API_KEY -u GEMINI_API_KEY -u GOOGLE_API_KEY \
    AGENT_ROOT="$agent_root" "$python" -I "$here/tests/test_core.py"
fi

if [[ "$(uname)" == "Darwin" ]]; then
  swift test --package-path "$here/helper" --scratch-path "${TMPDIR:-/tmp}/hermes-airpods-build-test"
fi

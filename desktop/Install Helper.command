#!/usr/bin/env bash
# Opened by Install in Settings > Plugins > AirPods Approvals.
#
# Head tracking needs a small Mac app, because only a real app can read AirPods motion. This builds
# it on this Mac from the Swift source in helper/ next to this script, then starts it. Nothing is
# downloaded, and the app is signed for this Mac only, so it needs no notarisation.
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
app="$HOME/Applications/Hermes AirPods.app"

echo "AirPods Approvals: building the helper app from source."
echo "Source: $root/helper"
echo "Read it online: https://github.com/cineglobe/hermes-airpods-approvals/tree/v1.2.0/desktop/helper"
echo

# Swift comes with Apple's Command Line Tools. If they're missing, macOS offers to install them.
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Apple's Command Line Tools are needed to build it. macOS will now offer to install them."
  echo "When that finishes, press Install in Hermes again."
  xcode-select --install || true
  exit 1
fi

"$root/install-helper.sh"
open "$app"

echo
echo "Done. The helper is running and Hermes connects to it by itself. You can close this window."

#!/usr/bin/env bash
# Build the Mac helper from the source in helper/ next to this script and install it. Nothing is downloaded.
#
#   desktop/install-helper.sh   (Install in the plugin's settings runs it for you)
#
# macOS only allows head motion for a real app bundle started by Launch Services, so this builds a
# small .app rather than a command-line tool. It needs the Xcode Command Line Tools.
set -euo pipefail

name="Hermes AirPods"
app="$HOME/Applications/$name.app"
root="$(cd "$(dirname "$0")" && pwd)"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "The helper runs on the Mac your AirPods connect to." >&2
  exit 1
fi

command -v swift >/dev/null || { echo "Swift not found. Run: xcode-select --install" >&2; exit 1; }

# Built outside the plugin folder, so no compiled files ever sit inside it.
build="${TMPDIR:-/tmp}/hermes-airpods-build"
swift build --package-path "$root/helper" --scratch-path "$build" -c release
binary="$(swift build --package-path "$root/helper" --scratch-path "$build" -c release --show-bin-path)/HermesAirPods"

pkill -x HermesAirPods || true
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/HermesAirPods"
cp "$root/helper/Info.plist" "$app/Contents/Info.plist"
# Signed for this Mac only. macOS asks for Motion access again after a rebuild.
codesign --force --sign - "$app"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "Installed $app"

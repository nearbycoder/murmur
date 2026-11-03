#!/usr/bin/env bash
# Captures the main window in demo mode (sample transfers, no network) for the README and website.
#   ./Scripts/shoot.sh <scene> <output.png> [light|dark]
#   scenes: overview, files, peers, trackers, noselect, empty, settings-general|transfers|network
#   WIDTH=940 HEIGHT=1100 change the window size.
set -euo pipefail
cd "$(dirname "$0")/.."
SCENE="$1" OUT="$2" APPEARANCE="${3:-}"
APP="build/DerivedData/Build/Products/Debug/Murmur.app"
INFO="$(mktemp)"
rm -f "$INFO"
# Launching through LaunchServices makes Murmur the active app, so the window isn't drawn dimmed.
open -n -W "$APP" --args -demo YES -demoScene "$SCENE" -demoWindowFile "$INFO" ${APPEARANCE:+-demoAppearance "$APPEARANCE"} ${WIDTH:+-demoWindowWidth "$WIDTH"} ${HEIGHT:+-demoWindowHeight "$HEIGHT"} -AppleLanguages '(en)' &
OPENER=$!
trap 'pkill -f "Murmur.app/Contents/MacOS/Murmur -demo" || true; rm -f "$INFO"' EXIT
for _ in $(seq 1 150); do
  [[ -s "$INFO" ]] && break
  sleep 0.1
done
WINDOW="$(cat "$INFO" 2>/dev/null || true)"
[[ -n "$WINDOW" ]] || { echo "Murmur didn't report a window"; exit 1; }
sleep "${SETTLE:-2.5}" # let SwiftUI animations and glass settle
screencapture -x -o -l "$WINDOW" "$OUT"
echo "✓ $OUT"

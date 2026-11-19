#!/bin/bash
# Builds Chat Nudge.app. `./build.sh install` also copies it to ~/Applications
# and (re)starts it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Chat Nudge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
  -o "$APP/Contents/MacOS/ChatNudge" ChatNudge.swift
cp Info.plist "$APP/Contents/Info.plist"

# App icon, drawn by make-icon.swift.
if [ ! -f build/AppIcon.icns ]; then
  swift make-icon.swift build/icon/icon_1024.png
  SET=build/AppIcon.iconset
  rm -rf "$SET"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon/icon_1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon/icon_1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
  mkdir -p "$HOME/Applications"
  pkill -x ChatNudge 2>/dev/null || true
  sleep 0.5
  rm -rf "$HOME/Applications/Chat Nudge.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/Chat Nudge.app"
  echo "Installed to ~/Applications/Chat Nudge.app and started it"
fi

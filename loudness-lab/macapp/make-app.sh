#!/bin/sh
#
# Assemble LoudnessLab.app from the package executable.
#
# `swift run` is fine for seeing a change, but it leaves you with a process
# rather than an application: nothing to double-click, nothing in the Dock,
# and no identity for macOS to hang file-access permissions on. A folder
# with an Info.plist in it is all a Mac app actually is, so this makes one.
#
# Usage:  sh macapp/make-app.sh [--open]
set -eu

cd "$(dirname "$0")"

VERSION="0.1.0"
APP="LoudnessLab.app"

echo "Building release…"
swift build -c release --product LoudnessLabUI
BIN="$(swift build -c release --show-bin-path)/LoudnessLabUI"
[ -x "$BIN" ] || { echo "no executable at $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LoudnessLab"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Loudness Lab</string>
    <key>CFBundleDisplayName</key>       <string>Loudness Lab</string>
    <key>CFBundleExecutable</key>        <string>LoudnessLab</string>
    <key>CFBundleIdentifier</key>        <string>uk.loudnesslab.app</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <!-- Not an agent: this owns a window and belongs in the Dock. -->
    <key>LSUIElement</key>               <false/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Not for distribution -- it gives the bundle a stable
# identity on this machine, so macOS remembers any folder access granted to
# it instead of asking again after every rebuild.
codesign --force --sign - "$APP" >/dev/null 2>&1 \
    || echo "note: could not sign (the app still runs)"

echo "Built $(pwd)/$APP"
if [ "${1:-}" = "--open" ]; then open "$APP"; fi

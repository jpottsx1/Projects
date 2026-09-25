#!/bin/sh
#
# Assemble LoudnessLab.app from the package executable.
#
# `swift run` is fine for seeing a change, but it leaves you with a process
# rather than an application: nothing to double-click, nothing in the Dock,
# and no identity for macOS to hang file-access permissions on. A folder
# with an Info.plist in it is all a Mac app actually is, so this makes one.
#
# Usage:  sh macapp/make-app.sh [--debug] [--open]
#
# `--debug` builds the Debug configuration instead of Release. Xcode's own
# Run button needs this: it wants the icon and the identity a bundle gives
# it too, and re-optimizing at -O on every keystroke-to-Cmd-R loop would
# make that the slow way to see a change rather than the fast one.
set -eu

cd "$(dirname "$0")"

VERSION="0.1.0"
APP="LoudnessLab.app"
CONFIG="release"
if [ "${1:-}" = "--debug" ]; then CONFIG="debug"; shift; fi

echo "Building ${CONFIG}…"
swift build -c "$CONFIG" --product LoudnessLabApp
BIN="$(swift build -c "$CONFIG" --show-bin-path)/LoudnessLabApp"
[ -x "$BIN" ] || { echo "no executable at $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LoudnessLab"

# SwiftUI's Bundle.module looks for this next to the binary's .app --
# Contents/Resources -- when the package is linked into an app. Without
# it here, Bundle.module fatalErrors the moment the app reaches for the
# splash image.
BIN_DIR="$(dirname "$BIN")"
RESOURCE_BUNDLE="$BIN_DIR/LoudnessLab_LoudnessLabUI.bundle"
[ -d "$RESOURCE_BUNDLE" ] && cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"

# --- icon -------------------------------------------------------------
# A .icns built from whatever square image is sitting here. macOS ships
# both tools needed (sips and iconutil), so there is nothing to install
# and nothing to check in but the artwork itself.
ICON_SOURCE=""
for candidate in Icon.png Icon.jpg Icon.jpeg Icon.tiff; do
    if [ -f "$candidate" ]; then ICON_SOURCE="$candidate"; break; fi
done

ICON_ENTRY=""
if [ -n "$ICON_SOURCE" ]; then
    WIDTH=$(sips -g pixelWidth "$ICON_SOURCE" | awk '/pixelWidth/ {print $2}')
    HEIGHT=$(sips -g pixelHeight "$ICON_SOURCE" | awk '/pixelHeight/ {print $2}')
    if [ "$WIDTH" != "$HEIGHT" ]; then
        echo "note: $ICON_SOURCE is ${WIDTH}x${HEIGHT}, not square."
        echo "      It will be squashed to fit. Crop it square for a clean icon."
    fi
    if [ "$WIDTH" -lt 512 ] 2>/dev/null; then
        echo "note: $ICON_SOURCE is only ${WIDTH}px wide; 1024 gives the"
        echo "      sharpest result on a Retina display."
    fi

    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    # Exactly the sizes iconutil expects -- it refuses a set with anything
    # else in it.
    for size in 16 32 128 256 512; do
        sips -s format png -z "$size" "$size" "$ICON_SOURCE"              --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
        sips -s format png -z "$((size * 2))" "$((size * 2))" "$ICON_SOURCE"              --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
    done
    if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
        ICON_ENTRY='    <key>CFBundleIconFile</key>          <string>AppIcon</string>'
        echo "  icon from $ICON_SOURCE"
    else
        echo "note: could not build an icon from $ICON_SOURCE; carrying on."
    fi
else
    echo "note: no icon. Put a square Icon.png (or .jpeg) in macapp/ to add one."
fi

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
$ICON_ENTRY
</dict>
</plist>
PLIST

# Ad-hoc signature. Not for distribution -- it gives the bundle a stable
# identity on this machine, so macOS remembers any folder access granted to
# it instead of asking again after every rebuild.
codesign --force --sign - "$APP" >/dev/null 2>&1 \
    || echo "note: could not sign (the app still runs)"

# The Dock caches icons by path, so a rebuild with new artwork will often
# keep showing the old one. Touching the bundle is the usual nudge.
touch "$APP"

echo "Built $(pwd)/$APP"
if [ "${1:-}" = "--open" ]; then open "$APP"; fi

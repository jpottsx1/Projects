#!/bin/sh
# Makes every app icon size from one square PNG (1024x1024 or larger is best)
# and puts them in Stash/Assets.xcassets/AppIcon.appiconset.
# Usage: Scripts/set-app-icon.sh /path/to/icon.png   (macOS only; uses sips)
set -e
src="$1"
if [ -z "$src" ] || [ ! -f "$src" ]; then
  echo "Usage: $0 /path/to/icon.png" >&2
  exit 1
fi
dir="$(cd "$(dirname "$0")/.." && pwd)/Stash/Assets.xcassets/AppIcon.appiconset"

w=$(sips -g pixelWidth "$src" | awk '/pixelWidth/ {print $2}')
h=$(sips -g pixelHeight "$src" | awk '/pixelHeight/ {print $2}')
if [ "$w" != "$h" ]; then
  echo "The image is ${w}x${h}; it needs to be square." >&2
  exit 1
fi
if [ "$w" -lt 1024 ]; then
  echo "Warning: the image is ${w}x${h}; 1024x1024 or larger looks best." >&2
fi

# iOS rejects icons with transparency, so the 1024 iOS icon is flattened to JPEG
# and back to PNG, which removes the alpha channel. The Mac icons keep it.
tmp=$(mktemp -d)
sips -s format jpeg -s formatOptions best -z 1024 1024 "$src" --out "$tmp/flat.jpg" >/dev/null
sips -s format png "$tmp/flat.jpg" --out "$dir/icon-ios-1024.png" >/dev/null
rm -rf "$tmp"

for px in 16 32 64 128 256 512 1024; do
  sips -s format png -z $px $px "$src" --out "$dir/icon-mac-$px.png" >/dev/null
done
cat > "$dir/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "universal", "platform" : "ios", "size" : "1024x1024", "filename" : "icon-ios-1024.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16", "filename" : "icon-mac-16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16", "filename" : "icon-mac-32.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32", "filename" : "icon-mac-32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32", "filename" : "icon-mac-64.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon-mac-128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon-mac-256.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon-mac-256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon-mac-512.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon-mac-512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon-mac-1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "App icon updated in $dir"

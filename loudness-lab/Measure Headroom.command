#!/bin/sh
#
# Double-click this in Finder. It asks for a folder of PROCESSED tracks
# (usually ~/Music/LoudnessLab) and answers two questions:
#
#   - is the -1 dBTP peak ceiling holding tracks under the -16 target?
#   - would rotating the phase of the bass give that level back?
#
# It writes nothing next to the music. The report is printed here and
# saved in scans/. See tools/headroom.py.
set -eu
set -o pipefail
cd "$(dirname "$0")"

fail() {
    echo
    echo "$1"
    echo
    printf "Press return to close. "; read -r _ ; exit 1
}

. ./update-from-github.sh
sync_with_github \
    || fail "Could not update, so this would measure with old code. The lines just above say why -- copy them and send them on."
VERSION="$(git log -1 --format='%h, %cd' --date=short 2>/dev/null || echo unknown)"

[ -x .venv/bin/python ] || fail "Loudness Lab is not set up on this Mac yet: setup.sh has not been run here."
command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is not installed: brew install ffmpeg"

FOLDER="$(osascript -e 'POSIX path of (choose folder with prompt "Which folder of processed tracks? (Usually Music > LoudnessLab.)" default location (path to music folder))' 2>/dev/null)" \
    || fail "No folder chosen."

mkdir -p scans
REPORT="scans/headroom-$(date +%Y-%m-%d-%H%M%S).txt"
echo "Loudness Lab version ${VERSION}" | tee "$REPORT"
.venv/bin/python -u tools/headroom.py "$FOLDER" 2>&1 | tee -a "$REPORT" \
    || fail "The measurement stopped. The errors above are the whole story -- copy them and send them on."

echo
echo "Saved to loudness-lab/$REPORT"
printf "Press return to close. "; read -r _

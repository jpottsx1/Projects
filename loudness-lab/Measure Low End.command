#!/bin/sh
#
# Double-click this in Finder. It asks for a folder of music, and then a
# reference folder (Cancel to skip that part), and reports two things
# about the bottom end -- without processing anything:
#
#   1. how much bass each track would lose on a club's mono sub system
#   2. how far each track's 200-400 Hz ("mud") sits above the reference
#
# New or changed tracks are measured into the app's library first; the
# rest is read back. The report is printed here and saved in scans/.
# See tools/low_end.py.
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

FOLDER="$(osascript -e 'POSIX path of (choose folder with prompt "Which folder of music should be checked?")' 2>/dev/null)" \
    || fail "No folder chosen."
set -- "$FOLDER"
REFERENCE="$(osascript -e 'POSIX path of (choose folder with prompt "And a reference folder for the mud comparison? (Cancel to skip.)")' 2>/dev/null)" \
    || REFERENCE=""

mkdir -p scans
REPORT="scans/low-end-$(date +%Y-%m-%d-%H%M%S).txt"
echo "Loudness Lab version ${VERSION}" | tee "$REPORT"
if [ -n "$REFERENCE" ]; then
    set -- "$FOLDER" --reference-folder "$REFERENCE"
fi
.venv/bin/python -u tools/low_end.py "$@" 2>&1 | tee -a "$REPORT" \
    || fail "The measurement stopped. The errors above are the whole story -- copy them and send them on."

echo
echo "Saved to loudness-lab/$REPORT"
printf "Press return to close. "; read -r _

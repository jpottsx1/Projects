#!/bin/sh
#
# Double-click this in Finder. It asks for a folder -- the output folder
# (Music > LoudnessLab) or a folder whose originals were replaced -- reads
# every audio file in it, and says for each whether it is at the level
# target, and if not, why. Nothing is changed. See tools/check_levels.py.
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
    || fail "Could not update, so this would check with old code. The lines just above say why -- copy them and send them on."
VERSION="$(git log -1 --format='%h, %cd' --date=short 2>/dev/null || echo unknown)"

[ -x .venv/bin/python ] || fail "Loudness Lab is not set up on this Mac yet: setup.sh has not been run here."
command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is not installed: brew install ffmpeg"

OUT="$HOME/Music/LoudnessLab"
[ -d "$OUT" ] || OUT="$HOME/Music"
FOLDER="$(osascript -e "POSIX path of (choose folder with prompt \"Which folder of finished files should be checked?\" default location POSIX file \"$OUT\")" 2>/dev/null)" \
    || fail "No folder chosen."

mkdir -p scans
REPORT="scans/levels-$(date +%Y-%m-%d-%H%M%S).txt"
echo "Loudness Lab version ${VERSION}" | tee "$REPORT"
.venv/bin/python -u tools/check_levels.py "$FOLDER" 2>&1 | tee -a "$REPORT" \
    || fail "The check stopped. The errors above are the whole story -- copy them and send them on."

echo
echo "Saved to loudness-lab/$REPORT"
printf "Press return to close. "; read -r _

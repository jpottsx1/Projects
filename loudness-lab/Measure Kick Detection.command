#!/bin/sh
#
# Double-click this in Finder. It asks for a folder of music and checks
# whether finding kicks on a separated drum part (Demucs) beats finding
# them in the full mix, which is what the sub stage does today.
#
# It writes nothing next to the music. The report is printed here and
# saved in scans/, which git ignores.
#
# The first run installs Demucs and PyTorch into .venv, once; the model
# itself (about 80 MB) downloads on the first track. See "Stems" in
# CLAUDE.md for what the numbers mean.
set -eu
# Without this, a failure inside the report pipe below would be tee's success.
set -o pipefail
cd "$(dirname "$0")"

fail() {
    echo
    echo "$1"
    echo
    printf "Press return to close. "; read -r _ ; exit 1
}

[ -x .venv/bin/python ] || fail "Loudness Lab is not set up on this Mac yet: setup.sh has not been run here."
command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is not installed: brew install ffmpeg"

if ! .venv/bin/python -c "import demucs, torch" 2>/dev/null; then
    echo "Installing Demucs and PyTorch, this once."
    echo
    .venv/bin/python -m pip install --quiet demucs \
        || fail "The install failed. The errors above are the whole story -- copy them and send them on."
fi

FOLDER="$(osascript -e 'POSIX path of (choose folder with prompt "Which folder should be checked? Four-on-the-floor tracks with a BPM tag work best.")' 2>/dev/null)" \
    || fail "No folder chosen."

mkdir -p scans
REPORT="scans/kick-detection-$(date +%Y-%m-%d-%H%M).txt"
echo
echo "Checking $FOLDER"
echo "Each track is separated first, which takes a while. The first one also"
echo "downloads the Demucs model."
echo

# -u: piped into tee, Python would otherwise hold every line back until the
# whole folder was done, and a window that says nothing for twenty minutes
# looks exactly like one that has hung.
.venv/bin/python -u tools/measure_stem_kicks.py --files "$FOLDER" --backend demucs 2>&1 | tee "$REPORT" \
    || fail "The check stopped. The errors above are the whole story -- copy them and send them on."

echo
echo "Saved to loudness-lab/$REPORT"
printf "Press return to close. "; read -r _

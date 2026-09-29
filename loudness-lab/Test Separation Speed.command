#!/bin/sh
#
# Double-click this in Finder. It asks for a folder, takes three songs
# from it, and separates each of them several ways -- the way processing
# does now, and faster ways -- timing each and checking the kicks found
# stay the same. It ends with a recommendation. Nothing is written next to
# the music; the report is printed here and saved in scans/.
#
# About five minutes for three songs. See tools/separation_speed.py.
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
    || fail "Could not update, so this would test old code. The lines just above say why -- copy them and send them on."
VERSION="$(git log -1 --format='%h, %cd' --date=short 2>/dev/null || echo unknown)"

[ -x .venv/bin/python ] || fail "Loudness Lab is not set up on this Mac yet: setup.sh has not been run here."
command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is not installed: brew install ffmpeg"
if ! .venv/bin/python -c "import demucs, torch" 2>/dev/null; then
    echo "Installing Demucs and PyTorch, this once."
    .venv/bin/python -m pip install --quiet demucs \
        || fail "The install failed. The errors above are the whole story -- copy them and send them on."
fi

if ! .venv/bin/python -c "import demucs_mlx, mlx" 2>/dev/null; then
    # The same separator rewritten for Apple's MLX, tested beside PyTorch.
    # If it will not install, the test runs without it and says so.
    echo "Installing demucs-mlx, this once."
    .venv/bin/python -m pip install --quiet demucs-mlx \
        || echo "demucs-mlx did not install; testing without it."
fi

FOLDER="$(osascript -e 'POSIX path of (choose folder with prompt "Which folder? Three songs from it are separated several ways.")' 2>/dev/null)" \
    || fail "No folder chosen."

mkdir -p scans
REPORT="scans/separation-speed-$(date +%Y-%m-%d-%H%M%S).txt"
echo "Loudness Lab version ${VERSION}" | tee "$REPORT"
.venv/bin/python -u tools/separation_speed.py "$FOLDER" 2>&1 | tee -a "$REPORT" \
    || fail "The test stopped. The errors above are the whole story -- copy them and send them on."

echo
echo "Saved to loudness-lab/$REPORT"
printf "Press return to close. "; read -r _

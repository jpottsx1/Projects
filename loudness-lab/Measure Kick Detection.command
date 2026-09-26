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

# Pull first, as Build and Run does. A report from a stale checkout is
# worse than none: the 2026-09-26 reports came from code two merges old,
# without the line they were run to get, and read as current.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Updating…"
    git pull --ff-only \
        || fail "Could not update, so this would check with old code. The lines just above say why -- copy them and send them on."
    VERSION="$(git log -1 --format='%h, %cd' --date=short)"
fi

[ -x .venv/bin/python ] || fail "Loudness Lab is not set up on this Mac yet: setup.sh has not been run here."
command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is not installed: brew install ffmpeg"

if ! .venv/bin/python -c "import demucs, torch" 2>/dev/null; then
    echo "Installing Demucs and PyTorch, this once."
    echo
    .venv/bin/python -m pip install --quiet demucs \
        || fail "The install failed. The errors above are the whole story -- copy them and send them on."
fi

# Several folders, one at a time: pick a folder, then "Add another folder"
# or "Start". Cmd-clicking several in one chooser was the first attempt,
# and in practice a click there opens the folder instead of selecting it.
# Cancel at any point starts with what has been chosen so far. One path
# per line, so a run over a few folders can be left alone.
FOLDERS="$(osascript \
    -e 'set out to ""' \
    -e 'set promptText to "Which folder should be checked? Tracks with a BPM tag work best."' \
    -e 'repeat' \
    -e 'try' \
    -e 'set f to choose folder with prompt promptText' \
    -e 'on error' \
    -e 'exit repeat' \
    -e 'end try' \
    -e 'set out to out & POSIX path of f & linefeed' \
    -e 'try' \
    -e 'set r to button returned of (display dialog ("Chosen so far:" & return & out) buttons {"Add another folder", "Start"} default button "Start")' \
    -e 'on error' \
    -e 'exit repeat' \
    -e 'end try' \
    -e 'if r is "Start" then exit repeat' \
    -e 'set promptText to "Which other folder should be checked?"' \
    -e 'end repeat' \
    -e 'return out' 2>/dev/null)" \
    || fail "No folder chosen."
[ -n "$FOLDERS" ] || fail "No folder chosen."
# One argument per folder, spaces and brackets in the names intact.
set --
while IFS= read -r line; do
    [ -n "$line" ] && set -- "$@" "$line"
done <<END_OF_FOLDERS
$FOLDERS
END_OF_FOLDERS

mkdir -p scans
REPORT="scans/kick-detection-$(date +%Y-%m-%d-%H%M%S).txt"
echo
echo "Checking:"
for f in "$@"; do echo "  $f"; done
echo "Loudness Lab version ${VERSION:-unknown}" | tee "$REPORT"
echo "A track is separated the first time it is checked, which takes a while."
echo "Tracks checked before are read from what was kept, in seconds."
echo

# -u: piped into tee, Python would otherwise hold every line back until the
# whole folder was done, and a window that says nothing for twenty minutes
# looks exactly like one that has hung.
.venv/bin/python -u tools/measure_stem_kicks.py --files "$@" --backend demucs 2>&1 | tee -a "$REPORT" \
    || fail "The check stopped. The errors above are the whole story -- copy them and send them on."

echo
echo "Saved to loudness-lab/$REPORT"
printf "Press return to close. "; read -r _

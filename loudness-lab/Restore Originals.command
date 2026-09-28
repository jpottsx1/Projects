#!/bin/sh
#
# Double-click this in Finder to undo "Replace originals when done".
# It asks which batch to put back -- a dated folder in
# Music > LoudnessLab > Replaced originals -- and moves every original in
# it back where it was. The processed files standing in their places are
# moved into that batch's "undone" folder, not deleted.
set -eu
cd "$(dirname "$0")"

fail() {
    echo
    echo "$1"
    echo
    printf "Press return to close. "; read -r _ ; exit 1
}

[ -x .venv/bin/python ] || fail "Loudness Lab is not set up on this Mac yet: setup.sh has not been run here."

KEPT="$HOME/Music/LoudnessLab/Replaced originals"
[ -d "$KEPT" ] || fail "Nothing has been replaced yet: there is no $KEPT."

BATCH="$(osascript -e "POSIX path of (choose folder with prompt \"Which batch of originals should be put back?\" default location POSIX file \"$KEPT\")" 2>/dev/null)" \
    || fail "No batch chosen. Nothing was changed."

./loudness-lab restore "$BATCH" \
    || fail "Not everything could be put back -- the lines above say which. Nothing was deleted."

echo
printf "Press return to close. "; read -r _

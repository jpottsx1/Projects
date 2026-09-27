#!/bin/sh
#
# Double-click this in Finder. It builds the app and opens it.
#
# It exists because Xcode opening a Swift package is one more thing that can
# go wrong between someone and their music, and none of it is the app's
# fault. Nothing here is special: it is the same build Xcode would do.
set -eu
cd "$(dirname "$0")"

# Pull first. Building a stale checkout is not a hypothetical problem: it
# has already cost an afternoon, looking for a pane that existed in the
# repository and not on this disk. "Pull and rebuild" should be one action,
# not two things to remember in the right order.
# Exactly GitHub's main, with anything local set aside rather than lost --
# see update-from-github.sh for why a plain pull was not enough.
. ../update-from-github.sh
if ! sync_with_github; then
    echo
    echo "Could not update. The lines above say why -- copy them and send"
    echo "them on. Building what is on disk instead; it may be out of date."
fi
echo

echo "Building Loudness Lab. The first build takes a minute or two."
echo

if ! command -v swift >/dev/null 2>&1; then
    echo "Swift is not installed. Install Xcode from the App Store, open it"
    echo "once to let it finish setting up, then double-click this again."
    echo
    printf "Press return to close. "; read -r _ ; exit 1
fi

if ! sh ./make-app.sh; then
    echo
    echo "The build failed. The errors above are the whole story -- copy them"
    echo "and send them on."
    echo
    printf "Press return to close. "; read -r _ ; exit 1
fi

open "LoudnessLab.app"
echo
echo "Running. You can close this window."

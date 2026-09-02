#!/bin/bash
#
# Removes the "Send to ImageOptim" Quick Action and any CLI symlink to it.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
target="$HOME/Library/Services/Send to ImageOptim.workflow"

if [ -d "$target" ]; then
    rm -rf "$target"
    echo "Removed $target"
else
    echo "Nothing to remove at $target"
fi

for dir in /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
    link="$dir/send-to-imageoptim"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$here/src/send-to-imageoptim.sh" ]; then
        rm -f "$link"
        echo "Removed $link"
    fi
done

[ -x /System/Library/CoreServices/pbs ] && /System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true

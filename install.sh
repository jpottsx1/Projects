#!/bin/bash
#
# Installs the "Send to ImageOptim" Quick Action into ~/Library/Services.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
bundle="Send to ImageOptim.workflow"
services="$HOME/Library/Services"
cli_dir=""

usage() {
    cat <<'USAGE'
usage: ./install.sh [--cli [DIR]]

Copies the Quick Action to ~/Library/Services so it shows up in Finder's
right-click menu under Quick Actions.

  --cli [DIR]   also symlink the send-to-imageoptim command into DIR
                (default /usr/local/bin), for use from the shell
USAGE
}

while [ $# -gt 0 ]; do
    case $1 in
        --cli)
            if [ $# -gt 1 ]; then
                cli_dir=$2
                shift
            else
                cli_dir=/usr/local/bin
            fi
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

[ "$(uname -s)" = "Darwin" ] || { echo "This installs a macOS Finder service; it only runs on macOS." >&2; exit 1; }
[ -d "$here/$bundle" ] || { echo "Missing '$bundle' -- run: python3 tools/build-workflow.py" >&2; exit 1; }

if ! /usr/bin/mdfind "kMDItemCFBundleIdentifier == 'net.pornel.ImageOptim'" 2>/dev/null | grep -q . \
   && [ ! -d /Applications/ImageOptim.app ] && [ ! -d "$HOME/Applications/ImageOptim.app" ]; then
    echo "Warning: ImageOptim.app was not found. Install it from https://imageoptim.com" >&2
fi

mkdir -p "$services"
rm -rf "$services/$bundle"
cp -R "$here/$bundle" "$services/$bundle"
echo "Installed $services/$bundle"

if [ -n "$cli_dir" ]; then
    mkdir -p "$cli_dir"
    ln -sf "$here/src/send-to-imageoptim.sh" "$cli_dir/send-to-imageoptim"
    echo "Linked $cli_dir/send-to-imageoptim"
fi

# Ask the pasteboard server to re-read the Services directory.
[ -x /System/Library/CoreServices/pbs ] && /System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true

cat <<'DONE'

Done. In Finder, select some images, right-click, and choose
    Quick Actions > Send to ImageOptim
(older selections may list it under Services instead).

If it does not appear yet, run `killall Finder`, or turn it on in
System Settings > Keyboard > Keyboard Shortcuts > Services > Files and Folders
-- where you can also give it a keyboard shortcut.
DONE

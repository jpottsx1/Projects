#!/bin/bash
#
# send-to-imageoptim -- hand a set of files (or folders) to ImageOptim.app
#
# ImageOptim has no real CLI, so the files are handed over the same way a
# drag-and-drop does: an "open documents" Apple Event sent straight to the app.
# `open -a ImageOptim file.png` looks like the obvious way to do it, but it
# goes through LaunchServices, which refuses with "ImageOptim cannot open
# files in the PNG image format" on builds whose bundle does not advertise
# those document types. A drop never consults that list, and neither does the
# Apple Event. Two cruder fallbacks follow it; see handoff() below.
#
# This script is the body of the "Send to ImageOptim" Finder Quick Action and
# also works standalone:  send-to-imageoptim ~/Pictures/*.png
#
# Configuration (environment variables):
#   IMAGEOPTIM_EXTS  space-separated list of extensions to accept
#                    (default: png jpg jpeg gif svg)
#   IMAGEOPTIM_APP   full path to the .app bundle (default: located with
#                    Spotlight, then /Applications and ~/Applications)
#   IMAGEOPTIM_QUIET set to 1 to suppress the "nothing to do" notification
#   IMAGEOPTIM_METHOD pin the handoff: applescript | applescript_name |
#                    launchargs | openapp
#                    (default: try them in that order, keep the first that
#                    works)
#
# The same three can be set in ~/.config/send-to-imageoptim/config, which is
# sourced as shell -- handy for tuning the installed Quick Action without
# rebuilding it, e.g.  IMAGEOPTIM_EXTS="png jpg jpeg"

set -u

# Environment wins over the config file, which wins over these defaults.
env_exts=${IMAGEOPTIM_EXTS:-}
env_app=${IMAGEOPTIM_APP:-}
env_quiet=${IMAGEOPTIM_QUIET:-}
env_method=${IMAGEOPTIM_METHOD:-}

config=${XDG_CONFIG_HOME:-$HOME/.config}/send-to-imageoptim/config
# shellcheck source=/dev/null
[ -r "$config" ] && . "$config"

exts=${env_exts:-${IMAGEOPTIM_EXTS:-"png jpg jpeg gif svg"}}
quiet=${env_quiet:-${IMAGEOPTIM_QUIET:-0}}
method=${env_method:-${IMAGEOPTIM_METHOD:-}}

notify() {
    # $1 = message, $2 = title
    /usr/bin/osascript -e "display notification $(quote_as "$1") with title $(quote_as "${2:-ImageOptim}")" >/dev/null 2>&1 || true
}

quote_as() {
    # AppleScript string literal
    local s=${1//\\/\\\\}
    printf '"%s"' "${s//\"/\\\"}"
}

die() {
    printf 'send-to-imageoptim: %s\n' "$1" >&2
    notify "$1" "ImageOptim"
    exit 1
}

usage() {
    cat <<'USAGE'
usage: send-to-imageoptim [file|folder ...]
       send-to-imageoptim --check

Adds the given images to ImageOptim's queue. Folders are passed through
whole; ImageOptim walks them recursively. Files whose extension is not in
IMAGEOPTIM_EXTS (default: png jpg jpeg gif svg) are skipped.

--check reports which ImageOptim it found and sends it a test image it
creates itself, printing which handoff method worked.
USAGE
}

do_check=0
case ${1:-} in
    -h|--help) usage; exit 0 ;;
    --check)   do_check=1 ;;
esac

if [ "$do_check" -eq 0 ] && [ $# -eq 0 ]; then
    usage >&2
    exit 2
fi

# --- locate ImageOptim ------------------------------------------------------
app=${env_app:-${IMAGEOPTIM_APP:-}}
if [ -z "$app" ]; then
    # By name, through LaunchServices: it knows where the app actually is, and
    # unlike a hardcoded bundle ID it cannot be wrong about which build this is.
    app=$(/usr/bin/osascript -e 'POSIX path of (path to application "ImageOptim")' 2>/dev/null) || app=""
fi
if [ -z "$app" ]; then
    app=$(/usr/bin/mdfind "kMDItemFSName == 'ImageOptim.app'" 2>/dev/null | /usr/bin/head -n 1)
fi
if [ -z "$app" ]; then
    for candidate in /Applications/ImageOptim.app "$HOME/Applications/ImageOptim.app"; do
        [ -d "$candidate" ] && { app=$candidate; break; }
    done
fi
[ -z "$app" ] && die "ImageOptim is not installed. Get it at https://imageoptim.com"
app=${app%/}

# The real identifiers, read off the bundle we actually found.
bundle_id=$(/usr/bin/defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null) || bundle_id=""
app_name=${app##*/}
app_name=${app_name%.app}

# --- hand off ---------------------------------------------------------------
# What a drop does: an open-documents Apple Event to the running (or
# newly launched) app. No LaunchServices document-type check, no second copy.
applescript_open() {
    # $1 is a complete AppleScript application specifier
    local specifier=$1
    shift
    /usr/bin/osascript - "$@" >/dev/null 2>&1 <<APPLESCRIPT
on run argv
    set theFiles to {}
    repeat with thePath in argv
        set end of theFiles to POSIX file (thePath as text)
    end repeat
    tell application $specifier
        activate
        open theFiles
    end tell
end run
APPLESCRIPT
}

handoff_applescript() {
    [ -n "$bundle_id" ] || return 1
    applescript_open "id \"$bundle_id\"" "$@"
}

# Same event, addressed by name -- the fallback for when the bundle carries an
# identifier LaunchServices has not registered.
handoff_applescript_name() {
    applescript_open "\"$app_name\"" "$@"
}

# ImageOptim also reads paths out of its own argv, but --args is only
# delivered to a process being launched, hence the new instance.
handoff_launchargs() {
    /usr/bin/open -n -a "$app" --args "$@" >/dev/null 2>&1
}

# The obvious one, kept last: LaunchServices may refuse the file types.
handoff_openapp() {
    /usr/bin/open -a "$app" "$@" >/dev/null 2>&1
}

METHODS="applescript applescript_name launchargs openapp"

handoff() {
    case $method in
        applescript|applescript_name|launchargs|openapp)
            "handoff_$method" "$@"; return $? ;;
    esac
    local candidate
    for candidate in $METHODS; do
        if "handoff_$candidate" "$@"; then
            method=$candidate   # stick with whatever worked for later batches
            return 0
        fi
    done
    return 1
}


# --- self test --------------------------------------------------------------
# A 1x1 PNG, so --check needs no file from the caller and cannot fail over a
# path that turns out not to exist.
TEST_PNG=iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==

selftest() {
    local dir file candidate
    printf 'App       : %s\n' "$app"
    printf 'Bundle ID : %s\n' "${bundle_id:-(none in Info.plist)}"

    dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/send-to-imageoptim.XXXXXXXX") || return 1
    file=$dir/send-to-imageoptim-test.png
    printf '%s' "$TEST_PNG" | /usr/bin/base64 -D >"$file" 2>/dev/null ||
        printf '%s' "$TEST_PNG" | /usr/bin/base64 --decode >"$file"
    [ -s "$file" ] || { printf 'could not write a test image\n' >&2; return 1; }
    printf 'Test image: %s\n\n' "$file"

    for candidate in $METHODS; do
        printf '  %-18s' "$candidate"
        if "handoff_$candidate" "$file"; then
            printf ' worked\n\nImageOptim should now be showing send-to-imageoptim-test.png.\n'
            printf 'If it is, everything works -- pin it with IMAGEOPTIM_METHOD=%s\n' "$candidate"
            printf 'in ~/.config/send-to-imageoptim/config if you like.\n'
            return 0
        fi
        printf ' failed\n'
    done

    printf '\nNothing worked. Send the output above back to whoever asked for it.\n' >&2
    return 1
}

if [ "$do_check" -eq 1 ]; then
    selftest
    exit $?
fi

# --- filter the selection ---------------------------------------------------
matches_ext() {
    local name=${1##*/}
    local ext=${name##*.}
    [ "$ext" = "$name" ] && return 1          # no extension at all
    ext=$(printf '%s' "$ext" | /usr/bin/tr '[:upper:]' '[:lower:]')
    local candidate
    for candidate in $exts; do
        [ "$ext" = "$candidate" ] && return 0
    done
    return 1
}

sent=0
skipped=0
files=()

for path in "$@"; do
    # Always hand `open` an absolute path: Finder gives us those anyway, and it
    # keeps a name that starts with "-" from being read as an option.
    case $path in
        /*) ;;
         *) path=$PWD/$path ;;
    esac
    if [ -e "$path" ] && { [ -d "$path" ] || matches_ext "$path"; }; then
        files+=("$path")
        sent=$((sent + 1))
    else
        skipped=$((skipped + 1))
    fi
done

if [ "$sent" -eq 0 ]; then
    if [ "$quiet" != "1" ]; then
        if [ "$skipped" -eq 1 ]; then
            notify "That file is not one ImageOptim can optimize." "ImageOptim"
        else
            notify "None of those $skipped items are files ImageOptim can optimize." "ImageOptim"
        fi
    fi
    exit 0
fi

# Send in batches so a selection of thousands cannot blow past ARG_MAX.
batch=200
index=0
while [ "$index" -lt "$sent" ]; do
    handoff "${files[@]:index:batch}" || die "ImageOptim would not accept the files."
    index=$((index + batch))
done

exit 0

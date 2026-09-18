#!/usr/bin/env bash
#
# One-command local setup. Creates a private virtual environment so nothing
# is installed into the system Python -- recent macOS/Homebrew Pythons refuse
# a plain `pip3 install` with "externally-managed-environment" anyway.
#
# Safe to re-run.

set -euo pipefail
cd "$(dirname "$0")"

VENV=".venv"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

echo "loudness-lab setup"
echo

# --- Python -----------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || die "python3 not found. Install it with: brew install python"
PY_VERSION="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
python3 - <<'PY' || die "Python 3.9 or newer is required (found $PY_VERSION)"
import sys
sys.exit(0 if sys.version_info >= (3, 9) else 1)
PY
ok "python3 $PY_VERSION"

# --- ffmpeg -----------------------------------------------------------------
missing_ffmpeg=0
for tool in ffmpeg ffprobe; do
    if command -v "$tool" >/dev/null 2>&1; then
        ok "$tool $("$tool" -version 2>/dev/null | head -1 | awk '{print $3}')"
    else
        warn "$tool not found"
        missing_ffmpeg=1
    fi
done
if [ "$missing_ffmpeg" -eq 1 ]; then
    echo
    die "ffmpeg is required for decoding. Install it with:

    brew install ffmpeg

  then run ./setup.sh again."
fi

# --- virtual environment ----------------------------------------------------
if [ ! -d "$VENV" ]; then
    python3 -m venv "$VENV" || die "could not create a virtual environment.
  On Debian/Ubuntu you may need: sudo apt-get install python3-venv"
    ok "created $VENV"
else
    ok "$VENV already exists"
fi

"$VENV/bin/python3" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
"$VENV/bin/python3" -m pip install --quiet -r requirements.txt \
    || die "dependency install failed"
ok "numpy $("$VENV/bin/python3" -c 'import numpy; print(numpy.__version__)')"
ok "scipy $("$VENV/bin/python3" -c 'import scipy; print(scipy.__version__)')"

# --- self-test --------------------------------------------------------------
echo
echo "Running the test suite..."
if "$VENV/bin/python3" -m unittest discover -s tests -t . >/tmp/loudness-lab-tests.log 2>&1; then
    ok "$(tail -3 /tmp/loudness-lab-tests.log | head -1 | tr -d '\n')"
else
    warn "tests failed -- see /tmp/loudness-lab-tests.log"
fi

cat <<'MSG'

Ready. The ./loudness-lab launcher picks up the virtual environment on its
own, so there is nothing to activate.

  ./loudness-lab doctor "/path/to/your/music"     check before a long run
  ./loudness-lab analyze "/path/to/your/music" --db library.db
  ./loudness-lab report loudness --db library.db
  ./loudness-lab report lowend   --db library.db
MSG

# Sourced by the Finder commands (Build and Run, Measure Kick Detection);
# not run on its own. Defines sync_with_github.
#
# It makes this copy exactly what is on GitHub's main, and loses nothing
# doing it. It replaced a plain `git pull --ff-only`, which stops dead the
# moment this copy has anything GitHub does not -- a stray local commit
# (2026-09-27: a report ran at f48b3bf, a version GitHub has never had)
# means no update ever arrives again, silently, while the reports still
# look current.
#
# - Edits to files GitHub also has are set aside with `git stash`.
# - Commits made here and not on GitHub are kept on a branch of their own,
#   local-<date>, and named in the window.
# - Then main is moved to GitHub's main and this copy switched to it.
# Files git does not track -- music, scans/, the separations -- are never
# touched.

sync_with_github() {
    command -v git >/dev/null 2>&1 || return 0
    git rev-parse --git-dir >/dev/null 2>&1 || return 0
    echo "Updating from GitHub…"
    if ! git fetch --quiet origin main; then
        echo "  Could not reach GitHub."
        return 1
    fi
    stamp="$(date +%Y-%m-%d-%H%M%S)"
    if ! git diff --quiet || ! git diff --cached --quiet; then
        git stash push --quiet -m "set aside by the update, ${stamp}" || return 1
        echo "  Edits made on this Mac were set aside, not lost"
        echo "  (git stash: \"set aside by the update, ${stamp}\")."
    fi
    if [ -n "$(git rev-list HEAD --not origin/main 2>/dev/null)" ]; then
        git branch "local-${stamp}" HEAD || return 1
        echo "  This Mac had a version GitHub does not ($(git log -1 --format=%h HEAD));"
        echo "  it is kept on the branch local-${stamp}."
    fi
    git checkout --quiet -B main origin/main || return 1
    git branch --quiet --set-upstream-to=origin/main main 2>/dev/null || true
    echo "  Now at $(git log -1 --format='%h, %cd' --date=short), the same as GitHub."
}

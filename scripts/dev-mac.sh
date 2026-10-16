#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
app="${1:-.artifacts/ResizeReview/Build/Products/Debug/AFK.app}"
binary="$app/Contents/MacOS/AFK"
if [ ! -x "$binary" ]; then
    echo "Build AFKMac first, or pass the path to AFK.app." >&2
    exit 1
fi
if pgrep -x AFK >/dev/null; then
    echo "AFK is already running. Quit it manually before relaunching; quitting ends its shell sessions." >&2
    exit 1
fi
# Only this development launcher removes color overrides inherited from tooling.
# Shell startup files can still set the user's own color preferences.
exec env -u NO_COLOR -u FORCE_COLOR -u CLICOLOR -u CLICOLOR_FORCE "$binary"

#!/bin/bash
set -euo pipefail
app=${1:?Path to the signed AFK.app}
output=${2:?Destination DMG}
test -d "$app/Contents"
test ! -e "$output"
stage=$(mktemp -d "${TMPDIR:-/tmp}/afk-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/AFK.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname AFK -srcfolder "$stage" -format UDZO "$output"

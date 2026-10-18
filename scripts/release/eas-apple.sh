#!/bin/bash
set -euo pipefail
mode=${1:?mac or ios}
[[ "$mode" == mac || "$mode" == ios ]] || exit 2
[[ "${AFK_SOURCE_COMMIT:?}" =~ ^[0-9a-f]{40}$ ]]
[[ "${AFK_BUILD_NUMBER:?}" =~ ^[1-9][0-9]{0,3}\.[0-9]{1,2}\.[0-9]{1,2}$ ]]
# The CLI uploads a clean, tracked source tree and a manifest of its tested commit.
test "$(cat .afk-source-commit)" = "$AFK_SOURCE_COMMIT"
export RUNNER_TEMP
RUNNER_TEMP=$(mktemp -d)
trap 'rm -rf "$RUNNER_TEMP"' EXIT
if [[ "$mode" == mac ]]; then
    export P12_BASE64="${MAC_CERTIFICATE_P12_BASE64:?}"
    export P12_PASSWORD="${MAC_CERTIFICATE_PASSWORD:?}"
else
    export P12_BASE64="${IOS_CERTIFICATE_P12_BASE64:?}"
    export P12_PASSWORD="${IOS_CERTIFICATE_PASSWORD:?}"
fi
python3 scripts/release/preflight.py "$mode" --check-relay
xcodebuild -version
xcodebuild -downloadComponent MetalToolchain
bash scripts/release/apple.sh "$mode"

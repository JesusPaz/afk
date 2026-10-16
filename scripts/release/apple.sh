#!/bin/bash
set -euo pipefail
# Run on an ephemeral GitHub macOS runner; never on a developer's login keychain.
mode=${1:?mac or ios}
[[ "$mode" == mac || "$mode" == ios ]] || exit 2
: "${RUNNER_TEMP:?}" "${APPLE_TEAM_ID:?}" "${P12_BASE64:?}" "${P12_PASSWORD:?}"
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_BASE64:?}" "${RELEASE_TAG:?}" "${AFK_RELAY_URL:?}"
python3 scripts/release/version.py "$RELEASE_TAG" > "$RUNNER_TEMP/afk-version"
version=$(sed -n 's/^version=//p' "$RUNNER_TEMP/afk-version")
build="${GITHUB_RUN_NUMBER:?}.${GITHUB_RUN_ATTEMPT:?}"
work=$(mktemp -d "$RUNNER_TEMP/afk-signing.XXXXXX")
keychain="$work/signing.keychain-db"
profile_path=""
cleanup() {
    if [[ -n "$profile_path" ]]; then rm -f "$profile_path"; fi
    security delete-keychain "$keychain" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT
umask 077
export SIGNING_WORK="$work"
python3 - <<'PY'
import base64, os
from pathlib import Path
p = Path(os.environ['SIGNING_WORK'])
for name, variable in [('certificate.p12', 'P12_BASE64'), ('AuthKey.p8', 'ASC_KEY_BASE64')]:
    (p / name).write_bytes(base64.b64decode(os.environ[variable], validate=True))
PY
password=$(openssl rand -hex 24)
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$work/certificate.p12" -k "$keychain" -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
args=(-project apps/apple/AFK.xcodeproj -configuration Release -archivePath "$work/AFK.xcarchive"
    -derivedDataPath "$work/build" -skipPackagePluginValidation
    "DEVELOPMENT_TEAM=$APPLE_TEAM_ID" "MARKETING_VERSION=$version" "CURRENT_PROJECT_VERSION=$build"
    "AFK_RELAY_URL=$AFK_RELAY_URL" CODE_SIGN_STYLE=Manual "OTHER_CODE_SIGN_FLAGS=--keychain $keychain")
if [[ "$mode" == mac ]]; then
    xcodebuild "${args[@]}" -scheme AFKMac -destination 'generic/platform=macOS' \
        'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO ENABLE_HARDENED_RUNTIME=YES \
        'CODE_SIGN_IDENTITY=Developer ID Application' archive
else
    : "${IOS_PROFILE_BASE64:?}"
    python3 - <<'PY'
import base64, os
from pathlib import Path
(Path(os.environ['SIGNING_WORK']) / 'profile.mobileprovision').write_bytes(base64.b64decode(os.environ['IOS_PROFILE_BASE64'], validate=True))
PY
    security cms -D -i "$work/profile.mobileprovision" > "$work/profile.plist"
    profile=$(/usr/libexec/PlistBuddy -c 'Print UUID' "$work/profile.plist")
    export PROFILE_UUID="$profile"
    python3 scripts/release/check-profile.py "$work/profile.plist"
    profile_path="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$profile.mobileprovision"
    mkdir -p "$(dirname "$profile_path")"
    cp "$work/profile.mobileprovision" "$profile_path"
    xcodebuild "${args[@]}" -scheme AFKiOS -destination 'generic/platform=iOS' \
        'CODE_SIGN_IDENTITY=Apple Distribution' "PROVISIONING_PROFILE_SPECIFIER=$profile" archive
fi
export APPLE_EXPORT_MODE="$mode"
python3 - <<'PY'
import os, plistlib
from pathlib import Path
mac = os.environ['APPLE_EXPORT_MODE'] == 'mac'
options = dict(method='developer-id' if mac else 'app-store-connect', destination='export' if mac else 'upload',
               signingStyle='manual', teamID=os.environ['APPLE_TEAM_ID'],
               signingCertificate='Developer ID Application' if mac else 'Apple Distribution',
               manageAppVersionAndBuildNumber=False)
if not mac:
    options.update(provisioningProfiles={'com.jesuspaz.afk.ios': os.environ['PROFILE_UUID']},
                   testFlightInternalTestingOnly=True, uploadSymbols=True)
with (Path(os.environ['SIGNING_WORK']) / 'ExportOptions.plist').open('wb') as f:
    plistlib.dump(options, f)
PY
xcodebuild -exportArchive -archivePath "$work/AFK.xcarchive" -exportPath "$work/export" \
    -exportOptionsPlist "$work/ExportOptions.plist" \
    -authenticationKeyPath "$work/AuthKey.p8" -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" -allowProvisioningUpdates
if [[ "$mode" == mac ]]; then
    app="$work/export/AFK.app"
    codesign --verify --deep --strict "$app"
    lipo "$app/Contents/MacOS/AFK" -verify_arch arm64 x86_64
    ditto -c -k --keepParent "$app" "$work/notarize.zip"
    xcrun notarytool submit "$work/notarize.zip" --key "$work/AuthKey.p8" \
        --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait --output-format json > "$work/notary.json"
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted", "Notarization rejected"' "$work/notary.json"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute "$app"
    mkdir -p dist
    ditto -c -k --keepParent "$app" "dist/AFK-$RELEASE_TAG-macOS.zip"
    (cd dist && shasum -a 256 "AFK-$RELEASE_TAG-macOS.zip" > SHA256SUMS)
    token=afk
    [[ "$RELEASE_TAG" != *-rc.* ]] || token=afk@preview
    python3 scripts/release/cask.py "$RELEASE_TAG" "dist/AFK-$RELEASE_TAG-macOS.zip" "dist/$token.rb"
fi

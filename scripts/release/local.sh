#!/bin/bash
# Build, sign, notarize and publish a release from this Mac, without EAS.
# Usage: scripts/release/local.sh vX.Y.Z[-rc.N]
# Uses the login keychain identities, the notarytool keychain profile and the
# Xcode account for the TestFlight upload. Builds a clean checkout of origin/main.
# Rerunning with the same tag resumes publishing if a previous run stopped there.
set -euo pipefail
tag=${1:?Usage: scripts/release/local.sh vX.Y.Z[-rc.N]}
repo=JesusPaz/afk
team=Y76K9N6M4R
relay=${AFK_RELAY_URL:-https://afk.jesuspaz.com}
notary=${AFK_NOTARY_PROFILE:-AFK}
root=$(git rev-parse --show-toplevel)
version=$(python3 "$root/scripts/release/version.py" "$tag" | sed -n 's/^version=//p')
token=afk; [[ "$tag" != *-rc.* ]] || token=afk@preview
step() { printf '\n==> %s\n' "$*"; }
# Dispatch a workflow on main and print the id of the run created by this dispatch.
dispatch() {
    local workflow=$1 since id
    since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    gh workflow run "$workflow" -R "$repo" --ref main -f tag="$tag" >&2
    for _ in $(seq 60); do
        id=$(gh run list -R "$repo" --workflow "$workflow" --event workflow_dispatch --created ">=$since" \
            --limit 1 --json databaseId,headSha --jq ".[] | select(.headSha == \"$commit\") | .databaseId")
        if [[ -n "$id" ]]; then echo "$id"; return; fi
        sleep 5
    done
    echo "No $workflow run appeared for $commit." >&2; return 1
}

step "Checking $tag"
git -C "$root" fetch -q origin main --tags
commit=$(git -C "$root" rev-parse origin/main)
published=$(gh release view "$tag" -R "$repo" --json isDraft --jq '.isDraft | not' 2>/dev/null || echo false)
[[ "$published" == false ]] || { echo "Release $tag is already published." >&2; exit 1; }
if existing=$(git -C "$root" rev-parse -q --verify "refs/tags/$tag^{commit}"); then
    [[ "$existing" == "$commit" ]] || { echo "Tag $tag points to $existing, not $commit." >&2; exit 1; }
fi
ci=$(gh run list -R "$repo" --workflow ci.yml --commit "$commit" --status success --limit 1 --json databaseId --jq length)
[[ "$ci" == 1 ]] || { echo "CI has not passed on $commit." >&2; exit 1; }
curl -fsS -A AFK-Release/1.0 "$relay/readyz" > /dev/null
identities=$(security find-identity -v -p codesigning)
mac_identity=$(awk '/"Developer ID Application: .*\('"$team"'\)"/ {print $2; exit}' <<< "$identities")
[[ -n "$mac_identity" ]] || { echo "No Developer ID Application identity for $team." >&2; exit 1; }
[[ "$identities" == *"Apple Distribution: "*"($team)"* ]] || { echo "No Apple Distribution identity for $team." >&2; exit 1; }
xcrun notarytool history --keychain-profile "$notary" > /dev/null
profile_uuid=""
for profile in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision; do
    decoded=$(mktemp); security cms -D -i "$profile" > "$decoded" 2>/dev/null || { rm -f "$decoded"; continue; }
    if APPLE_TEAM_ID=$team python3 "$root/scripts/release/check-profile.py" "$decoded" 2>/dev/null; then
        profile_uuid=$(plutil -extract UUID raw "$decoded")
    fi
    rm -f "$decoded"
    [[ -z "$profile_uuid" ]] || break
done
[[ -n "$profile_uuid" ]] || { echo "No valid App Store profile for com.jesuspaz.afk.ios." >&2; exit 1; }
# Same scheme as the EAS builds: minutes since 2020, always increasing.
build=$(python3 -c 'import datetime as d; m=int((d.datetime.now(d.timezone.utc)-d.datetime(2020,1,1,tzinfo=d.timezone.utc)).total_seconds()//60); print(f"{m//10000}.{m//100%100}.{m%100}")')
echo "commit $commit · version $version · build $build"

work=$(mktemp -d "${TMPDIR:-/tmp}/afk-release.XXXXXX")
source_dir="$work/source"
cleanup() { git -C "$root" worktree remove --force "$source_dir" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
git -C "$root" worktree add -q --detach "$source_dir" "$commit"
cd "$source_dir"
dist="$work/dist"; mkdir -p "$dist"

xcodebuild -downloadComponent MetalToolchain > /dev/null
args=(-project apps/apple/AFK.xcodeproj -configuration Release -derivedDataPath "$work/build" -skipPackagePluginValidation
      "DEVELOPMENT_TEAM=$team" "MARKETING_VERSION=$version" "CURRENT_PROJECT_VERSION=$build" "AFK_RELAY_URL=$relay" CODE_SIGN_STYLE=Manual)
export_options() { # output path, extra keys as a Python dict literal
    python3 - "$1" "$2" "$team" <<'PY'
import ast, plistlib, sys
path, extra, team = sys.argv[1:]
plistlib.dump(dict(signingStyle='manual', teamID=team, manageAppVersionAndBuildNumber=False, **ast.literal_eval(extra)), open(path, 'wb'))
PY
}

step "Mac: archive (universal)"
xcodebuild "${args[@]}" -scheme AFKMac -archivePath "$work/AFKMac.xcarchive" -destination 'generic/platform=macOS' \
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_IDENTITY=- archive -quiet
export_options "$work/mac.plist" "{'method': 'developer-id', 'destination': 'export', 'signingCertificate': '$mac_identity'}"
xcodebuild -exportArchive -archivePath "$work/AFKMac.xcarchive" -exportPath "$work/mac" -exportOptionsPlist "$work/mac.plist" -quiet
app="$work/mac/AFK.app"
codesign --verify --deep --strict "$app"
python3 -c 'import sys; assert set(sys.argv[1].split()) == {"arm64", "x86_64"}, "Mac app must be universal"' "$(xcrun lipo -archs "$app/Contents/MacOS/AFK")"

step "Mac: notarize app"
ditto -c -k --keepParent "$app" "$work/notarize.zip"
xcrun notarytool submit "$work/notarize.zip" --keychain-profile "$notary" --wait --output-format json > "$work/notary.json"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted", "Notarization rejected"' "$work/notary.json"
xcrun stapler staple "$app"; xcrun stapler validate "$app"; spctl --assess --type execute "$app"
ditto -c -k --keepParent "$app" "$dist/AFK-$tag-macOS.zip"

step "Mac: DMG"
dmg="$dist/AFK-$tag-macOS.dmg"
bash scripts/release/dmg.sh "$app" "$dmg"
codesign --sign "$mac_identity" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$notary" --wait --output-format json > "$work/dmg-notary.json"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted", "DMG notarization rejected"' "$work/dmg-notary.json"
xcrun stapler staple "$dmg"; xcrun stapler validate "$dmg"
(cd "$dist" && shasum -a 256 "AFK-$tag-macOS.zip" "AFK-$tag-macOS.dmg" > SHA256SUMS)
python3 scripts/release/cask.py "$tag" "$dist/AFK-$tag-macOS.zip" "$dist/$token.rb"

step "iPhone: archive and upload to TestFlight"
xcodebuild "${args[@]}" -scheme AFKiOS -archivePath "$work/AFKiOS.xcarchive" -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO archive -quiet
export_options "$work/ios.plist" "{'method': 'app-store-connect', 'destination': 'upload', 'signingCertificate': 'Apple Distribution', 'provisioningProfiles': {'com.jesuspaz.afk.ios': '$profile_uuid'}, 'testFlightInternalTestingOnly': True, 'uploadSymbols': True}"
xcodebuild -exportArchive -archivePath "$work/AFKiOS.xcarchive" -exportPath "$work/ios" -exportOptionsPlist "$work/ios.plist" -allowProvisioningUpdates -quiet

step "Relay image on GitHub"
image_run=$(dispatch container.yml)
gh run watch "$image_run" -R "$repo" --exit-status > /dev/null
gh run download "$image_run" -R "$repo" -n relay-image -D "$dist"

step "Publishing $tag"
# Same order as release.yml: tag, draft, upload, publish. A rerun resumes here.
if ! git -C "$root" ls-remote --exit-code --tags origin "refs/tags/$tag" > /dev/null; then
    git -C "$root" tag -f -a "$tag" "$commit" -m "AFK $tag"
    git -C "$root" push -q origin "refs/tags/$tag"
fi
gh release view "$tag" -R "$repo" > /dev/null 2>&1 ||
    gh release create "$tag" -R "$repo" --verify-tag --generate-notes --draft --title "AFK $tag"
gh release upload "$tag" -R "$repo" "$dist"/* --clobber
flags=(--latest); [[ "$tag" != *-rc.* ]] || flags=(--prerelease --latest=false)
gh release edit "$tag" -R "$repo" --draft=false "${flags[@]}"

if [[ -n "$(gh variable get HOMEBREW_TAP_REPOSITORY -R "$repo" 2>/dev/null)" ]]; then
    step "Updating Homebrew"
    brew_run=$(dispatch homebrew.yml)
    gh run watch "$brew_run" -R "$repo" --exit-status > /dev/null
fi

step "Done: https://github.com/$repo/releases/tag/$tag"
echo "Mac $version ($build) notarized; iPhone build $build uploaded to TestFlight (internal)."

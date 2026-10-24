# Publishing AFK

Updated 2026-10-17: GitHub orchestrates RC/stable releases and EAS runs both
native Apple builds. Tracks [MVP #3](https://github.com/JesusPaz/afk/issues/3).
Owner for credentials and distribution: **JesusPaz**.

Like Testa, AFK uses Expo's build service. AFK has its own EAS project
[`@jesuspazs-team/afk`](https://expo.dev/accounts/jesuspazs-team/projects/afk).
Custom macOS jobs run the existing Swift/Xcode projects directly: `app.json` and
`package.json` identify the delivery project; they do not add an Expo runtime.
The worker image is pinned to Xcode 27.0 and EAS CLI to 25.1.1 (older CLI 22.6.0
fails to validate the current workflow schema).

## Workflows

| Workflow | Trigger | Result |
| --- | --- | --- |
| CI | PR, main push, reusable call | Go race + PostgreSQL, vet, Swift tests, both app builds, packaging tests, Docker build |
| Publish relay candidate | Manual, chosen branch/commit | After CI, pushes `ghcr.io/jesuspaz/afk-relay:sha-<full commit>` for amd64/arm64; uploads exact digest |
| Release | Manual on main, explicit `vX.Y.Z` or `vX.Y.Z-rc.N` | CI → EAS Mac DMG + ZIP and internal iOS upload → versioned relay image → annotated tag at tested SHA → GitHub Release → Homebrew PR, merged automatically |
| TestFlight internal | Manual, chosen branch/commit + version label | CI → EAS signed iOS archive → internal-only upload; no Git tag or public App Review |
| Homebrew update | Called after release, or manual retry | Downloads release cask, opens a PR in your configured tap and squash-merges it; rerunning it for the same tag is safe |

Version input is explicit rather than calculated from commit messages. Start with
`v0.1.0-rc.1`, then `v0.1.0-rc.2`; use `v0.1.0` only when ready. RC releases are
marked prerelease and never latest. Stable releases become latest. Do not release
an older stable version after a newer one with this workflow.

The same selected commit flows through all reusable workflows. Publication is
invoked directly: it does not depend on a tag pushed with `GITHUB_TOKEN` triggering
another workflow (GitHub suppresses that recursive trigger).

Mac artifacts: `AFK-v<version>-macOS.dmg`, `AFK-v<version>-macOS.zip`, `SHA256SUMS`, `relay-image.txt`, and
`afk.rb` / `afk@preview.rb`. Both containers hold the Developer ID-signed, stapled app for Apple Silicon and
Intel. The DMG includes an Applications shortcut for drag-and-drop installation.
Homebrew downloads the ZIP, verifies its SHA-256 and requires macOS 14+.
Using the ZIP avoids disk-image mount conflicts during automated installation.
No unsigned fallback and no `sha256 :no_check`.

## GitHub and Apple setup

Create GitHub environments `release` and `homebrew`, restricted to trusted branches.
Add `EXPO_TOKEN` as a GitHub secret. Both release and TestFlight use the same
non-cancelling GitHub queue and the reusable `apple.yml` workflow.

Store Apple values below in AFK's **EAS production environment**, at project scope.
Use secret visibility for private keys, PKCS#12 passwords and provisioning profiles.
Keep Homebrew variables/secrets in GitHub. The tap update is opt-in: set
`HOMEBREW_TAP_REPOSITORY` together with its scoped token to enable it; without them,
the release still includes the generated cask for a manual tap update. Never print secret values or attach them
to a release. Uploading existing signing identities to EAS requires the owner's
explicit authorization; do not revoke or replace Testa's credentials.

| Name | Kind | Used by |
| --- | --- | --- |
| `APPLE_TEAM_ID` | Variable | EAS Apple jobs; existing paid Apple Developer team |
| `AFK_RELAY_URL` | Variable | Both; proposed `https://afk.jesuspaz.com`, must be reachable before beta upload |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | Variables | App Store Connect team API key, including notarization access |
| `ASC_KEY_BASE64` | Secret | Base64 of the `.p8` team API key |
| `MAC_CERTIFICATE_P12_BASE64` | Secret | Exported **Developer ID Application** certificate plus private key |
| `MAC_CERTIFICATE_PASSWORD` | Secret | Password of that PKCS#12 export |
| `IOS_CERTIFICATE_P12_BASE64` | Secret | **Apple Distribution** certificate plus private key |
| `IOS_CERTIFICATE_PASSWORD` | Secret | Password of the iOS PKCS#12 export |
| `IOS_PROFILE_BASE64` | Secret | App Store Connect distribution profile for `com.jesuspaz.afk.ios`, matching the iOS certificate |
| `HOMEBREW_TAP_REPOSITORY` | Variable | Proposed `JesusPaz/homebrew-tap`; create/choose the tap first |
| `HOMEBREW_TAP_TOKEN` | Secret | Fine-grained token for that tap only, contents + pull requests write and metadata read |

`GITHUB_TOKEN` publishes the container to GHCR and creates AFK's tag/release;
no additional Docker password is needed. Set the package visibility to **public**
after first publish and verify anonymous pulls before deploying homelab.

For Apple:
1. Register AFK's explicit iOS bundle ID `com.jesuspaz.afk.ios` in the existing team.
2. Create a new iOS App Store Connect app **AFK** with this bundle ID and a unique SKU.
3. Export/import the distribution credentials above. Team certificates can be shared
   across apps, but the iOS provisioning profile must be AFK's. AFK must have its own provisioning profile. Shared team credentials require
   explicit authorization before reuse; never put them in Git or chat.
4. In App Store Connect → AFK → TestFlight → Internal Testing → **+**, create the
   internal group with **Enable automatic distribution** selected. Apple then makes eligible
   uploads available to that group's testers after processing; uploading alone
   does not mean a build is ready to install. This is a group setting, not an Xcode
   export option, and does not require a per-release distribution script.
   See [Apple's internal tester setup](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers).
   If the group uses manual distribution, add each processed build explicitly.
5. Confirm current Apple agreements. `apps/apple/Info.plist` declares
   `ITSAppUsesNonExemptEncryption=false`, carrying forward the existing internal
   builds' export-compliance declaration so new uploads do not require answering
   the encryption questionnaire each time. This declares exemption from
   documentation, not absence of encryption: AFK uses end-to-end TLS 1.3 through
   bundled NIO/BoringSSL as well as Apple cryptography APIs. The current questionnaire
   answers are standard encryption in addition to Apple's APIs and no distribution
   in France. Reassess the declaration if encryption or distribution changes.
   Both EAS and local archives use this plist. Already uploaded builds still need
   their pending questionnaire completed; this change applies to new builds.
   See [Apple's export-compliance guidance](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation).

The shared retro keyboard icon source is `apps/apple/Artwork/retro-keyboard.png`.
Run `python3 scripts/release/make-beta-icon.py` on macOS to regenerate all catalog
sizes; PNGs have no alpha. Review it before
public branding. Both platforms include an asset catalog and required-reason privacy
manifest: app preferences (`CA92.1`), elapsed control-lease timing (`35F9.1`), and
SwiftTerm's file metadata access within the iOS app container (`C617.1`). Review the
privacy report when changing SwiftTerm. App Store privacy labels and a public privacy
policy remain a separate review: the relay persists device names, IDs and token hashes,
and sees encrypted traffic metadata. It does not receive terminal plaintext or
device private keys. Do not claim that no data is collected.

## Local Mac distribution

Local builds can use an installed Developer ID identity and a validated `notarytool`
Keychain profile; exporting the signing key to GitHub is not required. Do not run
`scripts/release/apple.sh` on the developer login keychain: it is runner-only.

1. Select a tested commit and an unused explicit release tag. Set numeric marketing
   and build versions, the public HTTPS relay URL, both `arm64 x86_64` architectures,
   and `ENABLE_HARDENED_RUNTIME=YES` for the Release archive.
2. Compile the archive with ad-hoc signing for build-time helper tools if necessary.
   Export with `xcodebuild -exportArchive`, method `developer-id`, destination
   `export`, manual signing and the installed Developer ID certificate/team. The
   exported application must be Developer ID signed, not ad hoc.
3. Verify `codesign --verify --deep --strict`, both executable architectures,
   hardened runtime, secure timestamp, bundle versions and embedded relay URL.
4. ZIP the app with `ditto -c -k --keepParent`. Submit using
   `xcrun notarytool submit <zip> --keychain-profile <profile>`. Store its submission
   ID; inspect status/logs and wait for **Accepted**, never infer success from upload.
5. Run `xcrun stapler staple <app>`, `xcrun stapler validate <app>` and
   `spctl --assess --type execute <app>`. Recreate the distribution ZIP after stapling,
   then create the DMG with `bash scripts/release/dmg.sh <app> <output.dmg>`.
6. Sign the DMG with the same Developer ID identity and a secure timestamp, submit
   it to notarytool, wait for Accepted, and staple/validate its ticket. Verify both
   the app and DMG with Gatekeeper. Calculate SHA-256 after stapling and publish
   those exact bytes to the release at the tested SHA. Generate the cask with
   `python3 scripts/release/cask.py <tag> <zip> <afk@preview.rb>`.

Keychain can require the Mac user's local approval when codesign accesses the
private key. Do not reset the keychain or change its access controls to avoid that
approval. Keep API private keys out of Git, logs and release assets. A credential
shared with another app requires authorization before retrieving/reusing it;
notarizing AFK must not revoke or reconfigure that app's credentials.

## Local iPhone / TestFlight

AFK has its own App Store Connect record, `AFK Remote Terminal` (ID `6823806445`),
with bundle `com.jesuspaz.afk.ios`. The `AFK Internal` group is internal-only and
has no public invitation link. Do not use Testa's bundle or provisioning profile.

For local distribution, use the installed Apple Distribution identity and AFK's
App Store provisioning profile. Compile a Release archive for
`generic/platform=iOS`, setting the public HTTPS relay URL and a new numeric build
number. An unsigned archive can be exported with manual distribution signing.
Use export options `method=app-store-connect`, `destination=export`,
`signingStyle=manual`, `signingCertificate=Apple Distribution`, the team ID and
`provisioningProfiles` mapping AFK's bundle to its installed profile UUID. Set
`manageAppVersionAndBuildNumber=false` and `testFlightInternalTestingOnly=true`.

Check the resulting IPA's identifier, version, relay endpoint and icon. Repeat
`xcodebuild -exportArchive` with `destination=upload`, API authentication key path,
key ID/issuer and `-allowProvisioningUpdates`. Keep any temporary API key private
and remove it when finished. Do not run the ephemeral-runner signing script on
the login keychain. Apple upload success is separate from processing, encryption
review and assignment to the internal test group. Enable automatic distribution
on the group to automate that last step. Only invite testers Jesus names.

## Build numbering and endpoint

The tag supplies Apple's numeric marketing version (`v0.1.0-rc.2` → `0.1.0`).
Both entry points allocate the build number from UTC minutes since 2020, split into
Apple's `major.minor.patch` limits (four/two/two digits). This exceeds local builds
1–7 and remains ordered across workflows. The shared queue prevents concurrent
uploads; do not dispatch EAS directly in parallel. Each retry allocates a new number.
Before retrying an interrupted upload, inspect the recorded EAS run and App Store
Connect to see whether Apple already accepted it.

The dispatcher exports **only tracked files at the tested commit**, uploads that
clean snapshot to EAS, and records its original SHA in the job. Local `.env`,
signing files and build directories are excluded. Both jobs consume that same
snapshot. GitHub waits for both jobs, downloads only the four expected Mac files,
and checks `SHA256SUMS` before publishing. iOS upload success still requires Apple
processing, export-compliance review and internal group assignment afterward.

`AFK_RELAY_URL` is embedded in Info.plist at archive time. Fresh installs use it;
existing `relayURL` preferences remain intact. Debug builds still default to localhost.
No credentials are embedded in the app. Release preflight rejects HTTP, non-public IP addresses, credentials in URLs, and
missing signing configuration; it also checks HTTPS `/readyz` before signing.

## First delivery order

1. Commit/push the reviewed AFK changes when authorized. Merge them to main after CI.
2. Run **Publish relay candidate**, download `relay-image.txt`, make GHCR public.
3. Finish the homelab PR prepared in `~/personal/homelab-afk-relay` (branch
   `afk-relay-publishing`), replace its proposed image with the real digest and configure
   Cloudflare Tunnel/DNS. Follow that repo's `infrastructure/afk-relay/README.md`.
4. Verify HTTPS readiness **and** physical-device WebSocket pairing/control/revocation.
5. Configure EAS Apple variables/secrets and GitHub `EXPO_TOKEN`, then run **TestFlight internal** for
   `v0.1.0-rc.1` and test the store-signed iPhone build.
6. Run **Release** on main for `v0.1.0-rc.1` to publish the notarized Mac and versioned
   relay. Review/merge the Homebrew tap PR; install with
   `brew install --cask JesusPaz/tap/afk@preview` from the public `JesusPaz/homebrew-tap` repository.
7. When ready for stable, publish `v0.1.0`, review the `afk` cask PR and remove the
   preview cask before installing stable. The two casks conflict intentionally.

## Recovery

- A failure before tag creation has not created a GitHub release. Fix the cause and
  rerun; a versioned GHCR image may already exist if the publish step failed later.
- If the publish job failed after pushing the tag, use **Re-run failed jobs**, not a
  fresh dispatch. It verifies that the tag points to the same tested commit, resumes
  a draft and uploads missing artifacts before publishing. Published assets are never
  overwritten. A fresh dispatch refuses an existing tag.
- If only Homebrew fails, rerun **Homebrew update** with the published tag after fixing
  tap configuration. An existing identical branch/PR is reused without force-pushing.
- If only Mac failed after a successful iOS upload, retry the tested source with
  `python3 scripts/release/eas-delivery.py <tag> mac` to avoid another iOS upload.
- If Apple accepted a build before a connection failure, inspect App Store Connect
  before rerunning: another run attempt produces a new build number and another upload.
- No automatic promotion to App Store review, external TestFlight, or homelab rollout.

## Local verification

```sh
python3 -m unittest discover -s scripts/release -p 'test_*.py'
actionlint .github/workflows/*.yml
bash -n scripts/release/apple.sh
docker build -t afk-relay:check server
swift test
./scripts/test-server.sh
```

A local unsigned Release archive verifies compilation, bundle metadata and assets;
it cannot verify Developer ID signing, notarization or App Store acceptance. Those
require the real credentials and workflow execution after publishing the code.

References: [Apple uploads](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/),
[GitHub container publishing](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images),
[Homebrew casks](https://docs.brew.sh/Cask-Cookbook),
[GitHub macOS runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md).

# Publishing AFK

Prepared locally on 2026-10-15. No Git commit, push, tag, release, store submission,
Homebrew PR or deployment has been made by this work. Tracks [MVP #3](https://github.com/JesusPaz/afk/issues/3).
Owner for activation and all external prerequisites: **JesusPaz**.

Testa (`~/personal/cefalea-app`, GitHub `JesusPaz/testa`) is the workflow reference:
separate a deliberate release from internal TestFlight delivery. AFK uses native
Xcode signing and upload instead of Testa's Expo/EAS credentials. Testa's app record,
App ID, provisioning profile and build numbers must not be reused for AFK.

## Workflows

| Workflow | Trigger | Result |
| --- | --- | --- |
| CI | PR, main push, reusable call | Go race + PostgreSQL, vet, Swift tests, both app builds, packaging tests, Docker build |
| Publish relay candidate | Manual, chosen branch/commit | After CI, pushes `ghcr.io/jesuspaz/afk-relay:sha-<full commit>` for amd64/arm64; uploads exact digest |
| Release | Manual on main, explicit `vX.Y.Z` or `vX.Y.Z-rc.N` | CI → signed/notarized universal Mac ZIP → versioned relay image → annotated tag at tested SHA → GitHub Release → Homebrew PR |
| TestFlight internal | Manual, chosen branch/commit + version label | CI → signed iOS archive → internal-only upload; no Git tag or public App Review |
| Homebrew update | Called after release, or manual retry | Downloads release cask and opens a PR in your configured tap; never auto-merges |

Version input is explicit rather than calculated from commit messages. Start with
`v0.1.0-rc.1`, then `v0.1.0-rc.2`; use `v0.1.0` only when ready. RC releases are
marked prerelease and never latest. Stable releases become latest. Do not release
an older stable version after a newer one with this workflow.

The same selected commit flows through all reusable workflows. Publication is
invoked directly: it does not depend on a tag pushed with `GITHUB_TOKEN` triggering
another workflow (GitHub suppresses that recursive trigger).

Mac artifacts: `AFK-v<version>-macOS.zip`, `SHA256SUMS`, `relay-image.txt`, and
`afk.rb` / `afk@preview.rb`. The ZIP contains a Developer ID-signed, stapled app for
both Apple Silicon and Intel. Homebrew verifies its SHA-256 and requires macOS 14+.
No unsigned fallback and no `sha256 :no_check`.

## GitHub and Apple setup

Create GitHub environments `release`, `testflight`, and `homebrew`. Restrict
`release`/`homebrew` to main and trusted release tags; only permit trusted branches
in `testflight`. Add the variables/secrets below at repository or appropriate
environment scope. There were no repository variables or secrets in AFK when checked.

| Name | Kind | Used by |
| --- | --- | --- |
| `APPLE_TEAM_ID` | Variable | Both Apple workflows; your existing paid Apple Developer team |
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
   across apps, but the iOS provisioning profile must be AFK's. Do not copy credentials
   out of Testa's EAS setup or put them in Git or chat.
4. Set up an internal TestFlight group in AFK's app record. Upload success means Apple
   accepted the transfer; processing and adding the build to a tester group happen next.
5. Confirm current Apple agreements and export-compliance answers. This POC declares
   no non-exempt encryption: TLS and platform authentication only, no custom E2EE.
   Revisit this declaration when E2EE is implemented.

The generated blue pixel-wordmark icon is **provisional beta artwork**. Source:
`scripts/release/make-beta-icon.py`; RGB PNGs have no alpha. Review/replace it before
public branding. Both platforms include an asset catalog and required-reason privacy
manifest: app preferences (`CA92.1`), elapsed control-lease timing (`35F9.1`), and
SwiftTerm's file metadata access within the iOS app container (`C617.1`). Review the
privacy report when changing SwiftTerm. App Store privacy labels and a public privacy
policy remain a separate review: the relay persists device names, IDs and token hashes,
and can see terminal traffic. Do not claim that no data is collected or that AFK is E2EE.

## Build numbering and endpoint

The tag supplies Apple's numeric marketing version (`v0.1.0-rc.2` → `0.1.0`).
`github.run_number.github.run_attempt` supplies the build version; TestFlight has its
own serial workflow queue. A rerun increments the attempt. Keep this workflow's
identity/counter; when migrating from manual uploads or renaming it, verify the next
build number exceeds the latest one in App Store Connect. Never reuse a build number.

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
5. Configure GitHub Apple variables/secrets, then run **TestFlight internal** for
   `v0.1.0-rc.1` and test the store-signed iPhone build.
6. Run **Release** on main for `v0.1.0-rc.1` to publish the notarized Mac and versioned
   relay. Review/merge the Homebrew tap PR; install with
   `brew install --cask JesusPaz/tap/afk@preview` if that is the chosen tap.
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

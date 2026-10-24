# Releasing

How to ship a new version of both apps. The details behind each step (credentials,
workflows, signing) are in the [publishing reference](publishing.md).

## 1. Pick the version

Versions are explicit: `v0.1.0-rc.N` for betas, `v0.1.0` when stable. Use the next
number after the latest one:

```sh
gh release list --limit 1
```

A failed attempt that never published can reuse its number.

## 2. Make sure `main` is ready

Everything to ship is merged and CI passed on exactly the current `main` commit:

```sh
git fetch origin
gh run list --workflow ci.yml --commit "$(git rev-parse origin/main)" --limit 1
```

## 3. Release

### From this Mac (default while EAS minutes are exhausted)

```sh
cd ~/personal/afk
git fetch origin
scripts/release/local.sh v0.1.0-rc.N
```

It takes about 20–30 minutes, mostly notarization. The script:

1. Refuses to start unless CI passed on `origin/main`, the release isn't published,
   the relay is up, and the signing identities, notary profile and App Store profile
   are present.
2. Builds a clean checkout of `origin/main` (your working tree is never used).
3. Mac: universal app signed with Developer ID, notarized and stapled; DMG, ZIP,
   `SHA256SUMS` and the Homebrew cask.
4. iPhone: uploads the build to TestFlight (internal testing only).
5. Builds the relay image on GitHub and waits for it.
6. Creates the tag and the GitHub Release with all files.
7. Updates Homebrew when the `HOMEBREW_TAP_REPOSITORY` repo variable is set (it is);
   the tap PR merges by itself.

It ends with `==> Done: <release URL>`.

What it needs on this Mac (already set up):

| Need | Where |
| --- | --- |
| Developer ID Application and Apple Distribution certificates | Login keychain |
| Notarization credentials | `notarytool` keychain profile `AFK` |
| iPhone App Store profile for `com.jesuspaz.afk.ios` | Xcode provisioning profiles |
| Apple account for the TestFlight upload | Xcode → Settings → Accounts |
| `gh` signed in with access to `JesusPaz/afk` | `gh auth status` |

### On EAS (when minutes are available)

```sh
gh workflow run release.yml --ref main -f tag=v0.1.0-rc.N
```

Same result, built on Expo's servers. The free plan has 60 CI minutes per month,
which is about three releases; it resets on the 1st.

## 4. After the release

- **Mac:** `brew upgrade --cask afk@preview` (quit AFK yourself first; quitting ends
  its sessions).
- **iPhone:** the build shows up in TestFlight after Apple finishes processing
  (usually 5–15 minutes). If it doesn't appear for testers, add it to the
  **AFK Internal** group in App Store Connect.
- Check the release page lists the DMG, ZIP, the cask (`afk@preview.rb` for an RC,
  `afk.rb` for stable), `SHA256SUMS` and `relay-image.txt`.

## If something fails

| Where it stopped | What to do |
| --- | --- |
| Before `==> Publishing` | Nothing was published. Fix the cause and run the same command again. An iPhone build that was already uploaded stays in TestFlight; that's fine. |
| During `==> Publishing` | Run the same command again. It rebuilds and notarizes everything (and uploads one more TestFlight build), then reuses the existing tag or draft release. If `main` moved meanwhile, it refuses: delete the draft and the tag (`gh release delete vX --cleanup-tag`) and release from the new `main`. |
| `CI has not passed` | Wait for CI on `main`, or fix it first. |
| Notarization rejected | Read the log with `xcrun notarytool log <id> --keychain-profile AFK`. |
| EAS: `Free plan ... limit reached` | Use the local release instead. |
| Homebrew step | Retry with `gh workflow run homebrew.yml --ref main -f tag=v0.1.0-rc.N`. |

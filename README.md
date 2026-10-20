# AFK

Your terminal, with you. Native macOS and iPhone apps sharing a real shell running on your Mac.

**Personal beta — not independently audited.** Device transport v2 uses end-to-end mutual TLS 1.3 inside WSS, local one-use enrollment and persistent device authorization. Signed distribution and independent security review remain release gates. See [security and boundaries](docs/security.md).

## Monorepo

| Path | Responsibility |
| --- | --- |
| `apps/apple` | Native SwiftUI macOS / iPhone apps, SwiftTerm terminal views |
| `packages/AFKCore` | Wire protocol, networking, Keychain, input lease, bounded replay |
| `packages/AFKHost` | macOS PTY ownership and authoritative session control |
| `apps/host-cli` | Headless Swift host for integration tests |
| `server` | Go HTTP/WebSocket relay, PostgreSQL identities and revocation |
| `deploy` | Isolated local PostgreSQL environment |
| `openspec/changes/afk-poc` | POC scope and acceptance scenarios |

One shell runs on the Mac. Both apps render the same output; only the current controller may write. PostgreSQL stores device identity and pairing metadata, **not terminal output or keystrokes**.

## Run locally

Requires macOS 14+, Xcode 26.3 (including its Metal Toolchain and an iOS simulator runtime), Go 1.26.9+, Docker Compose and Python 3. iPhone target: iOS 17+. Dependencies are locked in `go.sum` and `Package.resolved`.

```sh
./scripts/setup-dev.sh
docker compose --env-file .env -f deploy/compose.yaml up -d --wait
./scripts/dev-relay.sh
```

Open `apps/apple/AFK.xcodeproj`. Run scheme **AFKMac** on your Mac, then **AFKiOS** on an iPhone simulator. Both default to `http://127.0.0.1:8787`.

When launching a built Mac app from an automation terminal, use `./scripts/dev-mac.sh /path/to/AFK.app`. With no argument it uses `.artifacts/ResizeReview/Build/Products/Debug/AFK.app`. This foreground launcher removes inherited `NO_COLOR`, `FORCE_COLOR`, `CLICOLOR` and `CLICOLOR_FORCE` overrides from development tooling, while preserving the rest of the environment. It refuses to launch while AFK is running; quitting the existing app ends its shell sessions.

AFK sessions advertise `TERM=xterm-256color`, `COLORTERM=truecolor` and `TERM_PROGRAM=AFK`, and discard an inherited `TERM_PROGRAM_VERSION` belonging to another terminal. Normal app launches preserve color preferences, including `NO_COLOR`; shell startup files can also set these explicitly. AFK does not force applications to emit color.

On Mac, drag files from Finder onto the active terminal to insert their shell-quoted
paths. Multiple files, spaces and quotes are supported; dropping never presses Enter.
The Mac must have typing control. This inserts local paths, not file uploads.

AFK connects to the saved relay when the Mac app opens, unless remote access was explicitly paused. Pausing persists across launches. Development builds signed ad hoc may ask for Keychain authorization again after recompilation; use a consistent Apple signing identity for a stable development identity.

If an iPhone session cannot open, its error remains visible and **Copy diagnostics**
copies the failure time, connection stage/category, iOS version and AFK build.
Diagnostics contain no terminal text, file paths, server addresses or credentials.
After reconnecting, the phone waits for the authorized session list before restoring
the selected session. Update both apps for the fix to Codex screen restoration after
switching between wide Mac and narrow iPhone layouts.

1. On Mac, a local shell opens immediately. Choose **Vincular iPhone**.
2. On iPhone, choose **Vincular Mac**, scan the QR (or paste the invitation), and confirm the displayed server. Compare the code on both screens, then approve on the Mac with local authentication.
3. On Mac, open **Dispositivos → Sesiones y permisos** and explicitly share sessions. Pairing alone exposes none. Choose read-only or temporary control (15 minutes, 1 hour, 8 hours); creation and closing are separate permissions. On iPhone, open a shared session and take control if allowed.
4. On Mac, choose **Recuperar control** (`⌘⇧L`) to write locally again.
5. Manage linked phones and access history under **Dispositivos**. Five minutes without accepted input downgrades control to read-only. **Cortar todo acceso remoto** clears session grants; revocation also removes device trust. Both leave local terminals running. Grants are cleared when AFK quits.

The secure invitation expires in five minutes and works once. Saved device credentials live in Keychain. A physical iPhone requires signing with your own Apple development team and a reachable **HTTPS** relay; localhost on a physical iPhone is the phone itself. The personal beta relay is deployed on Helena; its public Cloudflare route is configured separately.

The checked-in Xcode project is generated from `apps/apple/project.yml` using XcodeGen 2.46.0. Regenerate with `xcodegen generate --spec apps/apple/project.yml` after changing project configuration.

## Verify

```sh
swift test
./scripts/test-server.sh
swift build
./scripts/test-secure.sh
```

The last command runs a real Swift PTY with two mutually authenticated, encrypted clients and checks pairing, control, stale-input rejection, resize, replay, reconnection and revocation. PostgreSQL tests use unique identities and remove their records. Without `AFK_TEST_DATABASE_URL`, direct `go test` skips database tests; the script configures the local database.

Native build checks:

```sh
xcodebuild -project apps/apple/AFK.xcodeproj -scheme AFKMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation
xcodebuild -project apps/apple/AFK.xcodeproj -scheme AFKiOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation
```

The unsigned commands above are compile checks. To **run** the iPhone simulator build from the command line, use `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`; otherwise Keychain reports error `-34018`. Running from Xcode signs the simulator app automatically.

`-skipPackagePluginValidation` is for these development builds with the pinned SwiftTerm package. Review dependency changes before running their build plugins.

## Current boundaries

- Up to eight sessions and eight connected clients per Mac; iPhone remembers one Mac.
- The current controller determines the shared terminal size: Mac window or iPhone viewport (including rotation and keyboard). Observers retain that grid and can scroll when it is larger than their screen. Updated iPhones open the current screen immediately and fetch older history automatically when scrolling backward. The Mac keeps the complete recording on disk. Older iPhones still use the 256 KiB snapshot protocol; update both apps for long sessions.
- Sessions survive closing the Mac window, **not quitting AFK, reboot or sleep with an active network connection**. There is no separate background helper yet.
- Manual reconnect. No offline keystroke queue or automatic retries of input.
- SwiftUI screens implement the functional flows; final visual polish and accessibility/device validation remain.
- No signed installer, App Store release, accounts, file transfer, audio, screen mirroring, Android, Windows or Linux host.

See [architecture](docs/architecture.md), [protocol](docs/protocol.md), [roadmap](docs/roadmap.md). MIT licensed.

## Trusted devices

New pairings use Secure Enclave identities. iPhone requires enrolled Face ID/Touch ID
for each connection; the Mac proves possession of its own pinned hardware key.
In **Devices**, explicitly choose **Trust this device…** to grant persistent access
to all current/future sessions and permission to create/close them. Mac authentication
is required. **Remove trust** disconnects the phone; **Stop all remote access** also
removes persistent grants. Session permissions remain available from the Session menu.

For an existing software identity, choose **Protect Mac identity…** first and confirm
removing old pairings. Then pair the updated iPhone app again and grant trust.
Changing enrolled phone biometrics requires pairing again. Secure Enclave is required
for new identities; simulator/software fallback is not enabled in the app.
See [security boundaries](docs/security.md) and [protocol](docs/e2ee.md).

## Saved terminal history

Mac sessions now record all output and ordered size changes under
`~/Library/Application Support/AFK/Session History`. Recordings survive quitting AFK
and restarting the Mac until explicitly deleted in **Saved history**. They do not
restart the shell or execute recorded commands. Active recordings cannot be deleted;
end the session first. Existing sessions from an older app cannot recover output
already discarded before this feature was installed.

Switching sessions keeps each live renderer attached, including its alternate screen
and background updates. The live Mac terminal retains 10,000 scrollback lines in RAM.
**Saved history** provides a recording-position slider and previous/next controls to
browse the complete disk recording in bounded batches, including earlier output
outside live scrollback. Opening a recording of an active session captures its current
length; reopen it to refresh. Reopening a live window reconstructs the renderer from
the recording, which can take time for long sessions.

On iPhone, scroll backward in the terminal to load older rows automatically. There is
no separate history menu and opening a session does not download its full recording.
In alternate-screen applications such as Codex, history belongs to the application:
while controlling the session, a vertical drag sends wheel events just like the Mac.
Take control with **Write from here** to browse that application-owned history.
Pages for normal shell history contain at most 64 rows / 64 KiB. The phone prefetches
one page after showing the current screen and keeps a bounded in-memory cache for
the current attachment, including when returning to live. It renders at most 256
historical rows plus the current screen; leaving the session clears the cache. Scrolling forward fetches newer pages and returns to live
output. New output does not move the row being read. Choosing **Write from here**
returns to the current screen before enabling input. Both apps need this update.

The Mac builds an owner-only, disk-indexed row archive alongside its original ANSI
recording. Rows retain their rendered text and colors at the width where they entered
history; the raw recording remains available in Mac **Saved history**, including
terminal redraws. The iPhone uses bounded memory rather than a complete disk copy.

The recording files are owner-only (directories `0700`, files `0600`), contain terminal
output that may include secrets, and are not separately encrypted by AFK. They never
go to the relay. There is no automatic age/size deletion; available disk space is the
limit. A recording failure is shown in the session while the shell continues running.
Normal termination flushes the file; a crash/power loss can leave an incomplete tail,
reported when reading it. This does not guarantee recovery of unwritten output.

## Languages

The Mac and iPhone apps support English and Spanish. Each app follows the device’s preferred languages (including regional variants such as es-CO and en-GB), with English as the fallback. macOS/iOS per-app language settings are supported; relaunch AFK after changing the language. No in-app language picker is required.

Shared UI, accessibility and error translations live in `packages/AFKCore/Sources/AFKCore/Resources/{en,es}.lproj/Localizable.strings`. Native permission descriptions live in `apps/apple/Resources`. Keep both catalogs’ keys and format arguments in sync; `swift test` verifies them. Session names, shell output, commands and credentials are never translated. Adding another language also requires declaring it in the app’s `CFBundleLocalizations` and the shared language resolver.

## Distribution

Download the signed, notarized universal Mac DMG from [GitHub Releases](https://github.com/JesusPaz/afk/releases), open it and drag AFK to Applications. Beta releases also include a ZIP.

Install the preview with Homebrew:

```sh
brew install --cask JesusPaz/tap/afk@preview
```

Update it with `brew upgrade --cask afk@preview`. If you already installed AFK manually, quit it and move the old app out of Applications before switching to Homebrew. Quitting AFK ends its shell sessions.

iPhone builds are distributed through the existing internal TestFlight group. Live dictation with delivery confirmation requires the updated app on both devices; see [dictation behavior and validation](docs/dictation.md).

See [publishing and required credentials](docs/publishing.md) for release, signing and tap maintenance, and [local delivery history](docs/local-delivery.md).

### Recognizing and organizing sessions

On Mac, rename a session or use its automatic terminal title, then organize sessions
into named groups with a symbol and color. A manual name takes precedence over OSC
0/2 titles; OSC 7 supplies directory context when the shell announces it. iPhone
shows the same authorized names and groups. Group editing is currently Mac-only.
Choose a flat system symbol or a single emoji using the macOS character picker.
Groups remain saved and visible even after their last session closes, including
after restarting AFK; their shell processes are not restored.

On Mac, use the profile selector above the sidebar to switch between **Personal**,
**Work**, and custom profiles created with **+ → New profile…**.
Each profile shows its own groups, ungrouped sessions, hidden sessions and ended
sessions. Existing organization starts in Personal. New groups and sessions belong
to the selected profile. Use **Move to profile** in a group or session's context
menu; moving a group includes its sessions, while moving a single session removes
it from its old group. Switching profiles clears the selected terminal and keeps
all shells and renderers running without changing typing control.
Drag sessions onto a group header or another session in that group to move them.
Drop onto **Ungrouped** to remove their group; this destination stays visible even
when empty. Profile names, group assignments and the selected profile survive app
relaunch; shells do not.
Restoring a terminal recording yields between bounded batches and shows progress;
input remains disabled until restoration completes. An unavailable history archive
shows a notice while the remote live screen continues updating.

Profiles organize the Mac workspace locally. iPhone access still follows the
existing session permissions, and Saved history remains a shared archive.

Hide keeps a session running and can be undone. Hidden state is local to each device.
Close and remove waits for the shell and foreground process group to exit, then
removes the row while preserving saved history. Detached processes and external
services are outside that guarantee. Ended sessions have a separate section and do
not consume the eight-live-session limit. Hiding or removing the selected session
never transfers typing to another terminal automatically.

See [the feature plans and validation](docs/plans/session-organization/README.md).

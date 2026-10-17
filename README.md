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

AFK connects to the saved relay when the Mac app opens, unless remote access was explicitly paused. Pausing persists across launches. Development builds signed ad hoc may ask for Keychain authorization again after recompilation; use a consistent Apple signing identity for a stable development identity.

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
- The current controller determines the shared terminal size: Mac window or iPhone viewport (including rotation and keyboard). Observers retain that grid and can scroll when it is larger than their screen. ANSI output and ordered resize events are replayed within a 256 KiB budget; after overflow, attaching fails explicitly while the local process continues.
- Sessions survive closing the Mac window, **not quitting AFK, reboot or sleep with an active network connection**. There is no separate background helper yet.
- Manual reconnect. No offline keystroke queue or automatic retries of input.
- SwiftUI screens implement the functional flows; final visual polish and accessibility/device validation remain.
- No signed installer, App Store release, accounts, file transfer, audio, screen mirroring, Android, Windows or Linux host.

See [architecture](docs/architecture.md), [protocol](docs/protocol.md), [roadmap](docs/roadmap.md). MIT licensed.

## Languages

The Mac and iPhone apps support English and Spanish. Each app follows the device’s preferred languages (including regional variants such as es-CO and en-GB), with English as the fallback. macOS/iOS per-app language settings are supported; relaunch AFK after changing the language. No in-app language picker is required.

Shared UI, accessibility and error translations live in `packages/AFKCore/Sources/AFKCore/Resources/{en,es}.lproj/Localizable.strings`. Native permission descriptions live in `apps/apple/Resources`. Keep both catalogs’ keys and format arguments in sync; `swift test` verifies them. Session names, shell output, commands and credentials are never translated. Adding another language also requires declaring it in the app’s `CFBundleLocalizations` and the shared language resolver.

## Distribution

GitHub Actions workflows prepare relay images in GHCR, signed/notarized macOS releases, Homebrew tap updates and internal TestFlight uploads. See [publishing and required credentials](docs/publishing.md). The personal relay beta `v0.1.0-rc.1` is published and deployed on Helena. See [local delivery and test evidence](docs/local-delivery.md); Apple signing and TestFlight remain pending.

# Development

## Run locally

Requires macOS 14+, Xcode 26.3 (including its Metal Toolchain and an iOS simulator runtime), Go 1.26.10+, Docker Compose and Python 3. iPhone target: iOS 17+. Dependencies are locked in `go.sum` and `Package.resolved`.

```sh
./scripts/setup-dev.sh
docker compose --env-file .env -f deploy/compose.yaml up -d --wait
./scripts/dev-relay.sh
```

Open `apps/apple/AFK.xcodeproj`. Run scheme **AFKMac** on your Mac, then **AFKiOS** on an iPhone simulator. Both default to `http://127.0.0.1:8787`.

When launching a built Mac app from an automation terminal, use `./scripts/dev-mac.sh /path/to/AFK.app`. With no argument it uses `.artifacts/ResizeReview/Build/Products/Debug/AFK.app`. This foreground launcher removes inherited `NO_COLOR`, `FORCE_COLOR`, `CLICOLOR` and `CLICOLOR_FORCE` overrides from development tooling, while preserving the rest of the environment. It refuses to launch while AFK is running; quitting the existing app ends its shell sessions.

AFK sessions advertise `TERM=xterm-256color`, `COLORTERM=truecolor` and `TERM_PROGRAM=AFK`, and discard an inherited `TERM_PROGRAM_VERSION` belonging to another terminal. Normal app launches preserve color preferences, including `NO_COLOR`; shell startup files can also set these explicitly. AFK does not force applications to emit color.

The checked-in Xcode project is generated from `apps/apple/project.yml` using XcodeGen 2.46.0. Regenerate with `xcodegen generate --spec apps/apple/project.yml` after changing project configuration.

Development builds signed ad hoc may ask for Keychain authorization again after recompilation; use a consistent Apple signing identity for a stable development identity. A physical iPhone requires signing with your own Apple development team and a reachable **HTTPS** relay; localhost on a physical iPhone is the phone itself. The personal beta relay is deployed on Helena; its public Cloudflare route is configured separately.

## Translations

Shared UI, accessibility and error translations live in `packages/AFKCore/Sources/AFKCore/Resources/{en,es}.lproj/Localizable.strings`. Native permission descriptions live in `apps/apple/Resources`. Keep both catalogs’ keys and format arguments in sync; `swift test` verifies them. Session names, shell output, commands and credentials are never translated. Adding another language also requires declaring it in the app’s `CFBundleLocalizations` and the shared language resolver.

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

## Repository layout

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

See [architecture](architecture.md), [releasing](releasing.md) and the [local delivery history](local-delivery.md).

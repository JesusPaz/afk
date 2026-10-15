# AFK

Your terminal, with you. Native macOS and iPhone apps sharing a real shell running on your Mac.

**Developer POC — not a production remote-access service.** This version uses a trusted relay that can read terminal traffic. End-to-end encryption, signed distribution and unattended operation are required before a public service. See [security and boundaries](docs/security.md).

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

Requires macOS 14+, Xcode 26.3 (including its Metal Toolchain and an iOS simulator runtime), Go 1.25.7+, Docker Compose and Python 3. iPhone target: iOS 17+. Dependencies are locked in `go.sum` and `Package.resolved`.

```sh
./scripts/setup-dev.sh
docker compose --env-file .env -f deploy/compose.yaml up -d --wait
./scripts/dev-relay.sh
```

Open `apps/apple/AFK.xcodeproj`. Run scheme **AFKMac** on your Mac, then **AFKiOS** on an iPhone simulator. Both default to `http://127.0.0.1:8787`.

1. On Mac, a local shell opens immediately. Choose **Vincular iPhone**.
2. On iPhone, choose **Vincular Mac** and enter the Mac code and temporary password.
3. Open a session. It starts read-only; choose **Tomar control** to type.
4. On Mac, choose **Recuperar control** (`⌘⇧L`) to write locally again.
5. Manage linked phones under **Dispositivos**. Revocation disconnects that device and invalidates its saved credential.

The temporary password expires in five minutes and works once. Saved device credentials live in Keychain. A physical iPhone requires signing with your own Apple development team and a reachable **HTTPS** trusted relay; localhost on a physical iPhone is the phone itself. No default public relay is deployed by this repository.

The checked-in Xcode project is generated from `apps/apple/project.yml` using XcodeGen 2.46.0. Regenerate with `xcodegen generate --spec apps/apple/project.yml` after changing project configuration.

## Verify

```sh
swift test
./scripts/test-server.sh
swift build
AFK_TEST_HOST_BINARY="$PWD/.build/debug/afk-host" ./scripts/test-server.sh
```

The last command starts a real Swift PTY host, routes its output to two clients, checks control transfer / stale-input rejection, replays history and exits the shell. PostgreSQL tests use unique identities and remove their records. Without `AFK_TEST_DATABASE_URL`, direct `go test` skips database tests; the script configures the local database.

Native build checks:

```sh
xcodebuild -project apps/apple/AFK.xcodeproj -scheme AFKMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation
xcodebuild -project apps/apple/AFK.xcodeproj -scheme AFKiOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation
```

The unsigned commands above are compile checks. To **run** the iPhone simulator build from the command line, use `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`; otherwise Keychain reports error `-34018`. Running from Xcode signs the simulator app automatically.

`-skipPackagePluginValidation` is for these development builds with the pinned SwiftTerm package. Review dependency changes before running their build plugins.

## Current boundaries

- Up to eight sessions and eight connected clients per Mac; iPhone remembers one Mac.
- Fixed 80×24 terminal. Initial ANSI output is replayed up to 256 KiB; after overflow, attaching fails explicitly while the local process continues.
- Sessions survive closing the Mac window, **not quitting AFK, reboot or sleep with an active network connection**. There is no separate background helper yet.
- Manual reconnect. No offline keystroke queue or automatic retries of input.
- SwiftUI screens implement the functional flows; final visual polish and accessibility/device validation remain.
- No E2EE, QR pairing, signed installer, App Store release, public relay deployment, accounts, file transfer, audio, screen mirroring, Android, Windows or Linux host.

See [architecture](docs/architecture.md), [protocol](docs/protocol.md), [roadmap](docs/roadmap.md). MIT licensed.

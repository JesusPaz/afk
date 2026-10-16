> Historical prototype. AFKCore now implements the production path and contains the attack tests. See ../../docs/e2ee.md.

# AFK peer TLS experiment

Tracking: [MVP #3](https://github.com/JesusPaz/afk/issues/3). Owner: JesusPaz.
This is a tested transport experiment for **already verified device identities**.
It is not imported by AFKCore, the apps, or the deployed relay. Existing AFK v1
sessions still trust the relay and are not end-to-end encrypted.

## Run

```sh
swift test --package-path experiments/e2ee-tls
```

Requires the project's macOS/Xcode environment and `/usr/bin/openssl` for test
fixtures only. Tests generate fresh P-256 keys in a private temporary directory
and delete them afterward. No test keys are checked in or used in real apps.
Dependencies are pinned; the experiment has its own `Package.resolved`.

## Implemented

- TLS 1.3 through SwiftNIO SSL 2.37.5 (BoringSSL), with SwiftNIO 2.104.0.
- Mutual certificate authentication against the explicitly supplied peer trust
  anchor; normal chain/signature/time validation stays enabled.
- An additional exact DER certificate pin prevents trusting delegated certificates.
- Required `afk-e2ee/2` ALPN and a gate before application dispatch. Writes before
  authentication fail instead of accumulating pending terminal commands.
- Fresh connections in the harness; no early data or application input retry.

`PinnedTLS.context` alone is insufficient: both the pinned client/server handler
and `PeerProtocolGate` must be installed, in that order, before application framing.
Test identity certificates are self-signed trust anchors (CA with pathlen=0);
this is a fixture format, not a selected production certificate lifecycle.

## Verification — 2026-10-16

13 tests passed on macOS. The library target also compiled for iOS 17 Simulator:

```sh
swift build --package-path experiments/e2ee-tls --target AFKSecureTransport \
  --triple arm64-apple-ios17.0-simulator \
  --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
```

Logs: `.artifacts/e2ee-tests.log` and `.artifacts/e2ee-ios-build.log` in the AFK checkout.
This compile check does not establish runtime behavior on an iPhone.

## Tested attacks

The in-memory relay sees only TLS records. Tests cover both-direction plaintext
absence and correct delivery under fragmentation, substituted Mac and phone
identities, delegated certificates despite a valid chain, missing client identity,
missing AFK ALPN, TLS 1.2 downgrade, pre-authentication commands, modified records,
duplicated records, replay into a fresh connection, reordered records and partial
records. Successful authentication and delivery are positive controls.

These tests demonstrate the configured TLS channel, not a security audit or the
security of AFK's full enrollment, WebSocket routing, UI and persistent storage.

## Promotion gates

- NIOSSL's **additional** verification hook is currently underscored. Decide how
  to support that API before production; do not replace it with a permissive
  custom verification callback that discards certificate validation.
- `NIOEmbedded` is a test transport, not an app event loop. Implement a real NIO
  transport adapter for the WebSocket byte stream, with bounded reads/writes and
  connection-generation isolation; verify on physical iPhone as well as Mac.
- Implement certificate/key generation and Keychain persistence on both Apple
  platforms. Test expiry/renewal, reinstall, backup restore and loss of keys.
- Implement authenticated first pairing and local revocation. The current relay
  pairing password is known to the relay and cannot bootstrap E2EE trust.
- Independently review the completed protocol and integration before describing
  AFK as a secure E2EE product. See [design and acceptance](../../docs/e2ee.md).

References: [Apple SwiftNIO SSL](https://github.com/apple/swift-nio-ssl),
[additional verification semantics](https://github.com/apple/swift-nio-ssl/blob/2.37.5/Sources/NIOSSL/SSLCallbacks.swift),
[TLS 1.3](https://www.rfc-editor.org/rfc/rfc8446).

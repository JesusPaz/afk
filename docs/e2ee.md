# AFK device transport v2

Implemented in `AFKCore` and the native apps. This is a personal beta, not an
independently audited remote-access product. Tracking: #3, owner @JesusPaz.

## Trust and enrollment

The Mac and iPhone generate independent P-256 certificate/private-key identities.
Keychain stores each identity with device-only accessibility. The phone record
requires an unlocked device; the Mac can retain its host identity while serving.
No private key or enrollment capability is sent to the relay HTTP API.

The Mac creates `AFK2:` invitations locally, containing protocol version, canonical
HTTPS origin, host UUID/code, SHA-256 certificate pin, invitation UUID, random
256-bit capability and a five-minute expiry. The Mac persists only the capability
hash, expiry and attempt counter. An invitation has five attempts and one use.
The native Mac UI requires local device-owner authentication to create it. Copying
is explicit; the clipboard item is marked concealed/transient and cleared after
five minutes if the user has not replaced it. Treat it like a temporary key.

The phone validates the invitation and persists its candidate identity before
connecting. Relay registration creates transport credentials only, not permission
to execute commands. Inside mutual TLS the phone sends a hello binding the origin,
host ID, client ID and fresh nonce to the enrollment capability. The host validates
that context and the TLS peer certificate, then atomically saves the authorized
peer and consumes the invitation **before** sending welcome. The phone verifies
the echoed context/nonce and its certificate fingerprint, then persists the
accepted connection before exposing application messages.

If welcome is lost, the same persisted device identity can reconnect. A different
certificate, copied ID or consumed invitation cannot grant another device access.
Legacy credentials never downgrade or automatically authorize v2. Re-pair old apps.

## Wire transport

Each phone has its own binary WebSocket tunnel. Host control `/v2/control` receives
opaque channel offers; `/v2/accept/{id}` joins one with host credentials. Phones use
`/v2/connect`. Control messages are untrusted routing hints, never authorization.
Only a locally authorized certificate can deliver commands to `HostController`.

Public connections require HTTPS/WSS with normal CA/hostname verification and a
TLS 1.3 minimum. Plain HTTP is permitted only for exact loopback development hosts.
Redirects are refused. Within WebSocket, NIOSSL/BoringSSL runs a separate mutually
authenticated **TLS 1.3** session with ALPN `afk-e2ee/2`. No plaintext fallback,
TLS 1.2, CA delegation, custom cipher, or application 0-RTT path exists.

Inner certificate verification intentionally uses direct device pins rather than
Web PKI: exactly one certificate, valid dates, and an exact saved certificate or
invitation fingerprint. During an active enrollment window an unknown phone can
complete TLS, but cannot execute any command until capability validation commits.
TLS CertificateVerify proves key possession; no trust is derived from a certificate
issuer or self-signature. Session record integrity, ordering, ephemeral key exchange
and replay rejection are provided by TLS, not by application-made crypto.

Encrypted application packets use a 4-byte big-endian length and bounded JSON.
The TLS protocol gate refuses app writes before authentication. Incoming dispatch
and outgoing queues are bounded to 16 messages / 1 MiB; a packet is at most 512 KiB.
WebSocket messages are binary, at most 64 KiB, with no compression. Slow or invalid
peers disconnect; uncertain input is discarded, never resent automatically.

## Revocation and local access

The Mac persists revocation first, closes the channel and then requests relay
revocation. It works locally even if the relay ignores the request or is offline.
A persistence failure closes all remote access and reports an error. Viewing the
devices list while paused does not resume access. Current local peer authorization
is checked on every application packet; input also needs the current lease epoch
and a fresh sequence. The relay rechecks transport credentials every 30 seconds,
pings peers, and caps connection lifetime at eight hours.

The native iPhone UI requires Face ID/Touch ID or the device passcode for pairing
and each connection. Backgrounding invalidates pending local authentication,
closes transport, and clears visible terminal contents. A privacy overlay hides
content while inactive. Late HTTP/TLS results cannot reopen a suspended generation.
No remote configuration, clipboard synchronization, file-transfer endpoint or
system-wide phone control is exposed. A paired phone can access all AFK shells;
that is full authority as the Mac user, not a sandboxed command permission.

## Verification

- `swift test`: production TLS pinning, missing/substitute/delegated identities,
  TLS downgrade and ALPN, tampered/replayed/reordered/cross-session/incomplete
  records, fragmented bidirectional encryption, pre-auth writes; invitation expiry,
  attempt persistence, one use, restart, lost welcome, failed writes, revocation;
  untrusted outer WSS certificate; local-auth denial, no caching, stale unlock.
- `./scripts/test-server.sh`: Go race detector with real PostgreSQL, token/role
  checks, legacy rejection, opaque routing, revoked credentials, malformed/text/
  oversized frames and aggregate probe/metrics behavior.
- `./scripts/test-secure.sh`: two real native TLS phones, Mac PTY, command output,
  exclusive control, stale-owner input, resize, snapshot, reconnect and revocation.
  Test database identities and current test Keychain records are removed.
- `go run golang.org/x/vuln/cmd/govulncheck@v1.9.0 ./...`: dependency vulnerability check.

The earlier `experiments/e2ee-tls` is historical design evidence. Production uses
the supported custom verification API, not that prototype's underscored API.
Physical Face ID, device backgrounding and public Cloudflare WSS still need an
actual iPhone test. Automated local checks are not a substitute for a security audit.

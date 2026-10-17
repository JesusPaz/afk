# AFK device transport v2

Implemented in `AFKCore` and the native apps. This is a personal beta, not an
independently audited remote-access product. Tracking: #3, owner @JesusPaz.

## Trust and enrollment

New Mac and iPhone identities use independent Secure Enclave P-256 keys with
self-signed certificates. Keychain stores only the opaque device-bound key blob.
The iPhone key ACL is `WhenUnlockedThisDeviceOnly` + `privateKeyUsage` +
`biometryCurrentSet`; the Mac uses `AfterFirstUnlockThisDeviceOnly` +
`privateKeyUsage` so it can serve while unattended. The supported NIOSSL custom-key
callback hashes/signs TLS transcript bytes with CryptoKit on a worker queue, never
blocking NIO's event loop. TLS negotiation is bounded to 60 seconds for biometric
interaction. The transport invalidates its LAContext on close/background/cancellation.
A connection has a fresh LAContext; there is no cached authentication across connections.
Software keys can only be created by internal test fixtures; previously saved software
identities remain readable for migration. No private key is transferred to Secure Enclave:
the explicit migration creates a new key, clears peers, and requires new pairing.
No private key or enrollment capability is sent to the relay HTTP API.

The Mac creates `AFK3:` invitations locally: schema 3, canonical HTTPS origin,
host UUID/code, SHA-256 certificate pin, invitation UUID, a random 256-bit
capability and a five-minute expiry. The parser limits the full input to 2,048
UTF-8 bytes before decoding. QR (Core Image, correction M) and paste use this same
parser. The Mac persists only the capability hash, expiry and attempt counter;
there are five attempts and one use. Startup invalidates recovered invitations.

The native Mac UI authenticates invitation creation and approval separately.
The iPhone displays the origin before registration and authenticates locally.
Registration creates transport credentials only. Inside mutual TLS, `hello`
uses wire version 2 and adds `ceremony: 3`. The host reserves a single candidate
in memory, bound to the concrete connection and a fresh approval UUID. No peer,
connection event or session data is exposed while approval is pending.

`approvalRequired` echoes server, host/client IDs, client nonce and client
certificate fingerprint, and includes `ceremony: 3`, `approvalID` and a fresh
`hostNonce`. Both endpoints calculate the comparison code below. The Mac UI
requires explicit code comparison and device-owner authentication; afterwards it
rechecks the candidate token and expiry. Commit atomically stores the peer and
consumes the invitation before `welcome` (with the same ceremony/approval ID).
The phone rejects welcome without that preceding challenge and only then saves
its replacement connection. Failure preserves the previous phone record.

Initial negotiation has 15 seconds; consent has up to 120 seconds within the
original invitation lifetime, enforced with monotonic deadlines as well as wall
expiry. Rejection, replacement, cancellation, disconnect and Mac lock invalidate
the pending invitation. Persistence failure closes enrollment. No pending
candidate survives restart. All commands are rejected before approval.

If the Mac commits but welcome or phone persistence fails, its peer can remain
orphaned. Revoke it in Devices and create a new invitation. There is no cross-device
atomic transaction. Existing peers still reconnect through v2 with their exact
certificate; AFK2 invitations and legacy hello cannot enroll a new peer.

### Comparison transcript and vector

Serialize these UTF-8 strings **in order**, each prefixed with its unsigned
32-bit **big-endian byte length** (no separator or terminator):

1. `AFK enrollment comparison`
2. `3`
3. canonical server origin
4. host ID
5. client ID
6. invitation ID
7. full lowercase host certificate SHA-256 fingerprint
8. full lowercase client certificate SHA-256 fingerprint
9. client nonce
10. host nonce

Hash the serialized bytes with SHA-256. Interpret its first four bytes as an
unsigned big-endian integer, take modulo 100,000,000, pad to eight decimal digits
and group `1234 5678`. The test vector uses `https://example.com`, `host`, `client`,
`invitation`, `host-fingerprint`, `client-fingerprint`, `client-nonce`, `host-nonce`
for fields 3–10. Its digest is
`ac188c10af11b779cccfab975e77070ba44913899f17cc85d5b867bc3db750f8`,
and its display code is **8728 9872**. Those identity/nonce labels are synthetic
vector inputs, not valid wire credentials.

The short code can collide; it complements the capability, pinned host,
proof of possession, fresh nonces and local consent. It is not a password or
an independently audited cryptographic guarantee. Never log the transcript,
nonces, code or invitation. Copy is explicit, transient/concealed, and clears
only its own clipboard item after five minutes.

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
complete TLS, but cannot execute any command until capability validation and local consent commit.
TLS CertificateVerify proves key possession; no trust is derived from a certificate
issuer or self-signature. Session record integrity, ordering, ephemeral key exchange
and replay rejection are provided by TLS, not by application-made crypto.

Encrypted application packets use a 4-byte big-endian length and bounded JSON.
The TLS protocol gate refuses app writes before authentication. Incoming dispatch
and outgoing queues are bounded to 16 messages / 1 MiB; a packet is at most 512 KiB.
WebSocket messages are binary, at most 64 KiB, with no compression. Slow or invalid
peers disconnect; input is never replayed across a connection or lease change.
Within the same lease, the phone retains bounded input until `inputAck` confirms
the session, epoch and sequence. It retries missing acknowledgements with the
same sequence; the host acknowledges accepted duplicates without applying them
again. Snapshots advertise this support with `inputAcknowledgements: true`.
See [live dictation and delivery confirmation](dictation.md) for batching, bounds
and retry behavior.

## Revocation and local access

The Mac persists revocation first, closes the channel and then requests relay
revocation. It works locally even if the relay ignores the request or is offline.
A persistence failure closes all remote access and reports an error. Viewing the
devices list while paused does not resume access. Current local peer authorization
is checked on every application packet; input also needs the current lease epoch
and a fresh sequence. The relay rechecks transport credentials every 30 seconds,
pings peers, and caps connection lifetime at eight hours.

New iPhone identities require Face ID/Touch ID in the hardware key operation for
pairing and every TLS connection, without a passcode fallback. Legacy identities
retain their existing UI device-owner authentication until deliberately replaced. Backgrounding invalidates pending local authentication,
closes transport, and clears visible terminal contents. A privacy overlay hides
content while inactive. Late HTTP/TLS results cannot reopen a suspended generation.
No remote configuration, clipboard synchronization, file-transfer endpoint or
system-wide phone control is exposed. Pairing grants no shell permissions. The Mac explicitly shares individual sessions
per device, filters all outgoing events and validates each requested operation.
Temporary control and separate creation/closing grants are bounded locally. An
explicit trusted-device grant instead covers all sessions and creation/closing,
persists in the same Keychain record as its exact certificate, and is checked locally.
The `biometricIdentity` hello field is saved only during consent-based enrollment;
changing it during reconnect cannot upgrade a peer. It describes genuine-app behavior,
not Apple attestation. Only a hardware-backed Mac with an enrolled biometric-capable
phone can grant persistent full access through the UI. See `security.md`. Controlling a shared shell still executes as the Mac user, without
OS isolation or command filtering.

## Verification

- `swift test`: production TLS pinning, missing/substitute/delegated identities,
  TLS downgrade and ALPN, tampered/replayed/reordered/cross-session/incomplete
  records, fragmented bidirectional encryption, pre-auth writes; invitation expiry,
  attempt persistence, one use, restart, lost welcome, failed writes, revocation;
  untrusted outer WSS certificate; local-auth denial, no caching, stale unlock;
  hardware-key serialization without plaintext, persistent full-access grants,
  failed persistence, legacy-grant rejection and explicit identity migration.
  Secure Enclave tests skip when hardware is unavailable.
- `./scripts/test-server.sh`: Go race detector with real PostgreSQL, token/role
  checks, legacy rejection, opaque routing, revoked credentials, malformed/text/
  oversized frames and aggregate probe/metrics behavior.
- `./scripts/test-secure.sh`: two real native TLS phones, Mac PTY, command output,
  exclusive control, stale-owner input, resize, snapshot, reconnect and revocation.
  The primary scenario uses real Secure Enclave keys on both ends (without biometric
  prompts in the test phone), rejects substitution of the pinned certificate’s
  hardware key before welcome, and reconnects successfully with the original key.
  Test database identities and current test Keychain records are removed.
- `go run golang.org/x/vuln/cmd/govulncheck@v1.9.0 ./...`: dependency vulnerability check.

The earlier `experiments/e2ee-tls` is historical design evidence. Production uses
the supported custom verification API, not that prototype's underscored API.
Physical Face ID, device backgrounding and public Cloudflare WSS still need an
actual iPhone test. Automated local checks are not a substitute for a security audit.

## Physical acceptance for hardware trust

Owner: JesusPaz, tracking #3. These checks require the updated apps on the M4 Mac
and iPhone 13 Pro; automated TLS tests do not prove Face ID behavior.

- Confirm Face ID is requested on each new connection and after background/resume.
  Cancel/fail it: no sessions, commands or terminal contents may be exposed.
- Lock/background while authentication is pending: late success must not connect.
- Confirm strict biometric signing cannot be bypassed with the device passcode.
- After deliberate biometric re-enrollment, the old key must fail and require re-pairing.
- Grant trust locally, create another terminal and restart AFK: access persists.
  Removing trust and stopping all access must disconnect/clear access immediately.
- Verify the Mac can authenticate itself while unattended after first unlock.
- Confirm live dictation corrections still stream without per-keystroke prompts.

Apple references: [Secure Enclave keys](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave),
[current biometric enrollment](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/biometrycurrentset),
[App Attest’s separate integrity checks](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity).

## Complete terminal history

An updated phone sends `attach` with a fresh UUID `historyID`. The Mac replies with
`historyChunk`: ordered `events`, the same `historyID`, `historyOffset`,
`historyLength`, `historyComplete`, and the current output `sequence`, owner/epoch
and input-acknowledgement capability. Each `historyNext` echoes the transfer ID and
last offset; mismatched/obsolete cursors cannot advance the reader. One reader per
phone bounds memory and open files. Access is checked on every request.

The Mac flushes pending PTY output before each read and refreshes the recording’s
length. Only output/resize events for that downloading phone/session are suppressed;
other viewers and the local terminal continue normally. The final page and resumption
of live output occur on the host main actor, with no gap between the recording and
the next output sequence. The phone renders and journals each page before requesting
another, with a 20 ms pacing interval to stay within relay frame/byte budgets. Input remains disabled until completion. Disk errors fail explicitly rather
than silently dropping history. Reconnect starts a fresh download. No total byte cap
is imposed; sustained output faster than download can delay catching up.

Absent `historyID`, the bounded legacy snapshot behavior is retained. Updated apps
require a Mac recording for streamed history; the production Mac creates these for
every session. There is no relay wire-format change: all fields remain inside TLS.

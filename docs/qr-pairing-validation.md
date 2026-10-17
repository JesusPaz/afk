# QR pairing — implementation evidence

2026-10-16 · Tracking: [#3](https://github.com/JesusPaz/afk/issues/3) · Owner: JesusPaz.
Implementation is under PR review. It is not a completed release or independent
security audit. Requirements: [plan](plans/qr-pairing.md); serialization, messages
and deterministic vector: [device protocol](e2ee.md#comparison-transcript-and-vector).

## Automated coverage

Local results: **53 unit tests passed** (`swift test` reports 56 with the three
relay-dependent cases skipped); **all three native integration scenarios passed**
when run separately with PostgreSQL. Go `-race -count=1` with the real database and
both unsigned native build checks passed. This is compile/test evidence, not a
signed release or a physical-device result.

Public WSS integration against `https://afk.jesuspaz.com` also passed on 2026-10-16:
code comparison and explicit approval after 16 seconds, two clients, real PTY,
independent session grants, reconnect and revocation. Only the
`testSecurePairingRealPTYReconnectAndRevocation` scenario ran publicly; the other
two scenarios ran locally. The public run used ephemeral test identities and the
harness cleanup; its log is `/tmp/afk-public-tests.log`.

| Plan | Evidence / remaining scope |
| --- | --- |
| P01 | QR and paste enter `SecureInvitation.decode` and the same phone ceremony. Core Image generates/decodes a real invitation and the 2,048-byte maximum at correction M. Physical camera legibility remains. |
| P02–P03 | Native mutual-TLS integration observes no peer/connection event before explicit harness approval, compares both codes, then verifies private sessions and independent grants. |
| P04 | Fixed SHA-256/display vector; every transcript context field is mutated independently. Short-code collision limits documented. |
| P05 | Unit cancellation/replacement/expiry/restart rejection; real pending rejection, invalidated invitation reuse, and late approval rejection. UI dismissal/physical lock still manual. |
| P06 | Real second candidate rejected while the first token/code remains stable. Scanner coordinator latches its first accepted result and stops capture; physical callbacks remain manual. |
| P07 | Unit stale tokens, monotonic timeout with wall-clock rollback and replacement. UI rechecks after local unlock; physical biometric races remain manual. |
| P08 | Five attempts persist during reservation; concurrent candidates cannot replace it. Existing transport/relay bounds retained. No sustained flood campaign claimed. |
| P09 | Injected Mac storage failure at commit and invalidation: no peer published, enrollment disabled, explicit new invitation required after storage recovery. |
| P10 | Real phone persistence failure preserves old RAM/Keychain record; committed Mac orphan remains visible and revocable. Cancellation preserves previous link. |
| P11 | Native integration sends list/create/attach/input/resize/claim/release/renew/terminate while pending: each closes without welcome/session data. |
| P12 | Parser bounds, malformed fields, unsafe origins, expiration and legacy format; existing TLS/pin tests. UI asks origin before network registration. |
| P13 | Legacy hello cannot enroll; AFK2 parser rejection; existing exact-certificate v2 reconnect still passes. |
| P14 | Mac/iOS compile; matching ES/EN catalogs. Real camera denial/restrictions and VoiceOver remain manual. |
| P15–P16 | Startup invalidates recovered invitations; phone background and Mac lock cancel; monotonic deadline tests and approval after 16 seconds. Real lifecycle/biometric/lock transitions remain manual. |
| P17 | Pending two-device physical test by Jesus. Public WSS native integration for this change passed; it does not replace a physical iPhone test. |

Run `swift test`, `scripts/test-secure.sh`, and `GOFLAGS=-count=1 scripts/test-server.sh`.
The native suite has separate relay instances per scenario so it respects the
existing 30-request/minute budget. Production relay behavior and session permissions
are unchanged. Native build commands remain in README.

Local logs for this work: `/tmp/afk-tests.log`, `/tmp/afk-secure-tests.log`,
`/tmp/afk-go-tests.log`, `/tmp/afk-mac-build.log`, `/tmp/afk-ios-build.log`.
These logs are temporary, not release artifacts.

## Karpathy review of the implementation

- Reservation and approval are separate; the legacy `authorize` path can only
  reconnect an already trusted exact certificate. No post-authorization dialog.
- The phone candidate remains transient until authenticated welcome; failure does
  not overwrite its old link. No cross-device atomicity is claimed.
- A single bounded candidate/token and existing transport limits replace any need
  for approval queues. Local auth completion cannot approve a replaced token.
- QR/scanner use Apple APIs and existing validation. No new dependency, discovery,
  relay protocol version, session grant or automatic approval was introduced.
- Tests exposed the relay's existing request budget; the harness was split rather
  than changing production limits. Temporary diagnostic logging was removed.
- Canceled Swift tasks close their own attempt; wall expiry and monotonic limits
  are checked independently. QR payload and comparison codes are never logged.

## Remaining release gates

JesusPaz: record P14–P17 on a physical iPhone/Mac (scan, denial, VoiceOver ES/EN,
background versus biometric inactivity, Mac lock, reject, timeout, reconnect,
manual session sharing, revoke). Independent cryptographic/design review remains
required before claiming audited security.

Build and verify a new signed/notarized Mac release and a new TestFlight build;
update both apps before creating AFK3 invitations. Existing releases must not be
replaced. This PR does not deploy the relay or publish either app.

# Security boundary

AFK v2 is a personal beta with end-to-end encrypted terminal transport. It has not
had an independent security audit. See [protocol and tests](e2ee.md) and the
[RustDesk comparison](security-rustdesk.md). Do not describe it as production-ready
or universally more secure than another product.

## Enforced controls

- Mutual TLS 1.3 between pinned device identities, inside CA-verified WSS/TLS 1.3.
  Missing/changed identities fail closed. The relay cannot grant shell access.
- Local 256-bit, five-minute, single-use invitation; five persisted attempts.
  Authorization and invitation consumption commit atomically before acknowledgement.
- Device-only Keychain identity persistence. Device-owner authentication gates
  invitation creation on Mac and pairing/reconnection in the iPhone UI.
- Local revocation precedes network revocation. Persistence failures disconnect.
  No automatic replacement of an identity, legacy fallback or uncertain input replay.
- The host validates the authorized certificate on every application packet, then
  applies exclusive input ownership, epoch and sequence checks.
- Bounded HTTP bodies, TLS application packets, WebSocket frames, queues, peers,
  traffic rates and connection lifetime. Native-only WebSocket origins, no cookies,
  no automatic redirects or compression. Binary opaque relay traffic only.
- PostgreSQL stores SHA-256 hashes of random transport tokens, not private keys,
  invitation capabilities or terminal contents. Metrics contain only aggregate
  counters/gauges, with no device labels, token values or terminal text.
- iPhone backgrounding closes remote access and clears terminal display memory.
  No automatic links, OSC clipboard integration or remote configuration endpoint.

## Remaining boundaries

A compromised operating system, injected process or stolen private device key is
outside this protection. Device keys are exportable to the TLS process, not Secure
Enclave-backed. Keychain accessibility and local UI authentication are not a claim
of hardware-backed non-exportability. Biometrics must be verified on physical
hardware; a person who knows the device passcode can pass device-owner authentication.

Only share invitations through a channel you trust. A stolen unused invitation
allows enrollment during its short lifetime. Pairing currently uses explicit copy /
paste, not QR scanning. The relay sees host/client routing metadata, addresses,
timing and ciphertext lengths, and can deny service; it cannot be made availability-
trusted by encryption. Registration abuse is rate/budget limited, not eliminated.
The single-instance limiter sees the TCP peer, which may be a shared reverse proxy.

Every authorized phone can create, read and terminate every AFK shell. Shells run
as the Mac user and can access that user's files and credentials; there are no
per-session or command-level permissions. The phone does not expose a remote shell.
Apple, SwiftTerm, NIO/BoringSSL and shell programs remain part of the trusted base.
Terminal replay is in RAM; OS crash reports, swap and shell history are separate.
No secure memory-erasure guarantee is made.

Identity certificates expire after five years and fail closed. Automatic key
rotation, recovery and device migration are not implemented: re-pair deliberately;
never accept a changed fingerprint automatically. Reinstall/Keychain deletion can
require new enrollment. Unattended background host lifecycle, signed/notarized
public distribution, independent review, sustained fuzz/load tests, physical-device
validation and tested backup/restore remain release gates owned by @JesusPaz in #3.

## Reporting and monitoring

Report security issues privately to the maintainer without credentials or terminal
content. `/healthz` is process liveness, `/readyz` checks PostgreSQL, and `/metrics`
is Prometheus text with aggregate transport activity and rejects. Keep metrics
internal to the homelab; probes do not prove that a particular phone is authorized.

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
  enforces explicit per-device/session permissions before exclusive input ownership,
  epoch and sequence checks. Pairing grants no session visibility or shell access.
- New sessions are private. Read, temporary control, timed creation and timed closing
  permissions are distinct. Both session lists and every output/control event are
  filtered locally. An authorized creator receives control only of its new session,
  until the original creation deadline, with no permission to close it.
- Control lasts 15 minutes, 1 hour or 8 hours as selected on Mac; 5 minutes without
  accepted input after the first claim downgrades to read-only. Heartbeats, resize,
  repeated claims and reconnects cannot extend that idle window or the absolute
  deadline. Clock checks use wall time and monotonic uptime. Read access remains
  until explicitly removed, all access is stopped, or the Mac process exits.
- Mac device-owner authentication gates permission grants. Offline phones can be
  authorized in advance. Disconnect releases control; grants stay bounded by their
  original deadlines. Stopping access clears all grants and pending invitations;
  revoke-all atomically persists device removal. Neither action closes local shells.
- A local, bounded history retains the last 200 authorization/access/security events
  across launches, with timestamps and device/session IDs, never terminal content.
  It is not tamper-proof auditing against a compromised Mac user account.
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

Controlling even one shared shell runs commands as the Mac user and can access
that user's files and credentials, including other processes. Per-session permissions
are access controls, not OS isolation or command-level restrictions. Closing permission
only gates AFK's close action: a controller can still run `exit` or kill processes.
Read-only access can expose secrets printed by that session. The phone does not
expose a remote shell. No VM or sandbox is introduced by these controls.
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

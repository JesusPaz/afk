# Delivery roadmap

## POC implemented

Local real PTY, native Mac/iPhone targets, shared Swift core, Go relay, PostgreSQL registration and pairing, Keychain credentials, exclusive input ownership, bounded stream replay, linked-device revocation and local development scripts.

## Before an internet-access MVP

1. E2EE threat model, reviewed transport design, authenticated device identity and recovery.
2. Separate Mac background host, restart semantics and signed/notarized installation.
3. Authoritative terminal-state snapshots, reconnection backoff and explicit resynchronization.
4. QR pairing, full approved visual system, clear disconnected / expired / revoked states, VoiceOver and Dynamic Type validation.
5. Self-host deployment with HTTPS, migrations/versioning, backups, quotas and operational tests. Default hosted relay requires explicit deployment and operations work.
6. Real iPhone tests across sleep, backgrounding, mobile networking and physical keyboards; TestFlight distribution.
7. Load tests, fuzzing, dependency updates and independent security review.

## Outside the first MVP

Android / Windows / Linux hosts, desktop screen streaming, audio, file transfer, organization/team administration, collaborative simultaneous typing, offline execution on iPhone, browser terminal and AI command execution features.

POC tracking: https://github.com/JesusPaz/afk/issues/1. MVP release gates: https://github.com/JesusPaz/afk/issues/3 (owner: @JesusPaz). The POC is not the full MVP and passing build/tests does not establish production security or visual approval.

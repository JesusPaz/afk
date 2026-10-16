# Secure personal beta delivery — 2026-10-16

## Notarized Mac distribution

Release [v0.1.0-rc.3](https://github.com/JesusPaz/afk/releases/tag/v0.1.0-rc.3)
contains `AFK-v0.1.0-rc.3-macOS.zip`, `SHA256SUMS` and `source.json`.
Built locally from `1f19e02142dd1aa731b593454c922162472a550e` (CI passed),
version 0.1.0 (3), macOS 14+, universal arm64/x86_64, public HTTPS relay.
Developer ID signature, hardened runtime, secure timestamp and both architectures
verified. Apple notarization `0238457b-5864-484d-a912-781c4eceb5b6` was Accepted;
stapling/validation passed and Gatekeeper accepted `Notarized Developer ID`.
The distribution ZIP was recreated after stapling. SHA-256:
`3bb1af00b067984f2407d6bfc3f6ec6aa223775aa62295cb5fc1d6a47445c18d`.

Download and extract the ZIP, then move AFK.app to Applications. Save existing shell
work before quitting/replacing AFK. iPhone distribution and physical-device checks
remain pending; the relay remains on rc.2.

## Session access controls (current main)

Mac Devices now grants per-device/session read or temporary control, with separate
creation and closing permissions. Pairing exposes no sessions. Control can be
preauthorized for 15 minutes, 1 hour or 8 hours, and downgrades after five minutes
without accepted input after the first claim. Reconnect/heartbeat cannot extend it.
Read access lasts until removed or AFK stops. Stop-all clears grants and invitations;
revoke-all also persists removal of trusted devices. Local history keeps 200 metadata
events. See `security.md` for shell authority and audit limitations.

Validation: 49 Swift tests (48 passed, integration skipped in unit run), separate
real encrypted PTY integration locally and through public WSS at
`https://afk.jesuspaz.com`, and Go race/PostgreSQL passed. Coverage includes private
metadata/output, read-only denials, creation/closing permissions, idle/absolute
expiry, stale input, reconnect, revoked output, clear-on-revoke iPhone display and
atomic revoke-all. HTTP `/readyz` is publicly healthy; `/metrics` remains 404 externally.
The relay image/protocol is unchanged; permissions are enforced on Mac, not by relay.

Current local archives: `.artifacts/secure-delivery/AFKMac-access.xcarchive` (ad hoc)
and `AFKiOS-access.xcarchive` (unsigned). Mac test ZIP:
`.artifacts/secure-delivery/AFK-local-macOS-access.zip`. Logs: `.artifacts/access-*.log`.
Update both native apps to use these controls. Existing running Mac shells were not
restarted. Physical-device checks remain pending; the signed distribution above
supersedes the ad-hoc Mac ZIP.

## Relay release and previous delivery

Release: https://github.com/JesusPaz/afk/releases/tag/v0.1.0-rc.2.
Relay source: `ba164d4` (PR #4); native clients also require the subsequent
HTTP-upgrade byte-forwarding fix on main. Tracking: #3, owner JesusPaz.

## Delivered and verified

- Relay compiled locally for linux/amd64 and linux/arm64. Release contains Docker
  archives and SHA256 checksums; Actions only loaded and published those archives.
- Public image (anonymous access verified for both architectures):
  `ghcr.io/jesuspaz/afk-relay@sha256:688fce7144115ddbed27c1ab93b60ba8325ebdec68b53b333e8849301b876ecc`.
- Personal homelab PR #64 merged; Argo synced `bcf90ba`, Healthy, relay 1/1.
  Two initial database migration startup failures recovered; no subsequent restart
  during integration verification. PostgreSQL data/PVC preserved.
- Protocol v2: end-to-end mutual TLS 1.3, exact device pins, single-use expiring
  invitation, Keychain persistence, local authorization and revocation. Legacy v1
  endpoints are disabled. HTTPS uses validated WSS; insecure HTTP is loopback-only.
- `/healthz` reports protocol 2, `/readyz` checks the database. `/metrics` is
  internal-only, with aggregate counters/gauges and pod scrape annotations.
  LAN ingress readiness passed; ingress `/metrics` returned 404.
- Swift: 38 tests, 37 passed and the environment-dependent integration skipped in
  the unit run. Integration passed separately against the deployed relay and real
  PostgreSQL: two native encrypted peers, real PTY, wrong-origin/preauthorization
  rejection, single-use pairing, stale owner, resize, reconnect and revocation.
- Local Go race/PostgreSQL tests, go vet, five packaging tests, actionlint and
  govulncheck passed (no known vulnerabilities). CI for `ba164d4` passed.
- Deployment exposed a native HTTP-upgrade race: a WebSocket frame coalesced with
  HTTP 101 was discarded. Main forwards leftover bytes and includes a regression
  test. No relay rebuild is required for this native-client correction.

## Local artifacts

Ignored local directory `.artifacts/secure-delivery/` contains:

- `AFKMac-final.xcarchive`: current Release Mac archive, ad-hoc signed.
- `AFKiOS.xcarchive`: current unsigned Release iPhone archive, not installable as-is.
- `relay-linux-amd64.tar.gz`, `relay-linux-arm64.tar.gz`, `relay-SHA256SUMS`.

Build/test logs: `.artifacts/secure-*.log`. The earlier `.artifacts/delivery/`
artifacts are obsolete v1 clients. Existing Mac app/shells were not restarted.
Run `scripts/test-secure.sh` for real native integration; `AFK_TEST_RELAY_URL` and
`AFK_TEST_DATABASE_URL` select an existing relay/database. Test identities are
random and removed afterwards. Keep database credentials out of logs.

## Remaining manual verification and distribution

Jesus configured Cloudflare DNS/tunnel setup: `afk.jesuspaz.com` →
`http://traefik.kube-system.svc.cluster.local:80`. Public HTTPS/WSS integration now
passes. Physical phone biometric/pairing/control/revocation on cellular remains
unverified. Metrics remain excluded from ingress.

Mac Developer ID signing and notarized ZIP distribution are complete. AFK iPhone
registration/provisioning and TestFlight distribution remain pending.

See `security.md`, `e2ee.md`, and `security-rustdesk.md` for threat boundaries,
negative tests and the source-based RustDesk comparison. This is not an
independent audit or proof that AFK is as secure as RustDesk overall.

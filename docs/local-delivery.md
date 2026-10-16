# Secure personal beta delivery — 2026-10-16

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

Jesus owns Cloudflare DNS/tunnel setup: `afk.jesuspaz.com` →
`http://traefik.kube-system.svc.cluster.local:80`. Public HTTPS/WSS and physical
phone biometric/pairing/control/revocation on cellular remain unverified.

Developer ID identities exist locally, but signing waits for macOS Keychain
approval. Notarization and iPhone distribution credentials/provisioning still
need completion; no signed installer or TestFlight build has been published.

See `security.md`, `e2ee.md`, and `security-rustdesk.md` for threat boundaries,
negative tests and the source-based RustDesk comparison. This is not an
independent audit or proof that AFK is as secure as RustDesk overall.

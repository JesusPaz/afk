# Personal beta delivery — 2026-10-15

Release: https://github.com/JesusPaz/afk/releases/tag/v0.1.0-rc.1.
Source: `854b60d`; tracking and remaining physical-device work: #3 (JesusPaz).

## Delivered

- Relay built **locally** for linux/amd64 and linux/arm64. Release assets contain
  both `docker save` archives and `relay-SHA256SUMS`.
- `publish-local.yml` only verifies checksums, loads those images, and pushes them;
  it does not compile the relay. This first delivery's saved image tag is
  `ghcr.io/jesuspaz/afk-relay:local-20261015`.
- Public image, anonymous access verified:
  `ghcr.io/jesuspaz/afk-relay@sha256:3482fbe70f99f5371d66ed23b1a7f856a176b644cc26f6c26484e879bc4d13f1`.
- Personal homelab manifests: `JesusPaz/homelab`, commit `1d7db23`,
  `infrastructure/afk-relay`. Relay and PostgreSQL run on helena in namespace `afk`,
  with a bound 5 GiB PVC. Argo application: `afk-relay`, manual sync.

## Verification

Passed locally: 13 Swift tests, Go race with PostgreSQL and a real Swift PTY/two
clients, `go vet`, 5 packaging tests, actionlint, and Mac/iPhone Release archives.
CI also passed for the release source. Mac and iPhone Simulator builds use ad-hoc
signing; the physical-iPhone archive is unsigned and is not installable as-is.

Repeated `TestRealSwiftPTY` against the **deployed** relay and database through
loopback port forwards: fanout, control transfer, stale-owner rejection, real
terminal resize, replay and shell exit passed. Test identities are cleaned up.
`AFK_TEST_RELAY_URL` selects an existing relay for this test; set
`AFK_TEST_DATABASE_URL` to that relay's database and `AFK_TEST_HOST_BINARY` to the
local Swift host. With no relay override the test starts its own isolated relay.

Ingress check passed:

```sh
curl --fail -H 'Host: afk.jesuspaz.com' http://192.168.1.43/readyz
```

The relay restarted twice during initial database startup, then became ready.

## Local artifacts for tomorrow

All paths are relative to the AFK checkout and are intentionally ignored by Git:

- `.artifacts/delivery/AFK-local-macOS.zip`: runnable development build, ad-hoc signed.
- `.artifacts/delivery/AFKMac.xcarchive`: Release Mac archive.
- `.artifacts/delivery/AFKiOS.xcarchive`: unsigned Release physical-iPhone archive.
- `.artifacts/DeliverySimulator/Build/Products/Debug-iphonesimulator/AFK.app`:
  runnable iPhone Simulator build.
- `.artifacts/delivery/`: build/test logs and relay release archives.

All three app builds embed `https://afk.jesuspaz.com`. Existing saved preferences
still take precedence. No existing Mac app or terminal sessions were restarted.

## Remaining manual steps

Jesus owns Cloudflare setup: add `afk.jesuspaz.com` to the homelab tunnel, pointing
to `http://traefik.kube-system.svc.cluster.local:80`, with its proxied DNS record.
Then verify HTTPS `/readyz` and pairing/control/revocation from an iPhone on cellular.
Public HTTPS/WebSocket routing was not verified before this manual configuration.

Apple Developer signing, TestFlight, notarization and Homebrew distribution are
separate unfinished work. The relay remains a trusted personal beta without E2EE.

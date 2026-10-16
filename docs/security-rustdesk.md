# Security comparison with RustDesk — 2026-10-16

Scope: design/code review, not a comparative penetration test or certification.
RustDesk source reviewed at `53996e3c404ea5083df0775057e4149e49102084`; defaults and
features vary by client version, OSS/Pro and deployment settings.

| Area | RustDesk evidence | AFK v2 decision / evidence |
| --- | --- | --- |
| Peer identity | Rendezvous-root verification of signed peer identities, then a signed peer handshake. | Mac fingerprint comes from its locally created invitation; phone certificate is authorized locally. The relay is never a device-identity authority. |
| Key exchange | The reviewed code negotiates key-exchange versions and binds key derivation to a transcript. | Standard mutual TLS 1.3 supplies transcript binding and directional authenticated record keys. No custom key-exchange implementation. |
| Failed verification | The reviewed TCP/relay path contains non-secure fallback branches when peer keys cannot be verified; WebRTC binding failures with an established identity are rejected. This is a scoped code observation, not a claim about every release or configuration. | No missing-key or plaintext fallback. v1 endpoints are unavailable in the shipped relay. Pin, ALPN and downgrade regressions are tested. |
| Permission controls | Documented settings cover approval modes, password verification, device trust, IP/ID allowlists and granular capabilities. | Device certificate allowlist plus one-use enrollment. All paired phones get AFK-shell authority; there is no claim of equivalent granular permissions. |
| Local possession | RustDesk documents trusted-device/2FA and approval controls. | Native local device-owner authentication before Mac invitation creation and phone connection; cancelled/stale unlocks fail closed. This is not an independent second factor after device compromise. |
| Surface area | RustDesk offers desktop, clipboard, file, tunnel and other optional functions. | AFK exposes only its terminal protocol, with remote configuration/clipboard/file endpoints absent. A shell itself still has broad user authority. |
| Abuse / operations | The reviewed server bounds admission/handshake work; documentation exposes connection policies. | Bounded handshakes, queues, traffic and peers, periodic transport-credential checks, local revocation, probes and metrics. Sustained adversarial load testing remains pending. |

Sources: [RustDesk client handshake](https://github.com/rustdesk/rustdesk/blob/53996e3c404ea5083df0775057e4149e49102084/src/client.rs#L1653),
[server handshake](https://github.com/rustdesk/rustdesk/blob/53996e3c404ea5083df0775057e4149e49102084/src/server.rs#L217),
[official security settings](https://rustdesk.com/docs/en/self-host/client-configuration/advanced-settings/),
and [maintainer security clarification](https://github.com/rustdesk/rustdesk/discussions/15492).

The review led to explicit local unlock gates, generation cancellation, privacy
clearing, fail-closed revocation, no production legacy switch, and production-code
TLS attack tests in AFK. The implementation also follows relevant
[OWASP WebSocket guidance](https://cheatsheetseries.owasp.org/cheatsheets/WebSocket_Security_Cheat_Sheet.html)
on WSS, origin checks, bounded messages and avoiding compression.

Acceptance for an "equally or more secure" product claim is **not met** by these
changes alone. Owner @JesusPaz / #3: independent protocol and implementation audit,
physical-device authentication/lifecycle tests, signed distribution, and adversarial
load/fuzz coverage are required before making that claim. Exact threat-model
comparisons must distinguish unauthorized shell access, endpoint compromise,
metadata privacy and denial of service.

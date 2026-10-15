# Security boundary

This is a local developer proof of concept, not a hardened remote shell product. Do not expose it as a public multi-tenant service.

## Implemented

- Crypto-random 256-bit bearer credentials; PostgreSQL holds SHA-256 hashes, not raw credentials. Hashing is suitable here because these are random high-entropy tokens, not human passwords.
- Crypto-random 128-bit pairing secret, five-minute validity and atomic single use.
- Keychain storage on Apple devices. Credential-free URLs, Authorization headers and redirect refusal.
- Native clients require HTTPS except exact loopback hosts. Relay binds to loopback by default; PostgreSQL also binds to loopback.
- Per-IP request throttling, bounded payloads / queues, authenticated sender assignment and cross-host routing isolation.
- Revocation persists across restart and cancels active connections. Pausing remote access disconnects the Mac host; local sessions continue.
- No terminal data, passwords or bearer credentials intentionally logged by AFK. No automatic terminal link opening or OSC clipboard integration.
- Pending input is discarded on disconnect. Input needs the current lease epoch and a fresh sequence.

## Not implemented yet

The relay **can read and modify terminal traffic** and sees pairing credentials in transit through its process. TLS is transport encryption, not E2EE. The current password is a random enrollment secret, not an encrypted authenticated handshake. A compromised trusted relay can impersonate peers. Every paired device has access to all AFK sessions, including session creation / termination. There are no per-session permissions.

A production release needs an independently reviewed E2EE protocol with device verification, key rotation, replay defenses and recovery rules; signed/notarized Mac distribution; background agent lifecycle; abuse protection and operational monitoring. Do not implement custom cryptography to bridge this gap.

The rate limiter is in-memory and uses the TCP peer address. There is no trusted-proxy configuration or distributed limiter; putting this behind an arbitrary proxy is not production deployment guidance. Device registration and room creation are not globally quota-managed.

Mac terminal content is held in RAM; Apple / third-party shell software may separately keep shell history or logs. SwiftTerm and the OS are part of the trusted computing base. Shell subprocesses are user processes, not sandboxed workloads. Quitting AFK closes the PTY and requests shell termination; detached child jobs are not a managed job tree.

There are no distributed binaries or production vulnerability-response guarantees yet. Report bugs without including credentials or private terminal output.

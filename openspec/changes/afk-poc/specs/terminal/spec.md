## ADDED Requirements

### Requirement: One authoritative shell

The system SHALL execute the shell on the Mac and render its output on linked clients.

#### Scenario: Two observers
- **WHEN** a shell produces output and two clients are connected
- **THEN** both receive the same ordered output bytes from that shell.

### Requirement: Exclusive input

The Mac SHALL accept input only for the current owner, epoch and increasing input sequence.

#### Scenario: Delayed input after control transfer
- **WHEN** client B takes control after client A
- **THEN** client A's old-epoch input does not reach the shell.

### Requirement: Persistent enrollment

The relay SHALL persist host identity, linked devices and revocation in PostgreSQL; clients SHALL store raw credentials in Keychain.

#### Scenario: Concurrent enrollment
- **WHEN** multiple clients redeem the same valid temporary secret
- **THEN** exactly one enrollment succeeds and the secret is consumed.

#### Scenario: Revoked client
- **WHEN** the Mac revokes a linked device
- **THEN** its active relay connection closes and its token cannot reconnect.

### Requirement: Explicit replay boundary

The host SHALL replay the full fixed-size terminal stream only while it fits its bounded buffer.

#### Scenario: Replay overflow
- **WHEN** a client attaches after the buffer limit was exceeded
- **THEN** it receives an explicit error instead of incomplete ANSI state.

### Requirement: Honest POC trust model

The applications and documentation SHALL identify that this version requires a trusted relay and does not implement E2EE.

# Historical POC protocol v1

**Disabled in the shipped v2 relay.** Retained as historical protocol documentation and regression tests. Current protocol: [device transport v2](e2ee.md).

HTTP uses JSON. WebSocket `/v1/connect` uses JSON **text** frames. Bearer tokens travel in Authorization headers. The server rejects browser Origin headers; AFK currently supports native clients only.

| Endpoint | Caller | Result |
| --- | --- | --- |
| `GET /healthz` | Anyone | protocol version 1 |
| `GET /readyz` | Anyone | PostgreSQL readiness |
| `POST /v1/hosts` | New / existing Mac | `{id,code,name}`; body `{id,name,token}` proves possession |
| `POST /v1/pairing` | Host | `{secret,expiresAt}` |
| `POST /v1/pair` | New phone | `{clientID,token,host}`; body `{code,secret,name}` |
| `GET /v1/clients` | Host | Active paired clients |
| `DELETE /v1/clients/{id}` | Host | Revoke this host's client; 204 |
| `GET /v1/connect` | Host / client | WebSocket upgrade |

Envelope fields are `type`, optional `clientID`, `sessionID`, `epoch`, `sequence`, `data`, `events`, `owner`, `columns`, `rows`, `name`, `sessions`, `message`. Data bytes use base64. IDs are opaque. Empty owner means read-only; `local` means Mac. Relay replaces any client-supplied `clientID` with the authenticated identity.

- Relay events: `welcome`, `hostOnline`, `hostOffline`, `clientConnected`, `clientDisconnected`.
- Client requests: `list`, `create` (UUID session ID), `attach`, `claim`, `release`, `renew`, `input`, `resize`, `terminate`.
- Host events: `sessions`, `snapshot`, `output`, `resized`, `control`, `exit`, `error`.
- Snapshot: `events` contains the complete ordered log from the initial 80×24 grid. Each event is either `{data: base64}` or `{size: {columns, rows}}`. Replay both in order; `columns`/`rows` give the final grid. `sequence` covers output and resize events together. Gaps require a fresh attach. Replaying history must not send terminal query responses back to the shell.
- Input: session ID, lease epoch, monotonically increasing command sequence and base64 bytes. No replay or resend on reconnect.
- Host events with `clientID` target that peer. Others fan out to all linked active clients; UIs filter by selected session.

Production protocol negotiation, E2EE envelopes, acknowledgments, authoritative terminal snapshots and compatible upgrades remain roadmap work. This wire format may change before 1.0.

## Adaptive geometry

`resize` carries session ID, current lease epoch, command sequence, columns and rows. Input and resize share the same command sequence. Only the current owner may resize; invalid dimensions (outside 2–400 columns / 2–200 rows) are rejected before consuming the sequence. The host applies TIOCSWINSZ and broadcasts `resized` with geometry and the next output-event sequence. The kernel notifies the foreground process via SIGWINCH. Duplicate sizes do not add replay events.

Each UI remembers its viewport while observing. Taking control applies that viewport; resizing an observer does not reflow the shared terminal. Viewport updates are coalesced for 100 ms. Replay accounting includes 64 bytes per event as well as raw output, keeping resize-only traffic bounded. Update host, relay and phone together: old byte-only snapshots are no longer supported by these development builds.

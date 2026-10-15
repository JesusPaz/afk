# POC protocol v1

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

Envelope fields are `type`, optional `clientID`, `sessionID`, `epoch`, `sequence`, `data`, `owner`, `columns`, `rows`, `name`, `sessions`, `message`. Data bytes use base64. IDs are opaque. Empty owner means read-only; `local` means Mac. Relay replaces any client-supplied `clientID` with the authenticated identity.

- Relay events: `welcome`, `hostOnline`, `hostOffline`, `clientConnected`, `clientDisconnected`.
- Client requests: `list`, `create` (UUID session ID), `attach`, `claim`, `release`, `renew`, `input`, `terminate`. `resize` is reserved and ignored in the fixed-size POC.
- Host events: `sessions`, `snapshot`, `output`, `control`, `exit`, `error`.
- Snapshot: complete initial byte stream, output sequence, owner/epoch, 80 columns and 24 rows. Follow with strictly increasing output sequences.
- Input: session ID, lease epoch, monotonically increasing input sequence and base64 bytes. No replay or resend on reconnect.
- Host events with `clientID` target that peer. Others fan out to all linked active clients; UIs filter by selected session.

Production protocol negotiation, E2EE envelopes, acknowledgments, authoritative terminal snapshots and compatible upgrades remain roadmap work. This wire format may change before 1.0.

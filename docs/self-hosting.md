# Run your own AFK server

AFK doesn't come with a server. The Mac and the iPhone never talk to each other
directly; both connect out to a small relay that you run. Paste its address into
**Connection** on the Mac and the invitation QR carries it to the iPhone.

## What the server does

- **Forwards encrypted traffic.** The Mac and the iPhone open a TLS 1.3 session
  through the relay, end to end. The relay passes opaque bytes along and cannot read
  your terminals, keystrokes or session names.
- **Routes and pairs.** It keeps the Mac's and each iPhone's routing credentials so
  they can find each other, and holds the one-time pairing invitation.
- **Stores little.** PostgreSQL holds device names, device IDs and token hashes. The
  relay sees connection metadata: IP addresses, timing and traffic volume.
- **Never runs anything.** Shells live on the Mac. The Mac decides who may see or type
  into each session; the relay cannot grant that.

See [security](security.md) for the full boundary.

## What you need

- A host that can run a container and reach PostgreSQL. The relay creates its tables
  on start.
- A public **HTTPS** address with WebSocket support, for example a reverse proxy or
  a Cloudflare tunnel in front of the relay. A physical iPhone refuses plain HTTP;
  `http://127.0.0.1:8787` only works on the Mac itself and its simulator.

## Run it

The image `ghcr.io/jesuspaz/afk-relay` is published for amd64 and arm64 with every
release. Use the tag of the AFK version you run, for example `v0.1.0-rc.21`.

```yaml
# compose.yaml
services:
  postgres:
    image: postgres:18.4-alpine
    environment:
      POSTGRES_USER: afk
      POSTGRES_PASSWORD: ${AFK_DATABASE_PASSWORD:?required}
      POSTGRES_DB: afk
    volumes:
      - postgres:/var/lib/postgresql
  relay:
    image: ghcr.io/jesuspaz/afk-relay:v0.1.0-rc.21
    environment:
      DATABASE_URL: postgres://afk:${AFK_DATABASE_PASSWORD}@postgres:5432/afk
    ports:
      - "127.0.0.1:8787:8787"   # put your HTTPS proxy in front of this
    depends_on: [postgres]
volumes:
  postgres:
```

| Variable | Default | |
| --- | --- | --- |
| `DATABASE_URL` | required | PostgreSQL connection string |
| `AFK_LISTEN` | `0.0.0.0:8787` in the image | Address the relay listens on |

Check it from outside: `curl https://your-server/readyz` answers when the relay and
its database are ready. Keep `/metrics` private; it is meant for your own monitoring.

## Connect the Mac

1. On the Mac, open **Connection**, paste `https://your-server` and choose
   **Connect to server**.
2. Pair the iPhone from **Devices**. The phone shows the server address before you
   confirm, so check it is yours.

Changing the server later disconnects every paired device; pair them again on the
new one.

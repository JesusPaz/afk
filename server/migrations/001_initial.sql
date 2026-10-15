CREATE TABLE IF NOT EXISTS hosts (
    id text PRIMARY KEY,
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    token_hash bytea NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    pairing_hash bytea,
    pairing_expires_at timestamptz
);
CREATE TABLE IF NOT EXISTS clients (
    id text PRIMARY KEY,
    host_id text NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
    name text NOT NULL,
    token_hash bytea NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz
);
CREATE INDEX IF NOT EXISTS clients_host_id_idx ON clients(host_id);

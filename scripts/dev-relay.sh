#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ ! -f .env ]; then echo 'Create .env from .env.example first.' >&2; exit 1; fi
set -a
. ./.env
set +a
export DATABASE_URL="postgres://afk:${AFK_DATABASE_PASSWORD}@127.0.0.1:55432/afk?sslmode=disable"
cd server
exec go run ./cmd/relay

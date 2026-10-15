#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
set -a
. ./.env
set +a
export AFK_TEST_DATABASE_URL="postgres://afk:${AFK_DATABASE_PASSWORD}@127.0.0.1:55432/afk?sslmode=disable"
cd server
exec go test -race ./...

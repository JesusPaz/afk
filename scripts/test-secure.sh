#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ -z "${AFK_TEST_DATABASE_URL:-}" ]; then
    set -a
    . ./.env
    set +a
    export AFK_TEST_DATABASE_URL="postgres://afk:${AFK_DATABASE_PASSWORD}@127.0.0.1:55432/afk?sslmode=disable"
fi
swift build --build-tests
export AFK_TEST_SWIFT_PACKAGE="$PWD"
cd server
exec go test -race -count=1 -v -run '^TestRealSecureSwiftPTY$' ./internal/relay

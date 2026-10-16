# AFK

Read README.md and docs/security.md before changing transport or terminal code.

- Swift apps and core are native Apple code; the relay is Go with PostgreSQL.
- Never log terminal contents, pairing secrets, bearer tokens, or request bodies.
- Local input and remote input must go through the same control authority.
- Keep queues and terminal replay bounded. Do not replay uncertain input.
- Test Go with `go test -race ./...` from server; test Swift with `swift test`.
- Use real PostgreSQL for store integration tests via AFK_TEST_DATABASE_URL.
- Every PR links a tracking issue. Do not claim production readiness or E2EE while the POC trusts the relay.

- For native UI validation, use Xcode MCP, xcodebuild and simctl. Do not use Computer Use unless Jesus explicitly asks for it.

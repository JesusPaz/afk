# AFK

Your terminal, with you. A native Mac app runs your shells; the iPhone app lets you
watch them and type into them from anywhere, end-to-end encrypted.

**Personal beta, not independently audited.** See [security and boundaries](docs/security.md).

## Install

**Mac** (macOS 14+, Apple Silicon or Intel):

```sh
brew install --cask JesusPaz/tap/afk@preview
brew upgrade --cask afk@preview   # later updates
```

Or download the signed, notarized DMG from [Releases](https://github.com/JesusPaz/afk/releases).
Quitting AFK ends its shell sessions, so quit it yourself before updating. If you
installed AFK by hand before, move the old app out of Applications before switching
to Homebrew.

**iPhone** (iOS 17+): internal TestFlight.

## Use it

1. Open AFK on the Mac; a shell starts right away.
2. In **Devices**, choose **Pair iPhone** and scan the QR with the iPhone app.
3. Compare the code on both screens and approve on the Mac.
4. Share sessions from **Devices → Sessions and permissions** (pairing alone shares nothing).
5. On the iPhone, open a session and tap **Type from here** to type or dictate.

Shortcuts on the Mac: **⌘K** go to a terminal, **⌘⌥↑ / ⌘⌥↓** previous / next,
**⌘1…9** jump, **⌘⌥← / ⌘⌥→** or **⌃⌘1…9** switch profile, **⌘N** new session.

## Docs

| | |
| --- | --- |
| [Using AFK](docs/usage.md) | Pairing, devices, sessions, groups, profiles, history, limits |
| [Development](docs/development.md) | Run locally, tests, native builds, repository layout |
| [Releasing](docs/releasing.md) | Step-by-step release from this Mac or EAS |
| [Publishing reference](docs/publishing.md) | Workflows, credentials, signing |
| [Security](docs/security.md) · [Protocol](docs/e2ee.md) · [Architecture](docs/architecture.md) | How it is built and what it protects |

MIT licensed.

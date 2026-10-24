# Using AFK

How the Mac and iPhone apps work day to day. For installing, see the [README](../README.md).

## Pair an iPhone

1. On Mac, a local shell opens immediately. Open **Devices** and choose **Pair iPhone**.
2. On iPhone, choose **Pair Mac**, scan the QR (or paste the invitation), and confirm the displayed server. Compare the code on both screens, then approve on the Mac with local authentication.
3. On Mac, open **Devices → Sessions and permissions** and explicitly share sessions. Pairing alone exposes none. Choose read-only or temporary control (15 minutes, 1 hour, 8 hours); creation and closing are separate permissions. On iPhone, open a shared session and take control if allowed.
4. On Mac, choose **Type here** (`⌘⇧L`) to write locally again.
5. Manage linked phones and access history under **Devices**. Five minutes without accepted input downgrades control to read-only. **Stop all remote access** clears session grants; revocation also removes device trust. Both leave local terminals running. Temporary session grants are cleared when AFK quits; [trusted devices](#trusted-devices) keep their access.

On Mac, drag files from Finder onto the active terminal to insert their shell-quoted
paths. Multiple files, spaces and quotes are supported; dropping never presses Enter.
The Mac must have typing control. This inserts local paths, not file uploads.

AFK connects to the saved relay when the Mac app opens, unless remote access was explicitly paused. Pausing persists across launches.

If an iPhone session cannot open, its error remains visible and **Copy diagnostics**
copies the failure time, connection stage/category, iOS version and AFK build.
Diagnostics contain no terminal text, file paths, server addresses or credentials.
After reconnecting, the phone waits for the authorized session list before restoring
the selected session.

The secure invitation expires in five minutes and works once. Saved device credentials live in Keychain.

## Mac keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘N | New session in the current group |
| ⌘K | Go to any terminal by name, folder, group or profile |
| ⌘⌥↑ / ⌘⌥↓ | Previous / next terminal in sidebar order |
| ⌘1 … ⌘9 | Jump to the Nth terminal |
| ⌃⌘1 … ⌃⌘9 | Switch profile |
| ⌘⇧L | Take or release typing control on the Mac |
| ⌘, | Settings (live-session limit) |

The toolbar **+** creates a session next to the selected one; hold it to create a
group or profile. Pairing an iPhone lives in **Devices**.

## Typing and dictating from the iPhone

While the iPhone has control, a text field sits above Esc / Tab / Ctrl+C. Type or
use iOS dictation there: each edit appears on the Mac's terminal line as you speak,
including corrections, and **Send** presses Enter. Using a special key or typing in
the terminal itself hands the line back to the terminal. Smart quotes and dashes are
converted to plain ASCII. See [dictation behavior and validation](dictation.md).

## Sessions, groups and profiles

On Mac, rename a session or use its automatic terminal title, then organize sessions
into named groups with a symbol and color. A manual name takes precedence over OSC
0/2 titles; OSC 7 supplies directory context when the shell announces it. iPhone
shows the same authorized names and groups. Group editing is currently Mac-only.
Choose a flat system symbol or a single emoji using the macOS character picker.
Groups remain saved and visible even after their last session closes, including
after restarting AFK; their shell processes are not restored.

On Mac, use the profile tabs above the sidebar (or ⌃⌘1…9) to switch between
**Personal**, **Work**, and custom profiles created with **+ → New profile…** in the
toolbar; beyond four profiles the tabs become a menu.
Each profile shows its own groups, ungrouped sessions, hidden sessions and ended
sessions. Existing organization starts in Personal. New groups and sessions belong
to the selected profile. Use **Move to profile** in a group or session's context
menu; moving a group includes its sessions, while moving a single session removes
it from its old group. Switching profiles clears the selected terminal and keeps
all shells and renderers running without changing typing control.
Drag sessions onto a group header or another session in that group to move them.
Drop onto **Ungrouped** to remove their group; this destination stays visible even
when empty. Profile names, group assignments and the selected profile survive app
relaunch; shells do not.
Restoring a terminal recording yields between bounded batches and shows progress;
input remains disabled until restoration completes. An unavailable history archive
shows a notice while the remote live screen continues updating.

Profiles organize the Mac workspace locally. iPhone access still follows the
existing session permissions, and Saved history remains a shared archive.

Hide keeps a session running and can be undone. Hidden state is local to each device.
Close and remove waits for the shell and foreground process group to exit, then
removes the row while preserving saved history. Detached processes and external
services are outside that guarantee. Ended sessions have a separate section and do
not consume the live-session limit. Hiding or removing the selected session
never transfers typing to another terminal automatically.

See [the feature plans and validation](plans/session-organization/README.md).

## Trusted devices

New pairings use Secure Enclave identities. iPhone requires enrolled Face ID/Touch ID
for each connection; the Mac proves possession of its own pinned hardware key.
In **Devices**, explicitly choose **Trust this device…** to grant persistent access
to all current/future sessions and permission to create/close them. Mac authentication
is required. **Remove trust** disconnects the phone; **Stop all remote access** also
removes persistent grants. Session permissions remain available from the Session menu.

For an existing software identity, choose **Protect Mac identity…** first and confirm
removing old pairings. Then pair the updated iPhone app again and grant trust.
Changing enrolled phone biometrics requires pairing again. Secure Enclave is required
for new identities; simulator/software fallback is not enabled in the app.
See [security boundaries](security.md) and [protocol](e2ee.md).

## Connection recovery

The Mac checks its relay connection when returning to the foreground or waking,
and periodically while running. A linked iPhone checks the authenticated path to
the Mac when opened and while active. Failed connections retry with increasing
waits capped at 30 seconds; health checks run every 30 seconds with a 10-second
response deadline. The phone suspends connections in the background and reconnects
on return. Manual Mac remote-access pause remains in effect until explicitly resumed.
Authentication cancellation or identity/protocol rejection requires user action;
recovery never replays uncertain input or automatically reclaims typing control.

## Saved terminal history

Mac sessions now record all output and ordered size changes under
`~/Library/Application Support/AFK/Session History`. Recordings survive quitting AFK
and restarting the Mac until explicitly deleted in **Saved history**. They do not
restart the shell or execute recorded commands. Active recordings cannot be deleted;
end the session first. Existing sessions from an older app cannot recover output
already discarded before this feature was installed.

Switching sessions keeps each live renderer attached, including its alternate screen
and background updates. The live Mac terminal retains 10,000 scrollback lines in RAM.
**Saved history** provides a recording-position slider and previous/next controls to
browse the complete disk recording in bounded batches, including earlier output
outside live scrollback. Opening a recording of an active session captures its current
length; reopen it to refresh. Reopening a live window reconstructs the renderer from
the recording, which can take time for long sessions.

On iPhone, scroll backward in the terminal to load older rows automatically. There is
no separate history menu and opening a session does not download its full recording.
In alternate-screen applications such as Codex, history belongs to the application:
while controlling the session, a vertical drag sends wheel events just like the Mac.
Take control with **Type from here** to browse that application-owned history.
Pages for normal shell history contain at most 64 rows / 64 KiB. The phone prefetches
one page after showing the current screen and keeps a bounded in-memory cache for
the current attachment, including when returning to live. It renders at most 256
historical rows plus the current screen; leaving the session clears the cache. Scrolling forward fetches newer pages and returns to live
output. New output does not move the row being read. Choosing **Type from here**
returns to the current screen before enabling input.

The Mac builds an owner-only, disk-indexed row archive alongside its original ANSI
recording. Rows retain their rendered text and colors at the width where they entered
history; the raw recording remains available in Mac **Saved history**, including
terminal redraws. The iPhone uses bounded memory rather than a complete disk copy.

The recording files are owner-only (directories `0700`, files `0600`), contain terminal
output that may include secrets, and are not separately encrypted by AFK. They never
go to the relay. There is no automatic age/size deletion; available disk space is the
limit. A recording failure is shown in the session while the shell continues running.
Normal termination flushes the file; a crash/power loss can leave an incomplete tail,
reported when reading it. This does not guarantee recovery of unwritten output.

## Languages

The Mac and iPhone apps support English and Spanish. Each app follows the device’s preferred languages (including regional variants such as es-CO and en-GB), with English as the fallback. macOS/iOS per-app language settings are supported; relaunch AFK after changing the language. No in-app language picker is required.


## Current boundaries

- Up to 24 live sessions by default (adjustable in Settings, 1–64) and eight connected clients per Mac; iPhone remembers one Mac.
- The current controller determines the shared terminal size: Mac window or iPhone viewport (including rotation and keyboard). Observers retain that grid and can scroll when it is larger than their screen. Updated iPhones open the current screen immediately and fetch older history automatically when scrolling backward. The Mac keeps the complete recording on disk. Older iPhones still use the 256 KiB snapshot protocol; update both apps for long sessions.
- Sessions survive closing the Mac window, **not quitting AFK, reboot or sleep with an active network connection**. There is no separate background helper yet.
- Reconnection is automatic (see above), but there is no offline keystroke queue and input is never replayed after a disconnect.
- SwiftUI screens implement the functional flows; final visual polish and accessibility/device validation remain.
- No App Store release, accounts, file transfer, audio, screen mirroring, Android, Windows or Linux host.

See [architecture](architecture.md), [protocol](protocol.md), [roadmap](roadmap.md).

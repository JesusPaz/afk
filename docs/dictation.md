# Live dictation and delivery confirmation

Apple's [UITextInput](https://developer.apple.com/documentation/uikit/uitextinput)
delivers insertions and replacements to custom text views. SwiftTerm 1.20.0's
`iOSTextInput.replace(_:withText:)` translates a replacement into one delegate
call per backspace, followed by the replacement text. Sending every callback as
a separate encrypted packet can exhaust AFK's 16 pending writes before the main
actor has processed any completions. A short correction can trigger this; it
does not require a large paste.

`TerminalInputBuffer` groups bytes in fixed 16 ms windows, without waiting for a
pause or for dictation to finish. It preserves byte order (including UTF-8 and
control characters), sends at most 8 KiB per packet, retains at most 64 KiB across
queued and unacknowledged data, and permits four packets in flight. Host PTY
output is also grouped in fixed 16 ms windows with a 64 KiB bound. Resize,
snapshot and exit boundaries flush preceding output first. These are scheduling
windows, not an end-to-end latency guarantee; network and OS scheduling add delay.

The host advertises `inputAcknowledgements: true` in snapshots. An `inputAck`
identifies the session, lease epoch and input sequence. It means the host accepted
the bytes into its bounded PTY path, not that the shell completed a command. The
host remembers 256 accepted input sequences for the current epoch. Duplicate
input cannot pass the lease sequence check again, but can receive another ACK.
Resize or a later input is not proof that an earlier input was accepted.

After one second without confirmation, the phone retries the oldest outstanding
packet with the same sequence and bytes. It stops after three attempts and
returns to read-only with an explicit notice. Permission checks apply to retries;
duplicates do not refresh the accepted-input idle deadline. Unknown ACKs do not
free the buffer. Queue overflow is reported rather than silently truncating text.

There is no replay across disconnect, backgrounding, session change or lease
change. The ordered TLS/WebSocket stream already retransmits network packets;
application retries recover a missing delivery confirmation while that context
is still valid. If the connection disappears, the phone cannot infer whether the
last Enter executed, and reports unconfirmed input instead of replaying it into
a new lease. The new iPhone app requires the updated Mac app for writable sessions;
an older Mac remains readable with an update notice.

## Validation

- `swift test`: batching, continuous input, UTF-8 chunk boundaries, capacity,
  cancellation, missing ACK retries, retry exhaustion and lease-bound receipts.
- `scripts/test-secure.sh`: real TLS peers, relay, PostgreSQL and PTY; partial
  input before Enter, repeated corrections, lost ACK without duplicate execution,
  and a suppressed initial send followed by retry.
- Build both native apps. Physical iPhone dictation still needs device validation;
  synthetic callback tests do not exercise Apple's speech recognition service.

Verified locally on 2026-10-17 with Xcode 27.1: 64 Swift tests passed, plus all
three real relay/PTY integration scenarios (run separately from the ordinary
suite). Go race tests with PostgreSQL passed. Both AFKiOS simulator and AFKMac
builds passed. In the PTY scenario, partial text appeared before Enter, twenty
64-character corrections completed, a lost ACK did not execute a command twice,
and a suppressed first send was recovered by retry. No physical-device dictation
validation or distribution of these builds has been performed yet.

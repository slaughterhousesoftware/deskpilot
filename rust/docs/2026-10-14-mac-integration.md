# Mac app integration — October 14, 2026

Production `/Applications/Tempo.app` on Kevin's MacBook now runs the bundled Rust service.
`DeskModel` receives versioned UI frames and sends queued commands. It no longer creates
a Swift Bluetooth client, computes the live day rollup/timeline, processes commands, or
writes history/snapshots. Rust does those jobs. The existing Dashboard and widget consume
the compatible shared files; the Dashboard still computes its historical chart layouts
and aggregates in Swift.

## Validation

- Release Rust binary and unsigned Xcode app build succeeded.
- Rust workspace: 136 unit tests passed; all-feature/all-target Clippy with warnings
  denied passed; rustfmt check passed.
- Swift: 112 unit tests passed, including decoding a frame from the actual Rust daemon
  and rejecting an unsupported protocol version. Two opt-in Swift Bluetooth live tests
  were skipped because they would start a second Bluetooth client.
- `scripts/test-rust-hosted.py` passed: pause/resume, cruise off/on, sitting-preset capture,
  reconnect, backup, duplicate-service refusal, unavailable/unauthorized Bluetooth,
  simulated announcement/motor transition/settling, and stdin-EOF shutdown.
- Native Swift menu rendering inspected using a busy-day simulator and the real desk.
  Live posture, total, timeline, and next-move countdown appeared in the UI.
- Properly signed app and sandbox-inheriting helper passed strict recursive signature
  verification and connected to the desk from the production App Group directory.
- `DevBackendVerification` called the same Swift model methods used by the menu:
  toggled pause, observed the changed Rust state, restored the original pause state,
  reconnected, and observed connected state again. Its report returned `success: true`.
- A real desk countdown announcement was ingested while the app was running; when
  the motor did not start, the expired announcement was dismissed and the next interval
  was computed.
- Normal app termination flushed history and disconnected the snapshot; no child survived.
- Killing only the Rust helper caused the same menu bar process to launch a new helper
  and reconnect.
- Killing the menu bar process caused stdin EOF in the helper, which exited and wrote a
  disconnected snapshot with no pending next move. Relaunch connected successfully.
- The archive contained 1,525 events at final verification. All 1,476 recovered events
  before October 2 were retained exactly as JSON values, including dates. Daily backups
  for October 13 and 14 remain present. The Dashboard opened against the shared files.

A warm process sample showed 18.9 MiB RSS for the UI and 7.3 MiB for Rust, with 0.0%
and 0.4% CPU respectively. Startup RSS was higher. This is not a controlled comparison
against identical Swift UI code, and does not establish lower overall memory usage.

## Recovery and evidence

MacBook pre-install data and previous Swift app:

`~/Library/Application Support/Tempo-Recovery/20261014-151246-rust-integration/`

A second pre-install snapshot (before the final verification-hook build):

`~/Library/Application Support/Tempo-Recovery/20261014-151827-rust-integration/`

The active App Group contains `backend.log`, `rust-ui-verification.json`,
`rust-lifecycle-verification.json`, and `rust-real-ui-*.png`. A separate copy of the
history and evidence is kept on the Mac mini under
`~/Library/Application Support/Tempo-Recovery/20261014-rust-integration/`.

`DESKPILOT_DEV_BACKEND_VERIFY=<report path>` enables the opt-in Swift model check;
`DESKPILOT_DEV_SNAPSHOT=<prefix> DESKPILOT_DEV_SNAPSHOT_DELAY=25` captures the menu and quits.
Production was relaunched without either test option after verification.

Windows/Linux, overnight sleep recovery, and sustained multi-day reliability remain
outside this verification. Real pause/resume writes were tested; real preset/cruise writes
and forced motor movements were not performed. Their queue paths and transitions were
tested with the simulator.

# Real desk smoke test — October 14, 2026

The Apple Silicon release binary was built on the Mac mini and run on Kevin's MacBook
against its paired Ergodriven desk. The Swift menu bar app was stopped during testing;
the Rust daemon used a separate data directory seeded with copies of the production files.
No cruise, pause, preset, clock-write, or motor commands were issued.

## Verified

- Bluetooth discovery, connection, characteristic discovery, and burst notifications.
- Initial history read: 98 bytes; restored five observed moves.
- Live height 34.6 inches, standing, present, stationary; sitting preset 26.6 inches,
  standing preset 34.7 inches, cruise 20 minutes standing / 40 minutes sitting.
- The archived history grew from 1,514 to 1,521 events. All 1,476 historical events
  before October 2 remained byte-equivalent as JSON values, including event dates.
- An immutable daily backup appeared in the isolated directory's `history-backups`.
- `tempo reconnect` round-tripped through the command queue and reconnected in about
  four seconds, followed by settings/history sync and clock phase locking.
- SIGTERM exited the process, flushed history, and wrote `connected: false` with no
  `nextMove` to the test snapshot.
- The validated history and observed moves were copied atomically back to production.
  The Swift menu bar app was restarted and reported connected, with matching live
  height, presence, posture, cruise, and next-move timing.

One `ps` sample showed about 11 MiB RSS and 0.0% CPU; this is a single observation,
not a sustained performance benchmark.

## Evidence and recovery

MacBook original files and final Rust archive:

`~/Library/Application Support/Tempo-Recovery/20261014-145258-rust-live-test/`

MacBook isolated data, disconnected snapshot, and full daemon log:

`~/Library/Application Support/Tempo-Rust-Live-Test/`

Independent Mac mini copy of the final Rust history, snapshot, and log:

`~/Library/Application Support/Tempo-Recovery/20261014-rust-live-test/`

The test binary was wrapped in `/tmp/Tempo Rust Test.app`, with a Bluetooth usage
description and ad hoc signature, and launched through `open` in the MacBook's GUI
session. Bluetooth authorization was granted before discovery began.

## Still unverified

Real motor transitions, desk write commands, overnight/sleep recovery, long-running
Bluetooth reliability, and Linux/Windows builds and devices. Production continues to
use the Swift menu bar backend after this smoke test.

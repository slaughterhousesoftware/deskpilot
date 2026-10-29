# Tempo backend in Rust

A cross-platform backend for the Ergodriven Tempo standing desk: everything the Swift
`DeskpilotKit` does, in Rust, so Windows and Linux apps can share the same engine as the macOS
app. Protocol:
`../docs/protocol.md`.

## Layout

```
crates/tempo-core   pure, synchronous: protocol, history clock, motion tracker, rollup,
                    timeline, the DeskSession state machine, file stores
crates/tempo-desk   async service on tokio: Transport trait, Desk task, simulator
crates/tempo-ble    the transport over Bluetooth Low Energy (btleplug: macOS, Linux, Windows)
crates/tempo-cli    the `tempo` binary: daemon and command line
```

Dependencies point one way: cli -> ble -> desk -> core. `tempo-core` has no runtime and no
Bluetooth, so every timing rule the desk taught us is a plain function with time passed in.

## Build and test

Rust 1.89 or newer (`brew install rust` on this Mac).

    cd rust
    cargo build --release
    cargo test --workspace --all-features
    cargo clippy --workspace --all-targets --all-features -- -D warnings
    cargo bench -p tempo-core          # the per-poll hot path

After building the release binary, `python3 ../scripts/test-rust-hosted.py` exercises the
actual hosted daemon, including UI frames, commands, reconnect, simulated motion, backups,
exclusive ownership, failure states, and shutdown when its hosting app closes stdin.

Hot path on a full 8 KiB ring (4 096 entries), Apple Silicon, release:

| step | time |
|---|---|
| decode + date + merge + rollup | ~31 µs |
| rollup alone (what each poll costs once dated events are cached) | ~10 µs |

## Run

    tempo serve                        # connect to the desk, keep the files current
    tempo serve --sim busy-day         # a desk in memory; `tempo scenarios` lists them
    tempo status                       # "You're sitting at 26.6". 3h 20m at the desk ..."
    tempo status --json
    tempo watch                        # the snapshot as a JSON line on every change
    tempo history today                # totals and the timeline, from history.json
    tempo history totals --days 7
    tempo history export
    tempo cruise set 20 60             # 20 min standing per 60 min cycle
    tempo cruise off
    tempo pause | tempo resume
    tempo pulse on | tempo pulse off     # nudge instead of moving when the interval runs out
    tempo preset sit | stand | custom1 | custom2
    tempo user 0 | tempo user 1          # the desk's active user
    tempo name user "Alex"              # or preset1 / preset2: the desk's 20-byte name fields
    tempo clock                          # write the time of day (also done on every connect)
    tempo reconnect
    tempo backup [--to DIR]            # a dated, verified copy of history.json

`tempo preset` captures the current position as a saved height; it does not move the desk.

Commands other than `serve` talk to the running daemon through the file queue and wait up
to 15 s for its answer. Logs go to stderr; `--log tempo_core=debug` or `RUST_LOG` filter
them. The same notice lines the Swift app emits (status samples, history ingest, countdown
to motor, today) are there for field tuning.

## Files and compatibility

The data directory is `DESKPILOT_DATA_DIR` if set; else on macOS the Swift apps' App Group
container (`~/Library/Group Containers/LQV43S38FV.com.kevinpatel.tempo`) when it exists,
so the Dashboard, the widget and the Siri summary read what the daemon writes; else
`~/Library/Application Support/Tempo`, `%APPDATA%\Tempo` or `$XDG_DATA_HOME/tempo`.

Every file is byte-compatible with the Swift apps' `Codable` output: `snapshot.json`,
`history.json` (merged with the archive, with an immutable daily copy in
`history-backups/`), `observed-moves.json`, `commands/<ID>.json` and `results/<ID>.json`.
Dates are whole-second `2026-10-13T22:10:36Z`; reading accepts fractional seconds too.

Only one Bluetooth client can hold the desk. On macOS run either the Swift menu bar app or
`tempo serve`, not both.

The Mac menu bar app now launches its bundled Rust service (`serve --hosted`) instead of
the Swift Bluetooth engine. A versioned JSON stream on stdout carries full desk state,
today's timeline, saved totals, and the widget snapshot into the UI. Commands from the
menu, Dashboard, and intents all use the same queue. Hosted command polling runs every
250 ms. Closing stdin stops the service even if the app crashes; the app restarts a
crashed service. An OS file lock prevents two services from owning one data directory.

The service keeps live status polling separate from its 30-second settings refresh. The
refresh reads the active user, the user register block, and the active cruise slot's
contents even when its index has not changed; this picks up phone edits to the custom
slot, presets and day boundary, plus handset user switching. Names are read on connect
and when the active user changes. Unsupported block reads fall back to individual reads.
`state.settings.countdownTiming` carries the configured countdown and pulse timing from
user offset 8; it is optional for compatibility and is not a live countdown signal.

Undocumented register probes are disabled in normal app operation. Protocol research can
opt in with `tempo serve --probe-registers`; this adds seven serialized register reads
(14 GATT operations, excluding retries) to each history poll near a predicted move.
It does not send motor or configuration commands. The app never passes this flag.

Xcode embeds the release binary through `scripts/build-rust-backend.sh`; installation
signs it with sandbox inheritance before signing the app. The installed app needs no
Rust toolchain. The Dashboard's historical chart rendering remains Swift.

## Bluetooth per platform

The desk must be bonded once at the OS level: hold its UP button for four seconds, pair,
and enter the six-digit code it shows. `btleplug` has no pairing API.

* macOS: pair from System Settings > Bluetooth. A terminal running `tempo serve` is asked for
  Bluetooth permission the first time.
* Linux: `bluetoothctl` -> `scan on`, `pair <addr>`, `trust <addr>`. Needs BlueZ 5.
* Windows: Settings > Bluetooth & devices > Add device.

## Status

Written 2026-10-13/14. Tested against the in-memory desk and a port of every `DeskpilotKit`
unit test. On October 14, the release binary also passed a real-desk smoke test on the
MacBook: Bluetooth discovery, settings/history reads, live status, manual reconnect,
clock phase locking, daily backup, and SIGTERM shutdown.
Linux and Windows builds are not verified on this machine (no rustup targets).
The integrated Mac app was then installed and tested on the MacBook, including commands
through the actual Swift model and recovery after killing either process.

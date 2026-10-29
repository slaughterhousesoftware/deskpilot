# Ergodriven Tempo BLE protocol

Reverse-engineered on 2026-09-04 from the Android app `com.ergodriventempo` v0.5 (28)
(React Native / Hermes bundle) and verified against a live Tempo running application
firmware 1.0.5. Nothing here is documented by Ergodriven; treat every field as
"observed", not "guaranteed".

## Transport

* Bluetooth Low Energy peripheral, advertised name `Ergodriven Tempo`.
* Advertises one 128-bit service UUID; manufacturer data company id `0x0CFF`.
* Chip family: Nordic nRF52 (SoftDevice revision register, Nordic Secure DFU used for
  firmware updates, app has a `setupNordicDFUCentralManager` path).
* **Bonding with a passkey is required.** Every characteristic returns
  `Insufficient Encryption` until the central is bonded. Pairing mode is entered on the
  handset by holding UP for 4 seconds; the desk shows a 6-digit key that the central must
  enter. The bond persists.
* Default ATT MTU 23; every value characteristic is 4 bytes, burst data is 20 bytes.

## GATT table

Service `da582000-796b-40fd-aeab-b06c95c30a5e`

| Characteristic | App name    | Props              | Purpose |
|----------------|-------------|--------------------|---------|
| `da582001-…`   | `addr`      | read, write        | Register address selector (uint32 LE) |
| `da582002-…`   | `data`      | read, write, notify| Value at the selected address (uint32 LE). Notifies ~2 Hz continuously with the current value while subscribed |
| `da582003-…`   | `alert`     | read, write, notify| Unused by the app. Never notified during testing |
| `da582010-…`   | `burstAddr` | read, write        | Byte address for bulk reads/writes (uint32 LE) |
| `da582011-…`   | `burstLen`  | read, write        | Number of 20-byte chunks to stream (uint32 LE). Writing it triggers the burst |
| `da582012-…`   | `burstData` | read, write, notify| Streams `burstLen` notifications of 20 bytes each, auto-incrementing from `burstAddr`. Also the write target for bulk writes |

All integers are little-endian.

## Register access

* **Read register `A`:** write `A` to `addr`, then read `data` (or subscribe to `data`
  and take the next notification). While `data` is subscribed the desk keeps pushing the
  value at the selected address about twice a second, which makes a cheap live stream:
  select register 60 once and listen.
* **Write register `A` = `V`:** write `A` to `addr`, then write `V` to `data`.
  The app special-cases address 16 (magic number): writing the value read from 16 back
  to 16 reboots the desk into the Nordic DFU bootloader. Never write to 16.
* **Bulk read `n` chunks from byte address `B`:** write `B` to `burstAddr`, write `n` to
  `burstLen`, then collect `n` notifications on `burstData` (20 bytes each, consecutive).
  The plain read value of `burstData` is just the last chunk. The desk ignores the low two
  bits of `burstAddr`: reads start at the address rounded down to a multiple of 4; read
  from the aligned address and skip the leading bytes.
* **Bulk write:** write `B` to `burstAddr`, then write up to 20 bytes to `burstData`.
  Used by the app for the 20-byte name strings.
* **Bulk reads cover the registers too.** The register space is one flat little-endian
  address space, so a burst from byte 0 returns registers 0..76 and a burst from a user
  block's base returns its first words. Verified live 2026-10-29: the service reads the
  global block (4 chunks: firmware, minutes, history size and pointer, user, clock, status)
  and the user block (3 chunks: flags, slot, countdown, heights, move count) this way on
  connect, and the whole sync - settings, the 1 kB log, restored moves - took 1.9 s where
  the twelve individual reads took about 4. A block that decodes to nonsense (firmware major
  above 15, pointer past the ring, a flagged status word) demotes that connection to
  register reads; none has yet.
* **The value is latched when `addr` is written.** Reading `data` again without rewriting
  `addr` returns the value from the time of the write, not the register now (2026-10-29: a
  service that skipped the write for repeated status polls showed the height standing
  still for seconds after a paddle move). Every register read needs both operations.

Unmapped addresses read `0xDEADBEEF`.

## Global registers (byte addresses)

| Addr | Name (from app) | Observed | Notes |
|-----:|-----------------|----------|-------|
| 0    | –               | 0        | |
| 4    | `fw_rev_appl`   | `0x00010005` | Application firmware 1.0.5 |
| 8    | `fw_rev_bl`     | 0        | Bootloader revision |
| 12   | `fw_rev_sd`     | 18       | Nordic SoftDevice revision |
| 16   | magic number    | 14       | Writing it back triggers bootloader. **Do not write.** |
| 20   | `num_users`     | 2        | |
| 24   | `num_cruise_setting` | 5   | Cruise-control timing slots |
| 28   | `misc_flag`     | 0        | |
| 32   | `min_since_pwr_on` | 5432  | Minutes since power-on; the history clock |
| 36   | history size    | 8192     | Bytes in the history ring buffer |
| 40   | minutes to wrap | 256      | Timestamp byte modulus |
| 44   | history write ptr | 428    | Byte offset of the next history entry |
| 48   | –               | 9        | |
| 52   | `cur_user`      | 0        | Active user index (0 or 1). Writable |
| 56   | clock           | `0x000C0C2B` | `hour<<16 \| minute<<8 \| second`. App writes it on every sync |
| 60   | status          | `0x0000010B` | See below |
| 72   | –               | 1        | Meaning unknown. Do not confuse with **user offset** 72 below |
| 76   | –               | 1        | |
| 228  | –               | 1208     | Not a minimum height (an earlier guess used it as one); meaning unknown. The app uses a fixed 20 in floor |

### Status register 60

* bits 0..15: current desk height in tenths of an inch (267 = 26.7 in).
* bit 31: desk is in motion (verified with the paddle; app method `inMotion`).
* bits 16..30 stayed 0 during testing. Presence is not in this register.

## Per-user blocks

User 1 at byte 4096, user 2 at byte 8192 (`USER_ADDRESSES = {1: 4096, 2: 8192}`).
Offsets are relative to the block base.

| Off | Name | User 1 observed | Notes |
|----:|------|-----------------|-------|
| 0   | flags | `0x1E3` | Bitfield, see below. Written by `setUserInfo` |
| 4   | `cruiseControl` | 1 | Active cruise slot index. 0 = cruise control off. The app always uses slot 1 as the editable "custom" slot |
| 8   | countdown / pulseTime | `0x0008000F` | low16 = countdown (15), high16 = pulseTime (8). The app writes `(pulseTime << 16) \| countdown` when either setting changes (APK write path rechecked 2026-10-29; these writes were not live-tested in that audit) |
| 12  | `middleOfNightHour` | 4 | Hour used to split days in stats. The app clamps this to 0–23 and writes it when changed (APK write path rechecked 2026-10-29) |
| 16  | `standingHeight` | 411 | Tenths of an inch (41.1 in). **Writing any value stores the desk's current height**; the written value is ignored (verified 2026-09-04) |
| 20  | `sittingHeight`  | 266 | Tenths of an inch (26.6 in). Same capture-current-height behaviour on write |
| 24  | `customHeightOne` | 0 | Preset "Custom 1", 0 = unset. Presumably same capture behaviour |
| 28  | `customHeightTwo` | 0 | Preset "Custom 2", 0 = unset. Presumably same capture behaviour |
| 32  | – | `0x00060000` | |
| 36  | – | 1 | |
| 40  | move count | 1191 | `user1MoveCount` in the app |
| 72  | `collisionSensitivity` | Not verified on this desk | APK `syncDeskData` writes `COLLISION_MAP[collisionSensitivity]` at **user base + 72**, only when `desk.type == 5`. This is not global register 72; model support and values require further verification |
| 256 | `userName` | (unset) | 20-byte string via burst write |
| 320 | `presetNameOne` | (unset) | 20-byte string |
| 384 | `presetNameTwo` | (unset) | 20-byte string |
| 512 + 16·N | cruise slot N | see below | Five slots, 16 bytes apart (N = 0..4) |

### Cruise slots (offset 512 + 16·N)

Each slot is one uint32: `(standingSeconds << 16) | sittingSeconds`. The app computes
`sittingSeconds = cycleSeconds - standingSeconds`, always writes slot 1, then sets
`cruiseControl` = 1. Observed on user 1:

| N | Addr | Value | Standing | Sitting | Meaning |
|--:|-----:|-------|---------:|--------:|---------|
| 0 | 4608 | `0x0008000F` | 8 s | 15 s | Unused / factory test values |
| 1 | 4624 | `0x04B004B0` | 20 min | 20 min | Active custom slot: 30 min standing per hour |
| 2 | 4640 | `0x02580BB8` | 10 min | 50 min | 10 min/hour |
| 3 | 4656 | `0x04B00960` | 20 min | 40 min | 20 min/hour |
| 4 | 4672 | `0x07080708` | 30 min | 30 min | 30 min/hour |

The desk's rhythm: after a move to standing it waits `standingSeconds`, counts down, and
lowers; after a move to sitting it waits `sittingSeconds`. The countdown entry
(`MOVE move=0`) is logged roughly a minute before the move itself. Moves only happen while
the user is present; absence pauses the cycle.

### User flags (offset 0)

| Bit | Name |
|----:|------|
| 0 | `sitPresetSet` |
| 1 | `standingPresetSet` |
| 2 | `paused` |
| 3 | `reserved` |
| 4 | `pulseOnly` |
| 5 | `userEnabled` |
| 6 | `userSelected` |
| 7 | `historyLoggingEnabled` |
| 8 | unknown, set on both users |

User 1 = `0x1E3`: presets set, not paused, enabled, selected, logging on.

## History ring buffer

* Base byte address `0x10000` (65536), size = register 36 bytes, write pointer =
  register 44 (byte offset). Read with bursts; the app reads it in 100-byte bursts.
* Each entry is 2 bytes: `[time][event]`.
  * `time` = minutes since power-on modulo 256. The firmware writes `NOP` entries as wrap
    markers, so a backward walk from a `(minutesSincePowerOn, now)` reference - computing
    `(reference - t) mod 256` at each step, never counting wraps explicitly - reconstructs
    absolute time correctly across long gaps (verified against a 4-day log); see
    `HistoryDecoder.dateEntries`.
  * `event` byte decoded by top bits:

| Pattern (event byte) | Type | Payload |
|----------------------|------|---------|
| `0b01011xxx` (top5 = 11) | `MOVE_OR_COUNTDOWN` | bit0 `raise`, bit2 `move`. `move=0` is the pre-move countdown; `move=1` is the actual move. `raise` gives the new standing state |
| `0b01010xxx` (top5 = 10) | `PRESENCE_CHANGE` | bit0 `present` |
| `0b0100xxxx` (top4 = 4)  | `USER_CHANGE` | bits 0..3 new user |
| `0b001xxxxx` (top3 = 1)  | `HEIGHT_CHANGE` | height in inches = 20 + bits 0..4 |
| anything else, incl. `0x00` | `NOP` | padding / power cycle marker |

Typical sequence for an automatic stand: `MOVE raise=1 move=0` (countdown), then
`HEIGHT 41`, then `MOVE raise=1 move=1`. A paddle nudge logs the same `MOVE` shape without
actually reaching the other preset, so `DayRollup.compute` counts a stand only as a
sitting→standing transition derived from the `HEIGHT` entry that immediately precedes each
`MOVE`, not from the raise bit alone.

Polling register 44 and reading new entries is the only observed way to get presence.
Latency measured live: "not present" was logged about 4 minutes after the user walked
away (the desk debounces absence). The return was not logged as a separate entry before
the desk started a countdown and moved, so any `MOVE_OR_COUNTDOWN` entry also implies
present = true.

### Write latency

The desk writes the log **late**. Observed 2026-09-04: an automatic stand whose own minute
stamps say 15:45 (countdown), 15:46 (`HEIGHT 41`, `MOVE raise=1 move=1`) was still not
readable through the write pointer at 15:49 or 15:54 by an app polling register 44 every
5 s; a raw dump at 15:54:49 showed all three entries present. So an entry can surface
several minutes after the event it describes, and the ~4 minute presence lag noted above is
the same effect rather than (only) a debounce.

Consequence: **the history log is not a real-time source.** Anything time-sensitive - the
current posture, "did the desk just move", the countdown anchor - must come from the status
register (60), which is live and cheap to poll. The log is still the only source for
presence, for the day's history before the app connected, and for reconciling what the desk
thinks it did. `TempoDesk` therefore derives `.move` events from status transitions
(`observedMoves`, byte offset -1) and merges them with the decoded log, dropping an observed
move once a logged move of the same direction shows up within ±3 minutes of it.

### Countdown accuracy

The popover's live countdown is not read from the desk; it is computed by
`DayRollup.compute` (`Sources/DeskpilotKit/DayRollup.swift`) as the timestamp of the last move
plus the active cruise slot's `standingSeconds` or `sittingSeconds` for the state that move
produced. Because of the write latency above, that last move is normally the one detected
live from the status register (the motion bit falling, or a ≥ 2 in height jump between
polls, classified against the midpoint of the sitting/standing presets), not the logged one:
the countdown is anchored to the live-detected move and later reconciled with the log, which
drops the duplicate when it finally arrives. If the log gets there first — possible after a
reconnect — it anchors the countdown instead and the matching live detection is suppressed.
The end-to-end check against a full automatic cycle is still outstanding.

The desk itself doesn't move the instant the interval elapses: it beeps first. The beep is
15 s - the user block's countdown field (offset 8, low 16 bits) reads 15 - and the COUNTDOWN
log entry is written when it starts. Measured on 2026-09-08 with the log read every second
around the predicted move (`TempoDesk.currentHistoryPollInterval`): previous motor start
16:39:57.9, COUNTDOWN entry readable 16:59:54.97 (1197 s later, on a 1200 s standing
interval), motor start 17:00:08.2 (13.2 s after the entry), settled 17:00:16.3. So the desk
counts its interval from the previous *motor start*, begins beeping about 5 s before it
elapses, and moves `DayRollup.beepSeconds` (15 s) after that - `DayRollup.moveLeadSeconds`
(10 s) past the interval. The app dates observed moves at the motor start for that reason
(`TempoDesk.motionStartedAt`). Earlier figures of 29-66 s were measured from the settle,
which lands ~8 s after the motor start, with the entry read every 5 s.

That estimate is only as good as the desk's timer is regular, and it isn't: three sitting
intervals on 2026-09-08 ran 8 s, 68 s and 120 s long with no absence logged in between.
The desk evidently pauses its timer whenever it loses sight of the user, even briefly, and
never logs those pauses. So the app's countdown is an estimate up to the beep, then hands
over to the desk: the COUNTDOWN entry is read within a second or two of being written, and
from then on `NextMove.announcedAt` is set and `NextMove.at` is the entry's read time plus
`TempoDesk.countdownEntryToMotorSeconds` (14.5 s: entry-to-motor measured 13.2, ~14, ~14.5,
~14.5 and ~14.7 s over five cycles on 2026-09-08/09) - the menu bar shows that in seconds. An
announcement for the wrong direction, or one older than two minutes with no move, is ignored
and the interval rule stays in charge (a waved-off countdown). Verified live on the next
cycle (2026-09-08): COUNTDOWN read 17:32:32.9, predicted motor 17:32:45.9, motor actually
started between 17:32:46.4 and 17:32:47.4 (first moving sample 17:32:47.46 at 28.2 in).

The desk's pre-move **pulse** is a single 0.1 in nudge (26.7 -> 26.8 in) with the motion
bit clear, 6.7 s after the COUNTDOWN entry was read (17:32:39.6), and the height stays there
until the motor starts. Nothing else moves before the beep: the height held for the ten
minutes before it, sampled every second. It is not used as a trigger - the entry is read
sooner - and `TempoDesk.motionStartedAt` deliberately keys on the motion bit so the pulse
doesn't date the move. The unknown registers (48, 72, 76, 228, user block +32/+36/+40) did
not change during either countdown (`TempoDesk.pollProbe`; +40, the move count, ticks once
the move is done), and the status register's bits 16-30 stayed zero throughout.

Sitting intervals run long far more than standing ones: on 2026-09-08 the four measured
sitting intervals overran their 1800 s by 120, 68, 145 and (earlier) ~8 s, the two standing
intervals their 1200 s by -3 and +8 s. Presumably the sensor loses a seated user more often.

Two things keep the estimate's anchor honest across restarts: observed moves are persisted
in the App Group (`ObservedMoveFile`) and restored on connect, and the history clock is
phase-locked on the first register-32 tick seen between two polls, dating logged entries to
the middle of their minute rather than to wherever in the minute the connection-time read
fell (that read alone moved the same prediction between 23:07:14Z and 23:08:00Z across five
restarts on 2026-09-07). The COUNTDOWN entry's own minute stamp is too coarse to time
anything by; `DayRollup.compute` keeps the interval-based prediction when it agrees with the
stamped announcement to within two minutes, and only lets the stamp take over when the
interval prediction is clearly off.

The desk's own timer anchors on its own completed **or aborted** moves, and on manual ones -
a COUNTDOWN doesn't always end in a MOVE. If the user reverses the move before it finishes,
the desk logs the HEIGHT it stopped at with no MOVE entry at all; that HEIGHT is the real
anchor for its next countdown, not the COUNTDOWN's originally announced direction.
`DayRollup.compute` tracks this as a pending countdown, resolved by whichever comes first: a
`.heightChange` (the aborted/no-op case - posture is `inches >= standingThresholdInches`) or
a `.move` (the completed case). Evidence, 2026-09-04:

- `19:54 COUNTDOWN down` → `19:55 HEIGHT 41`, no MOVE at all - the user reversed an
  in-progress sit; the desk stayed standing, and its next countdown (for sitting again) has
  to count from 19:55, not from the abandoned 19:54 announcement.
- `18:27 HEIGHT 29` / `MOVE down` (manual, while marked absent) → `18:34 absent` → `18:52
  HEIGHT 26` (the desk's own no-op "sit" on the user's return - no COUNTDOWN or MOVE
  accompanies it, so it's outside this rule and simply passes through) → `18:53 present` →
  `19:11 COUNTDOWN up` → `19:12 MOVE down` (the user cancelled the stand before it
  completed - the log still records the actual resulting MOVE) → `19:34 COUNTDOWN up` +
  `HEIGHT 41` + `MOVE up` (a normal completed stand).
- 2026-09-05, sitting, waving every stand off: `00:57 COUNTDOWN up` → `01:17 COUNTDOWN up`
  → `01:38 COUNTDOWN up` + `HEIGHT 26` (started to rise, reversed) → `01:59 COUNTDOWN up` →
  `02:21 absent`. A **dismissed** countdown - no MOVE and no HEIGHT within a few minutes -
  restarts the desk's interval too: the next announcement lands one interval plus about a
  minute later, i.e. the anchor is roughly `moveLeadSeconds` after the announcement, with
  the posture unchanged. `DayRollup.compute` treats any countdown older than
  `countdownResolutionWindow` (5 min) that nothing resolved as dismissed. Until it did, the
  01:59 announcement was still "pending" at 11:49 the next morning and the popover sat on
  "Waiting for the desk" through the whole return. Five minutes is still too long when the
  user is watching (2026-09-12: a sit waved off at 13:39:45 read "Sit coming up" and then
  "Waiting for the desk" until 13:44:35), and the app has better evidence than the log: it
  read the COUNTDOWN entry live and then watched the status register not move. Once the
  announcement grace (`countdownEntryToMotorSeconds + announcementGraceSeconds`) passes with
  no motion, `TempoDesk` hands the read time to `DayRollup.compute` as
  `dismissedCountdownAt`, which dismisses the matching entry at once and restarts the
  interval from the read time itself: next motor 1206.9 s after that read on a 1200 s
  interval, i.e. read time plus interval plus the usual `moveLeadSeconds`. Absences logged
  *before* a dismissed countdown belong to the interval that just ended and no longer push
  the restarted one back (they did: a 13:03-13:26 absence put the re-anchored estimate at
  14:22 when the desk sat at 13:59).

What to look for the next time someone is at the desk for a full cycle: the countdown
should reach "now" within about a minute of the desk's own countdown beep and the
`MOVE move=0` history entry that precedes the actual move; the popover icon should switch
to the moving glyph while `isMoving` is true; the posture (`isStanding`) should flip after
the move; and the stands counter should increment when the move is sit→stand. Any
consistent offset is most likely clock drift between `history time` (minutes since
power-on, reconstructed via register 32) and wall-clock `Date`, or the four-minute
presence debounce delaying when the app resumes counting down after the user returns.

### Absences hold the timer

The desk holds its interval timer while it doesn't see you. 2026-09-11: sat 12:41:01, logged
absent 13:04:27 to 13:12:07 (7 m 40 s), and the stand due at 13:21 came at 13:33:13 - the
logged absence plus about 4.5 min of the short pauses it never logs. 2026-09-04 fits too (a
manual sit at 18:27 while absent, back at 18:53, no stand by 19:28). The estimate is therefore
last move + interval + the logged absences since the move (`DayRollup`), which runs early by
the unlogged pauses (and, since the refinements below, can run a few minutes late), and the
app polls the log every second from ten minutes (originally four) before the estimate until
the move itself - previously it stopped ten minutes past the
estimate and, after re-anchoring to the return (a rule the 09-11 data refutes: it predicted
13:52), read the COUNTDOWN entry on the slow 5 s poll, 3 s late, so the timer ran 3 s behind.

Two refinements (2026-09-26, fitted over the 63 cycles with an absence from 09-08 to 09-25):

- **The timer restarts at the day boundary** (`middleOfNightHour`). Every overnight cycle
  with no visit after the boundary moved one full interval after the morning's return
  (sits 39-41 min on a 40 min interval, stands 18-20 on 20). Holding yesterday's minutes
  instead made the evening of 09-26 due at 20:58 when the user sat down at 21:07, and the
  menu bar read "overdue" from then on; the desk announced at 21:47:25.
- **Absences are logged late.** Visits the desk logs as 7-8 min (5:36-5:43, 16:50-16:58,
  ...) are mostly its delay before writing "not present"; the timer stopped when the user
  left. `DayRollup.absenceLogLagSeconds` (7 min) dates each hold that much before the entry.
  Lags of 4-7 min fit about equally on average; 7 leaves the fewest estimates early (7 of
  63), the side that shows "overdue". Together: mean error 9.4 -> 3.3 min, early 36 -> 7.

### Read cadence and the constant (2026-09-11)

The COUNTDOWN entry is read every 0.3 s inside the last minute before the estimate and for as
long as it runs overdue (every 1 s from ten minutes out - four until 2026-09-26 - and 5 s otherwise). 21:56 cycle: entry
read at 29.93, first moving sample at 44.90 with 1.1 in already travelled at ~1.5 in/s, so the
motor started ~14.3 s after the read; the user saw the label still at 0:01. The timer constant
is 14.1 s from the read; the app logs `countdown to motor N s` at notice level every cycle.

### Cancelled countdowns, live

A waved-off countdown has no signature of its own in anything the desk exposes (no log
entry, no status bit, no `alert`), so it is detected by the motor *not* starting. The
motor has started 13.2-14.7 s after the COUNTDOWN entry was read on every cycle measured,
and 14.09 s on 2026-10-29 15:26; the status register is read every 0.25 s from the entry
until `countdown_entry_to_motor + announcement_grace + 2 s` (`DeskSession::status_poll_fast`),
so a motor start is seen within a quarter second. Four seconds past the expected motor
time with the motion bit still clear is therefore conclusive: `TodayStats.cancelled_move`
is set (`reason = wavedOff`), the announced countdown is dismissed and the interval
restarts from the read time as before. A motor that starts but settles in the same posture
within 45 s of the entry is `reason = reversed`. The finding stays until the desk's next
announcement or move; the menu bar shows the cancellation confirmation for five seconds and the popover's
headline reads "Stand / Cancelled" with the restarted countdown in the tooltip. Until
2026-10-29 the grace was 15 s, so "now" sat on screen for a quarter of a minute after
every wave-off.

### Where a move stops

The desk clears the motion bit before it has finished travelling (40.5 in moving, 41.1 in
a second later, 2026-09-08), and a paddle release coasts the same way. `coast::CoastModel`
learns that overshoot per direction from every move it watches - a constant-deceleration
fit (`v²/2a`, `v` from a least-squares slope over the last 1.2 s of moving samples, `a`
exponentially averaged from each settle) blended with the median of the last eight
overshoots - and publishes `DeskState.predicted_height_tenths` while the desk coasts. Every
settle logs a `coast` line with the prediction's error for tuning; the seed is the one
measurement above (1.5 in/s, 0.6 in). First real lessons, 2026-10-29: the desk coasts
0.2-0.7 in after the bit clears (up: 291 -> 298, 300 -> 305, 286 -> 289; down: 265 -> 263,
264 -> 261), its readings never go backwards, and after one move per direction the
prediction was within a tenth. The menu bar's readout does *not* use it: a prediction a
tenth high reads as the number ticking back when the desk settles, which the user noticed
at once, so the readout follows the real height (polled every quarter second, so a paddle
press shows within one poll).

### Connecting quickly

The desk's CoreBluetooth identifier is kept in `peripheral-id` in the data directory. A
connect first asks the OS for that peripheral and for any connected peripheral carrying the
desk's service (`retrieve_peripherals`) and connects to it directly; only without one does
it scan, and then it reacts to the discovery event rather than polling the adapter's list.
A remembered desk that fails to connect within 8 s is forgotten so the next attempt scans.
The clock register is written on every connect, as the phone app does.

## Identified commands and remaining uncertainty

No direct "move now" or "go to height" command has been identified in the reviewed
Android app BLE write paths. The observed movement mechanisms are the handset paddle and
the desk's own rhythm. This does not establish that the controller firmware has no other
commands, or rule out behavior in another app version.

An explicitly authorized live test on 2026-10-29 did cause movement through Tempo,
but **did not discover a direct movement command**. It temporarily changed the active
cruise slot from 20 minutes standing / 40 minutes sitting to 20 minutes / 1 minute.
Tempo then ran its own countdown and raised the desk from 26.1 to 34.7 inches.
The original settings were restored and the captured settings objects match exactly.
The user explicitly rejected this scheduling workaround; it is not an implementation
of raise/lower and must not be exposed as a Deskpilot movement action.

The inspection build adds `tempo inspect`, which returns cached state through the
existing service command queue without a second Bluetooth connection, and logs the
already-discovered GATT services. The live inventory contained Tempo's `da582000…`
service with address/data/alert and burst characteristics; no FlexiSpot `FFF0`/`FFF1`
service or raw forwarding route was identified. This observation does not rule out an
undocumented command inside Tempo's register protocol.

The identified app writes include user flags (pause, pulse-only, enable, select), preset
capture (the standing/sitting register writes were observed to save the current height),
cruise-control slot and timing, the active user, clock, names, countdown/pulse timing,
the day-boundary hour, and the bootloader magic. The fresh APK's `syncDeskData` generator
(function #15049) explicitly writes user offset 8 and offset 12; the earlier inventory
omitted those two configuration writes. Deskpilot reads these fields, but its typed
command API does not currently expose setters for them.

The same generator contains a model-specific collision-sensitivity write at user base
+ 72 when `desk.type == 5` (bytecode offsets 0x65e–0x690). No such write has been sent to
this desk. This is another configuration capability, not a direct motion command; the
earlier global-register-72 note conflated an absolute address with a user-block offset.

The production Rust service now refreshes settings through the existing block reader
every 30 seconds, including the current user and the active slot's contents. Checking only
flags and the slot index missed phone edits to the custom slot, preset heights and day
boundary. Offset 8 is retained as optional typed `countdownTiming` configuration in its
state stream; it is not used as a live countdown or substituted for measured motor timing.
Experimental reads of 48, 72, 76, 228 and user offsets 32, 36, 40 require the explicit
`tempo serve --probe-registers` flag. The app leaves them disabled so seven additional
register reads do not compete with height polling near a move.

The service exposes the previously implemented controls via `tempo pause|resume`, `tempo pulse on|off`,
`tempo preset sit|stand|custom1|custom2`, `tempo cruise`, `tempo user 0|1`, `tempo name
user|preset1|preset2 <name>`, `tempo clock`. The `alert` characteristic is subscribed and
logged; it has still never notified.

### Firmware package recovered, 2026-10-29

The APK's update client uses `https://api.ergodriven.com/api/v1/updates` and
`/api/v1/updates/{id}/download`. The metadata returned update ID 3, version 1.0.5;
the download response was base64 text encoding `Clovis_Pkg_1.0.5.zip`. Its nested DFU
archives contain an application image, bootloader image, and Nordic S113 SoftDevice.
The package was downloaded and unpacked locally without contacting or writing to the desk.

The application and bootloader payloads do not begin with ordinary Cortex-M vector tables
and have near-8-bit-per-byte entropy; they may be encrypted or otherwise encoded. The
SoftDevice image has a conventional vector table. The application register-write handler
has **not** been decoded, so this package is an investigation lead, not evidence for or
against a hidden motor-control command.

The three Nordic DFU init packets were decoded using the upstream `dfu-cc.proto` layout.
Each declares SHA-256 and a 64-byte ECDSA-P256 signature; every declared image hash matches
the downloaded bytes (Nordic stores these hashes in reverse byte order). The signature
itself was not verified without the vendor's public key. This establishes that the opaque
application bytes match the package metadata, rather than being a bad base64 extraction.
In the reviewed JavaScript update path, `sendUpdate` (#22506) extracts the nested archives,
its component loop (#22512) passes their paths to `NordicDFU.startDFU`, and the bridge
(#18935) forwards the path to the native module. No application-image decoding was
identified in those JavaScript paths. The follow-up native inspection below traces the
archive bytes through the Android DFU library; firmware dispatch remains unresolved.

Reference schema: [Nordic pc-nrfutil dfu-cc.proto](https://github.com/NordicSemiconductor/pc-nrfutil/blob/master/nordicsemi/dfu/dfu-cc.proto).

The package SHA-256 is
`6a7e87f3c6dc61a66a0db4ad278d9237c244c65d1daff2872b9d019bf45a6e63`.

### Native DFU follow-up and older firmware

Static inspection of all three DEX files found that the vendor's
`BluetoothDeviceManager` handles bonding and disconnects, with no raise/lower methods.
`RNNordicDfuModule.startDFU` passes the archive path to Nordic's `setZip` API.
`ArchiveInputStream.parseZip` extracts the image bytes; `BaseCustomDfuImpl` and its
callback read that stream into a byte array and pass it to the GATT write. No custom
payload decryption was identified in this reviewed path. The 58 crypto call sites found
in the DEX inventory belong to generic fingerprint, Okio and TLS code, not the vendor
Bluetooth module or DFU upload. The downloaded base APK has no native `.so` files;
ABI split packages were not inspected, so this is not an exhaustive audit of every
possible native component.

Update ID 2 also yielded firmware 1.0.4. Its application payload has the same opaque
structure, while the bootloader and SoftDevice hashes match the 1.0.5 package. Bounded
checks of common compression formats did not decode either application image. High
entropy suggests encryption or custom encoding, but does not identify a cipher or prove
that a hidden command exists. These findings narrow the remaining work to firmware
decoding or new protocol evidence; they do not justify guessed register writes.

The static firmware investigation did not flash firmware or issue motor commands.

### FlexiSpot hardware route, 2026-10-29

The user's photos identify the frame as **FSCA-E7B-Plus-Max**, with lifting-column
label **EC40SP1D3-1-650/610**, and the separate control box as **CB38M4A(IB)-1**
(`IMG_5502.jpg` through `IMG_5504.jpg`). Its label lists outputs M1-M4. FlexiSpot's
[E7 Plus Max manual](https://s3.springbeetle.eu/dev-de-s3-flexispot/commodity/item/E7B-Plus-MaxManual-250925.pdf)
shows that box beneath the middle of the desktop, between the frame beams: printed
page 6, steps 7-8. The connector side and current Tempo wiring are not visible in the
photos, so an available handset port has not been verified on the user's setup.

FlexiSpot's official [BT057 adapter page](https://www.flexispot.com/desk-bluetooth-adaptor-bt057)
explicitly lists E7 Plus Max compatibility and describes Mac control of raise/lower,
four presets, and current height. It documents an inline adapter with keypad
passthrough, or a direct connection on supported control boxes. The adapter is also
[listed in Canada](https://www.flexispot.ca/desk-bluetooth-adaptor-bt057).
This is stronger model-specific evidence than assuming that an arbitrary RJ45 bridge
will work. Neither page establishes coexistence with an Ergodriven Tempo handset.

The download URL embedded in both official product pages supplied
`FlexiSpot-Smart-Desk-Control-App_20260310_G8wXyv4W.zip`. Its Mac app identifies itself as
FlexiSmart 1.1.0 (`com.Loctek.LocalMotion`). Static inspection, without launching it,
found `FFF0`/`FFF1` Bluetooth UUID strings and a `BluetoothProtocol` class containing
`cmdForTableTargetHeight:`, `cmdForTableResponseType:` and `cmdForTableInfo`. The arm64
target-height implementation at `0x10003c6d0` appends a two-byte argument and invokes
the CRC/framing helpers. This is an actual command-construction path, not just UI
wording, but its units, full transport behavior, stop semantics and operation on the
user's hardware have not been validated. These commands belong to the FlexiSpot
adapter, not Tempo's `da582…` register interface.

The app archive SHA-256 is
`988f6c8c65d8cb96cefbaa5b9e1fe0008969ed48195394c7ead01a07277f87e1`;
the universal executable SHA-256 is
`cadf9dd6c5fbc84a794fd6d092daabd02153158174ad8d9e1db200f1989265a7`.
The downloaded vendor app and firmware are not distributed in this repository.

A DIY alternative exists: the author of
[flexispot-esphome](https://github.com/dimitri-vs/flexispot-esphome)
reports working up/down and presets on an E7 Pro Plus with HS13M-1C0 keypad and
CB38M2L control box. That is not the user's verified control-box model. The
[Upsy Desky compatibility list](https://upsy-desky.tjhorner.dev/docs/reference/compatibility/)
does not establish support for this FlexiSpot model either.

The control-box photos yielded a more specific match:
[DeskUp Pro FlexiSpot](https://smarthomeguys.github.io/DeskUp-Pro-Flexispot/)
lists **CB38M4A(IB)-1 with HS13G-1 keypad on an E7Q** in its confirmed compatibility
table. It requires a spare RJ45 handset port (usually marked HS), retains the original
controller, and runs on ESPHome/Wi-Fi. Its setup documentation makes Home Assistant
optional and describes a local web interface and REST access, although its REST
endpoint documentation is unfinished. This is evidence that this exact control-box
model supports external commands, not validation of the user's Tempo combination.

[LoctekMotion issue 114](https://github.com/iMicknl/LoctekMotion_IoT/issues/114)
also reports external control of CB38M4A(IB)-1 alongside an HS13M-1C0 handset, with
two handset sockets. That implementation initially stopped accepting movement commands
after idle periods despite continuing to report height. Users reported that waking the
screen before a command restored movement; the project's merged
[wake-before-action fix](https://github.com/iMicknl/LoctekMotion_IoT/pull/139)
closed that issue. Other keypad combinations have unresolved failures in
[issue 72](https://github.com/iMicknl/LoctekMotion_IoT/issues/72), so a model-number
match alone does not establish reliable operation with every handset or firmware.
Any Deskpilot bridge integration needs an idle/wake/reconnect test and actual movement
feedback, rather than treating a successful packet write as proof the desk moved.

If BT057 is validated, Deskpilot should add it as a separate motion transport with
explicit capabilities. Tempo can continue supplying its presence/history and cruise
settings if coexistence is confirmed. Motion controls should be enabled only for a
verified transport, with a tested stop/release path and without replaying movement
commands after reconnect. Do not reinterpret Tempo preset-capture writes as movement
commands or temporarily shorten cruise timing to simulate an immediate move.

Useful additions supported by current Tempo protocol evidence include setters for
countdown/pulse configuration and the stats day boundary. Timed pauses, work-hours
rules and saved cruise profiles can build on existing pause/resume and cruise commands;
app-side scheduling would depend on the Mac being awake and connected. These are
potential additions, not newly shipped features. Collision sensitivity remains
model-gated and unverified on this device.

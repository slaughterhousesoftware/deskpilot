import Foundation

public struct NextMove: Equatable, Sendable, Codable {
    public let at: Date
    public let toStanding: Bool
    /// When the desk's own COUNTDOWN entry was read, if it has been: from then on `at` is
    /// the desk's timing (entry plus `TempoDesk.countdownEntryToMotorSeconds`), good to a
    /// second or two, rather than the app's interval arithmetic. `nil` while estimating.
    public let announcedAt: Date?
    public init(at: Date, toStanding: Bool, announcedAt: Date? = nil) {
        self.at = at; self.toStanding = toStanding; self.announcedAt = announcedAt
    }

    /// True once `now` is more than 90 s past `at`. The desk doesn't move the instant the
    /// cruise interval elapses - it waits out an audible countdown first (see
    /// `DayRollup.moveLeadSeconds`), and can run further behind that depending on presence
    /// timing - so a plain "now"/"any second" countdown reads as broken once it's been
    /// sitting at zero for a while; the UI switches to an "overdue" presentation instead.
    public func isOverdue(now: Date) -> Bool {
        now > at.addingTimeInterval(90)
    }

    /// When the desk starts (or started) beeping: `DayRollup.beepSeconds` before `at`. This
    /// is the moment the user experiences as "the desk is moving", so it is what the app's
    /// minute countdowns run down to; between here and `at` the desk is counting.
    public var announceAt: Date { announcedAt ?? at.addingTimeInterval(-DayRollup.beepSeconds) }

    /// True once the desk has actually announced this move (its COUNTDOWN entry was read),
    /// as opposed to the app's estimate having merely reached the beep.
    public var isAnnounced: Bool { announcedAt != nil }

    /// True while the desk should be running its own countdown (or moving).
    public func isAnnounced(now: Date) -> Bool {
        now >= announceAt
    }
}

/// Why an announced move came to nothing.
public enum CancelReason: String, Equatable, Sendable, Codable {
    /// The desk beeped and the motor never started: the paddle waved it off.
    case wavedOff
    /// The motor started and the desk ended up in the same posture: reversed mid-move.
    case reversed
}

/// The desk announced a move and the user stopped it. Stays in `TodayStats` until the desk's
/// next announcement or move; the UI shows it for `displaySeconds`.
public struct CancelledMove: Equatable, Sendable, Codable {
    /// When the app concluded the move was off.
    public let at: Date
    public let toStanding: Bool
    public let reason: CancelReason
    public init(at: Date, toStanding: Bool, reason: CancelReason) {
        self.at = at; self.toStanding = toStanding; self.reason = reason
    }

    /// How long the menu bar says "cancelled" before going back to the countdown. The backend
    /// hides the badge after this long (CANCELLED_SHOWN_FOR); this also guards a stale frame.
    public static let displaySeconds: TimeInterval = 5

    public func isShowing(now: Date) -> Bool {
        now.timeIntervalSince(at) < Self.displaySeconds
    }
}

public struct TodayStats: Equatable, Sendable, Codable {
    public var atDeskSeconds: TimeInterval
    public var stands: Int
    public var isStanding: Bool?
    public var isPresent: Bool
    public var nextMove: NextMove?
    public var cancelledMove: CancelledMove?

    public init(atDeskSeconds: TimeInterval = 0, stands: Int = 0, isStanding: Bool? = nil,
                isPresent: Bool = false, nextMove: NextMove? = nil, cancelledMove: CancelledMove? = nil) {
        self.atDeskSeconds = atDeskSeconds
        self.stands = stands
        self.isStanding = isStanding
        self.isPresent = isPresent
        self.nextMove = nextMove
        self.cancelledMove = cancelledMove
    }
}

public enum DayRollup {
    /// How long the desk beeps before it moves: the "countdown" field of the user block
    /// (offset 8, low 16 bits) reads 15, and the COUNTDOWN log entry, written when the
    /// beeping starts, became readable 13.2 s before the motor started on 2026-09-08 with
    /// the log read every second (docs/protocol.md, "Countdown accuracy").
    public static let beepSeconds: TimeInterval = 15

    /// Where the desk's next move lands past `last motor start + interval`: the beep began
    /// 1197 s after the previous motor start on a 1200 s interval (2026-09-08, 16:39:57.9 ->
    /// 16:59:54.97), i.e. about 5 s early, and the motor followed `beepSeconds` later. So the
    /// motor starts roughly interval + 10 s after the previous one. Added to `nextMove.at`;
    /// `NextMove.announceAt` is `beepSeconds` before that. Only an estimate: the desk also
    /// pauses its timer for short absences it never logs (three sitting intervals on
    /// 2026-09-08 ran 8 s, 68 s and 120 s long), which is why the estimate hands over to
    /// the desk's own announcement (`NextMove.announcedAt`) as soon as that is read.
    public static let moveLeadSeconds: TimeInterval = 10

    /// How long after the user leaves the desk writes "not present": its timer stopped when
    /// they left, so a hold starts this much before the logged absence. Visits the desk logs
    /// as 7-8 min are mostly this lag (2026-09-19 and -26: 5:36-5:43, 16:50-16:58, ...).
    /// Over the 63 cycles with an absence from 2026-09-08 to 09-25, lags of 4-7 min fit
    /// about equally (mean error 3.2-3.4 min, against 4.6 taking the entry at its word);
    /// 7 leaves the fewest estimates early (7 of 63), and early is the costly side - the
    /// label reads "overdue" - where late only defers to the desk's own COUNTDOWN entry.
    /// 2026-09-26: two such visits, back 21:07:34, desk announced at 21:47:25 (8 min: 21:47:44).
    public static let absenceLogLagSeconds: TimeInterval = 7 * 60

    /// The desk splits days at `middleOfNightHour` (user block offset 12).
    public static func dayStart(now: Date, middleOfNightHour: Int, calendar: Calendar = .current) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = middleOfNightHour
        parts.minute = 0
        parts.second = 0
        // `date(from:)` can return nil for a wall-clock time that doesn't exist (a DST gap).
        // Fall back to start-of-day + middleOfNightHour hours, then to plain start-of-day.
        let todayBoundary = calendar.date(from: parts)
            ?? calendar.date(byAdding: .hour, value: middleOfNightHour, to: calendar.startOfDay(for: now))
            ?? calendar.startOfDay(for: now)
        if now >= todayBoundary { return todayBoundary }
        return calendar.date(byAdding: .day, value: -1, to: todayBoundary)
            ?? todayBoundary.addingTimeInterval(-86400)
    }

    /// A `MOVE` entry within this many seconds of an immediately preceding `HEIGHT` entry is
    /// treated as stamped the same minute (the desk logs `HEIGHT n` right before the `MOVE`
    /// it produced).
    private static let heightMoveWindow: TimeInterval = 90

    /// How long a `.countdown` stays eligible to be resolved (completed or aborted) by the
    /// next `.heightChange`, and how long it keeps announcing the move. Beyond this it was
    /// dismissed (see `dismissCountdown` in `compute`): a later `.heightChange` is treated as
    /// unrelated - a paddle nudge, possibly after an absence in between - not its abort.
    private static let countdownResolutionWindow: TimeInterval = 5 * 60

    /// How far a `.countdown`'s logged date may sit from `dismissedCountdownAt` and still be
    /// the entry the app read live: the log dates entries to the minute from an anchor with
    /// up to a minute of seconds-of-minute jitter (see `TempoDesk.recomputeToday`).
    private static let liveCountdownMatchWindow: TimeInterval = 120

    /// Pure rollup of dated events. `events` must be in chronological order.
    ///
    /// - Parameter standingThresholdInches: the midpoint (in whole inches) between the
    ///   sitting and standing presets. When given, a `.move`'s actual resulting posture is
    ///   derived from the `HEIGHT` entry the desk logs immediately before it (same minute),
    ///   rather than trusted from the move's raise bit - a paddle nudge that doesn't cross
    ///   the threshold (e.g. `HEIGHT 29, MOVE up, HEIGHT 26, MOVE down`, logged within one
    ///   minute) still logs `MOVE up`/`MOVE down` and must not count as a stand. `nil`
    ///   (the default) keeps the raise bit as the posture, e.g. for a live-observed move,
    ///   which has no preceding `HEIGHT` entry.
    /// - Parameter dismissedCountdownAt: when the app read the desk's latest COUNTDOWN entry
    ///   live and then watched the motor *not* start (see `TempoDesk.recomputeToday`). The
    ///   log alone can't tell a dismissed countdown from one about to move until
    ///   `countdownResolutionWindow` has passed, and meanwhile the pending announcement
    ///   reads as a move due any second - "sit coming up", then "waiting for the desk", for
    ///   four and a half minutes after the user waved it off (2026-09-12, 13:40-13:44). This
    ///   dismisses the matching countdown at once, anchored on the read time, which is good
    ///   to a fraction of a second where the log's stamp is good to a minute.
    public static func compute(events: [HistoryEvent], now: Date, dayStart: Date,
                               cruise: CruiseSlot?, paused: Bool,
                               standingThresholdInches: Int? = nil,
                               dismissedCountdownAt: Date? = nil) -> TodayStats {
        var present = false
        var presentSince: Date?
        var atDesk: TimeInterval = 0
        var stands = 0
        var isStanding: Bool?
        // Gates the stands counter, separately from `isStanding` (which must keep reflecting
        // the desk's actual current posture even when its most recent move happened before
        // today). Seeded exactly once, from `isStanding` as of just before the first event
        // dated at/after `dayStart` - i.e. the posture the desk carried across the day
        // boundary - so a move counts as a stand only when it's a genuine sitting->standing
        // *transition within today*: neither a re-affirmation of a posture the desk already
        // held when today started, nor a second move to the same posture in a row (the desk
        // occasionally logs one of those).
        var isStandingToday: Bool?
        var seededToday = false
        var lastMove: (date: Date, toStanding: Bool)?
        // Logged absences since the last move, summed: the desk holds its interval timer
        // while it doesn't see you (2026-09-11: sat 12:41, away 13:04-13:12, and the stand
        // due at 13:21 came at 13:33 - the 7:40 logged plus a few minutes it never logs), so
        // the next move is pushed back by at least this much.
        var absentSinceMove: TimeInterval = 0
        var absentSince: Date?
        // The desk's timer anchors on its own completed *or aborted* moves, and on manual
        // ones. A `.countdown` sets this; the next `.heightChange` (a HEIGHT entry logged
        // with no `.move` following, e.g. the user reversed an in-progress move) resolves it
        // as a move at that height - completed if it crossed the threshold, aborted (a no-op
        // back to the starting posture) if it didn't - and a `.move` resolves it too. While
        // still set at the end of the loop, nothing has resolved it yet and it anchors
        // `nextMove` directly (see below).
        var pendingCountdown: (date: Date, toStanding: Bool, absentBefore: TimeInterval)?

        func closeInterval(at end: Date) {
            guard let start = presentSince else { return }
            let clippedStart = max(start, dayStart)
            let clippedEnd = min(end, now)
            if clippedEnd > clippedStart { atDesk += clippedEnd.timeIntervalSince(clippedStart) }
            presentSince = nil
        }
        func markPresent(at date: Date) {
            if !present { present = true; presentSince = date }
        }
        // Shared by `.move` and a `.heightChange` that resolves a pending countdown: records
        // `date`/`toStanding` as the desk's latest move, counting a stand only on a genuine
        // sitting->standing transition within today (see `isStandingToday` above).
        func applyMove(at date: Date, toStanding: Bool) {
            if date >= dayStart {
                if toStanding, isStandingToday != true { stands += 1 }
                isStandingToday = toStanding
            }
            isStanding = toStanding
            lastMove = (date, toStanding)
            absentSinceMove = 0
            // A move while marked absent (a manual one): the hold counts from the move.
            if absentSince != nil { absentSince = date }
        }
        // A countdown that never became a move or a height change was dismissed - the user
        // waved it off, or walked away. The desk restarts its interval from that dismissal,
        // not from the older move: field data (2026-09-05) shows dismissed stand countdowns
        // recurring at 00:57, 01:17, 01:38 and 01:59 - every interval plus about a minute,
        // i.e. anchored ~`moveLeadSeconds` after each announcement. Posture is unchanged, so
        // this is not a move and counts no stand. Before this, a dismissed countdown kept
        // anchoring `nextMove` for as long as nothing resolved it - nine hours, in one case.
        //
        // `anchor` is where the restarted interval counts from: the log's minute stamp plus
        // `moveLeadSeconds` by default, or the live read time of the entry when the app
        // watched the dismissal itself (2026-09-12: read 13:39:44.96, next motor 13:59:51.9,
        // 1206.9 s later on a 1200 s interval - the read time plus the usual lead).
        func dismissCountdown(_ pending: (date: Date, toStanding: Bool, absentBefore: TimeInterval),
                              anchor: Date? = nil) {
            // Posture unknown so far: the announced direction says what the desk thinks it is.
            lastMove = (anchor ?? pending.date.addingTimeInterval(moveLeadSeconds), isStanding ?? !pending.toStanding)
            // The timer restarts here, so only absences *since* the countdown hold it: the
            // ones before it were already part of the interval that just ran out (2026-09-12:
            // a 23 min absence before a dismissed sit pushed the re-anchored estimate to
            // 14:22; the desk sat at 13:59, a plain interval after the dismissal).
            absentSinceMove -= pending.absentBefore
        }
        // The desk starts its interval afresh each day: every overnight cycle on record with
        // no visit after the boundary moved one full interval after the morning's return
        // (sits 39-41 min on a 40 min interval, stands 18-20 on 20). Holding yesterday's
        // minutes instead put the stand due before the user had even sat down (2026-09-26:
        // due 20:58, back 21:07, "↑…" from then on). Posture carries over; only the timer
        // restarts, as if at a move at `dayStart`.
        func restartTimerAtDayStart() {
            if let pending = pendingCountdown,
               dayStart.timeIntervalSince(pending.date) > Self.countdownResolutionWindow {
                dismissCountdown(pending)
                pendingCountdown = nil
            }
            guard let move = lastMove, move.date < dayStart else { return }
            lastMove = (dayStart, move.toStanding)
            absentSinceMove = 0
            if absentSince != nil { absentSince = dayStart }
        }

        for (index, event) in events.enumerated() {
            if !seededToday, event.date >= dayStart {
                isStandingToday = isStanding
                seededToday = true
                restartTimerAtDayStart()
            }
            switch event.kind {
            case .presence(let p):
                if p {
                    if let absentSince { absentSinceMove += event.date.timeIntervalSince(absentSince) }
                    absentSince = nil
                    // A presence(true) event is the desk's authoritative presence signal, so
                    // it always (re)anchors the interval start, even if we were already
                    // marked present from an earlier countdown/move.
                    present = true
                    presentSince = event.date
                } else if present {
                    // The timer stopped when the user left, `absenceLogLagSeconds` before
                    // this entry - but not before this visit, move or countdown began.
                    var left = event.date.addingTimeInterval(-absenceLogLagSeconds)
                    for floor in [presentSince, lastMove?.date, pendingCountdown?.date] {
                        if let floor { left = max(left, floor) }
                    }
                    closeInterval(at: event.date)
                    present = false
                    absentSince = min(left, event.date)
                }
            case .countdown(let toStanding):
                markPresent(at: event.date)
                if let pending = pendingCountdown { dismissCountdown(pending) }
                pendingCountdown = (event.date, toStanding, absentSinceMove)
            case .move(let raiseBit):
                markPresent(at: event.date)
                pendingCountdown = nil
                var toStanding = raiseBit
                if let threshold = standingThresholdInches, index > 0,
                   case .heightChange(let inches) = events[index - 1].kind,
                   abs(event.date.timeIntervalSince(events[index - 1].date)) <= heightMoveWindow {
                    toStanding = inches >= threshold
                }
                applyMove(at: event.date, toStanding: toStanding)
            case .heightChange(let inches):
                // Only meaningful right after an unresolved countdown - a HEIGHT entry with
                // no MOVE following, e.g. the user reversed the move before it completed -
                // and only within `countdownResolutionWindow` of it. Beyond that window this
                // is an unrelated later event, not that countdown's abort: drop the pending
                // countdown unresolved and ignore the height, as before this feature existed.
                guard let pending = pendingCountdown else { break }
                guard event.date.timeIntervalSince(pending.date) <= Self.countdownResolutionWindow else {
                    dismissCountdown(pending)
                    pendingCountdown = nil
                    break
                }
                let toStanding = standingThresholdInches.map { inches >= $0 } ?? pending.toStanding
                applyMove(at: event.date, toStanding: toStanding)
                pendingCountdown = nil
            case .userChange, .nop:
                break
            }
        }
        if !seededToday { restartTimerAtDayStart() }
        if present { closeInterval(at: now) }
        if let pending = pendingCountdown {
            if let dismissedAt = dismissedCountdownAt,
               abs(pending.date.timeIntervalSince(dismissedAt)) < Self.liveCountdownMatchWindow {
                // The app watched this very countdown come to nothing - dismissed now, on the
                // read time, rather than after `countdownResolutionWindow` on the minute stamp.
                dismissCountdown(pending, anchor: dismissedAt)
                pendingCountdown = nil
            } else if now.timeIntervalSince(pending.date) > Self.countdownResolutionWindow {
                // Still pending at the end of the timeline, but old enough that its move would
                // have been logged by now - dismissed, so it re-anchors the timer rather than
                // announcing.
                dismissCountdown(pending)
                pendingCountdown = nil
            }
        }

        var nextMove: NextMove?
        if let cruise, !paused, present {
            // The interval-based prediction, when there is a move to count from.
            let fromInterval: NextMove? = lastMove.map { lastMove in
                let wait = lastMove.toStanding ? cruise.standingSeconds : cruise.sittingSeconds
                return NextMove(at: lastMove.date.addingTimeInterval(Double(wait) + moveLeadSeconds),
                                toStanding: !lastMove.toStanding)
            }
            if let pending = pendingCountdown {
                // The desk has announced this move and nothing has resolved it yet - a
                // `.heightChange` (completed or aborted, see above) or a `.move` would have
                // cleared `pendingCountdown`. The announcement's own stamp is only good to the
                // minute, and the desk writes it anywhere from a few seconds to a minute
                // before the move (2026-09-07: COUNTDOWN stamped in the same desk-minute as a
                // move that began 23:28:42Z), so when the interval-based prediction agrees
                // with it to within a couple of minutes, keep that - it can be anchored on a
                // live-observed move and be good to the second. The announcement only takes
                // over when the interval prediction is clearly wrong, e.g. after an absence.
                let announced = NextMove(at: pending.date.addingTimeInterval(moveLeadSeconds), toStanding: pending.toStanding)
                if let fromInterval, fromInterval.toStanding == announced.toStanding,
                   abs(fromInterval.at.timeIntervalSince(announced.at)) < 120 {
                    nextMove = fromInterval
                } else {
                    nextMove = announced
                }
            } else if let lastMove, fromInterval != nil {
                // The desk holds its timer while it doesn't see you, so the plain interval
                // runs early by the absences since the move (each dated from when the user
                // left, `absenceLogLagSeconds` before its entry). Short pauses it never logs
                // can still leave the estimate early, and the lag, fitted, can leave it a few
                // minutes late; either way the desk's own COUNTDOWN entry takes over the
                // moment it beeps.
                // Field data 2026-09-04: a manual sit at 18:27 while absent, back at 18:53, no
                // stand by 19:28 - consistent with a 26 min hold; 2026-09-11 above.
                let wait = lastMove.toStanding ? cruise.standingSeconds : cruise.sittingSeconds
                nextMove = NextMove(at: lastMove.date.addingTimeInterval(Double(wait) + absentSinceMove + moveLeadSeconds),
                                    toStanding: !lastMove.toStanding)
            }
        }
        return TodayStats(atDeskSeconds: atDesk, stands: stands, isStanding: isStanding,
                          isPresent: present, nextMove: nextMove)
    }
}

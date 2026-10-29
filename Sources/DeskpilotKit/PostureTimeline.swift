import Foundation

public enum PostureState: String, Codable, Sendable, CaseIterable {
    case standing, sitting, away
}

public struct PostureSegment: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let state: PostureState

    public init(start: Date, end: Date, state: PostureState) {
        self.start = start
        self.end = end
        self.state = state
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct DayTotals: Codable, Equatable, Sendable {
    /// Start of the day (e.g. from `DayRollup.dayStart`).
    public let day: Date
    public let standing: TimeInterval
    public let sitting: TimeInterval
    public let away: TimeInterval
    public let stands: Int

    public init(day: Date, standing: TimeInterval, sitting: TimeInterval, away: TimeInterval, stands: Int) {
        self.day = day
        self.standing = standing
        self.sitting = sitting
        self.away = away
        self.stands = stands
    }
}

public enum PostureTimeline {
    /// A `MOVE` entry within this many seconds of an immediately preceding `HEIGHT` entry is
    /// treated as stamped the same minute. Mirrors `DayRollup.heightMoveWindow`.
    private static let heightMoveWindow: TimeInterval = 90

    /// A posture/presence state change effective starting at `date`.
    private struct Breakpoint {
        let date: Date
        let state: PostureState
    }

    /// A resolved `MOVE` event (raise bit corrected by `standingThresholdInches`, like DayRollup).
    private struct ResolvedMove {
        let date: Date
        let toStanding: Bool
    }

    private struct Walk {
        let breakpoints: [Breakpoint]
        let moves: [ResolvedMove]
    }

    /// The single state machine shared by `segments` and `totals`, so their notions of
    /// presence/posture cannot drift apart. Mirrors DayRollup's per-event handling exactly:
    /// `presence(false)` -> away, `presence(true)`/`countdown`/`move` -> present, a move's
    /// resulting posture is derived from an immediately preceding `heightChange` (within
    /// `heightMoveWindow`) when `standingThresholdInches` is given, and posture while present
    /// with no move yet is unknown -> sitting.
    private static func walk(events: [HistoryEvent], standingThresholdInches: Int?) -> Walk {
        var present = false
        var isStanding: Bool?
        var breakpoints: [Breakpoint] = []
        var moves: [ResolvedMove] = []

        func currentState() -> PostureState {
            guard present else { return .away }
            return isStanding == true ? .standing : .sitting
        }

        for (index, event) in events.enumerated() {
            switch event.kind {
            case .presence(let p):
                present = p
                breakpoints.append(Breakpoint(date: event.date, state: currentState()))
            case .countdown:
                present = true
                breakpoints.append(Breakpoint(date: event.date, state: currentState()))
            case .move(let raiseBit):
                present = true
                var toStanding = raiseBit
                if let threshold = standingThresholdInches, index > 0,
                   case .heightChange(let inches) = events[index - 1].kind,
                   abs(event.date.timeIntervalSince(events[index - 1].date)) <= heightMoveWindow {
                    toStanding = inches >= threshold
                }
                isStanding = toStanding
                moves.append(ResolvedMove(date: event.date, toStanding: toStanding))
                breakpoints.append(Breakpoint(date: event.date, state: currentState()))
            case .heightChange, .userChange, .nop:
                break
            }
        }
        return Walk(breakpoints: breakpoints, moves: moves)
    }

    /// Turns a chronological breakpoint list into contiguous segments covering [from, to),
    /// clipping breakpoints outside the window and merging adjacent equal states.
    private static func clippedSegments(_ breakpoints: [Breakpoint], from: Date, to: Date) -> [PostureSegment] {
        guard to > from else { return [] }
        var segments: [PostureSegment] = []
        var state: PostureState = .away
        var segmentStart = from
        for point in breakpoints {
            guard point.date < to else { break }
            guard point.state != state else { continue }
            let clippedDate = min(max(point.date, from), to)
            if clippedDate > segmentStart {
                segments.append(PostureSegment(start: segmentStart, end: clippedDate, state: state))
            }
            state = point.state
            segmentStart = clippedDate
        }
        if to > segmentStart {
            segments.append(PostureSegment(start: segmentStart, end: to, state: state))
        }
        return segments
    }

    /// Same "genuine sitting->standing transition" rule DayRollup uses for `stands`, scoped to
    /// one day: seeded once from the last resolved move before `dayStart` (the posture the desk
    /// carried across the day boundary), then incremented only when a move within
    /// [dayStart, dayEnd) actually rises from a non-standing seed.
    private static func stands(_ moves: [ResolvedMove], dayStart: Date, dayEnd: Date) -> Int {
        var seed: Bool?
        var count = 0
        for move in moves {
            if move.date < dayStart { seed = move.toStanding; continue }
            guard move.date < dayEnd else { break }
            if move.toStanding, seed != true { count += 1 }
            seed = move.toStanding
        }
        return count
    }

    /// Builds contiguous segments covering [from, to] from chronological events, using the same
    /// rules as DayRollup. While away the state is `.away` regardless of posture. Segments
    /// shorter than 0 are dropped; adjacent equal states are merged.
    public static func segments(events: [HistoryEvent], from: Date, to: Date,
                                standingThresholdInches: Int?) -> [PostureSegment] {
        clippedSegments(walk(events: events, standingThresholdInches: standingThresholdInches).breakpoints,
                        from: from, to: to)
    }

    /// Totals per calendar day for the given day starts: sum of segment durations clipped to
    /// [dayStart, nextDayStart) - itself clipped to `now`, so a day that hasn't finished yet
    /// only totals what's happened so far - plus the stand count (transitions sitting->standing,
    /// same rule as DayRollup).
    ///
    /// A day's end is `calendar`'s own next-day boundary rather than a fixed 86 400 s: across a
    /// daylight-saving change the fixed length runs an hour past (or short of) the boundary, and
    /// would leak an hour of the neighbouring day into the totals twice a year.
    public static func totals(events: [HistoryEvent], dayStarts: [Date],
                              standingThresholdInches: Int?, now: Date,
                              calendar: Calendar = .current) -> [DayTotals] {
        let walked = walk(events: events, standingThresholdInches: standingThresholdInches)
        return dayStarts.map { dayStart in
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
                ?? dayStart.addingTimeInterval(86_400)
            let segs = clippedSegments(walked.breakpoints, from: dayStart, to: min(dayEnd, now))
            var standing: TimeInterval = 0
            var sitting: TimeInterval = 0
            var away: TimeInterval = 0
            for seg in segs {
                switch seg.state {
                case .standing: standing += seg.duration
                case .sitting: sitting += seg.duration
                case .away: away += seg.duration
                }
            }
            let standCount = stands(walked.moves, dayStart: dayStart, dayEnd: dayEnd)
            return DayTotals(day: dayStart, standing: standing, sitting: sitting, away: away, stands: standCount)
        }
    }
}

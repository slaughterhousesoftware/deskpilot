import Foundation

// `HistoryEvent`/`HistoryEventKind` are declared in HistoryDecoder.swift. Their
// `Codable` conformance is added here instead; synthesis cannot
// reach across files for an enum with associated values, so it's written out by hand.
extension HistoryEventKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, present, toStanding, inches, user, raw
    }

    private enum Kind: String, Codable {
        case presence, countdown, move, heightChange, userChange, nop
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .presence:
            self = .presence(present: try container.decode(Bool.self, forKey: .present))
        case .countdown:
            self = .countdown(toStanding: try container.decode(Bool.self, forKey: .toStanding))
        case .move:
            self = .move(toStanding: try container.decode(Bool.self, forKey: .toStanding))
        case .heightChange:
            self = .heightChange(inches: try container.decode(Int.self, forKey: .inches))
        case .userChange:
            self = .userChange(user: try container.decode(Int.self, forKey: .user))
        case .nop:
            self = .nop(raw: try container.decode(UInt8.self, forKey: .raw))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .presence(let present):
            try container.encode(Kind.presence, forKey: .type)
            try container.encode(present, forKey: .present)
        case .countdown(let toStanding):
            try container.encode(Kind.countdown, forKey: .type)
            try container.encode(toStanding, forKey: .toStanding)
        case .move(let toStanding):
            try container.encode(Kind.move, forKey: .type)
            try container.encode(toStanding, forKey: .toStanding)
        case .heightChange(let inches):
            try container.encode(Kind.heightChange, forKey: .type)
            try container.encode(inches, forKey: .inches)
        case .userChange(let user):
            try container.encode(Kind.userChange, forKey: .type)
            try container.encode(user, forKey: .user)
        case .nop(let raw):
            try container.encode(Kind.nop, forKey: .type)
            try container.encode(raw, forKey: .raw)
        }
    }
}

extension HistoryEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case byteOffset, date, kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(byteOffset: try container.decode(Int.self, forKey: .byteOffset),
                  date: try container.decode(Date.self, forKey: .date),
                  kind: try container.decode(HistoryEventKind.self, forKey: .kind))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(byteOffset, forKey: .byteOffset)
        try container.encode(date, forKey: .date)
        try container.encode(kind, forKey: .kind)
    }
}

/// The dated history the menu bar app (the only BLE client) writes to the App Group for the
/// dashboard app to read.
public struct HistoryDocument: Codable, Equatable, Sendable {
    public var writtenAt: Date
    public var standingThresholdInches: Int?
    public var middleOfNightHour: Int
    public var events: [HistoryEvent]

    public init(writtenAt: Date, standingThresholdInches: Int?, middleOfNightHour: Int, events: [HistoryEvent]) {
        self.writtenAt = writtenAt
        self.standingThresholdInches = standingThresholdInches
        self.middleOfNightHour = middleOfNightHour
        self.events = events
    }
}

public struct HistoryStore: Sendable {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("history.json")
    }

    /// Uses the App Group container; falls back to Application Support if unavailable.
    public init(appGroup: String = SnapshotStore.appGroup) {
        let fm = FileManager.default
        let dir = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Tempo")
        self.init(directory: dir)
    }

    public func write(_ doc: HistoryDocument) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(doc)
        try data.write(to: fileURL, options: .atomic)
    }

    /// A desk log is a bounded view of one boot session, not the user's archive.
    /// Keep the older prefix and replace the overlapping window with the current log.
    public static func merging(saved: HistoryDocument?, incoming: HistoryDocument) -> HistoryDocument {
        guard let saved else { return incoming }
        guard let first = incoming.events.map(\.date).min() else { return saved }
        // Reconnecting can shift the log's wall-clock anchor by seconds. Recognize the
        // first entry so the previous copy doesn't survive as a duplicate at the seam.
        let matching = saved.events.first {
            $0.byteOffset == incoming.events.first?.byteOffset
                && $0.kind == incoming.events.first?.kind
                && abs($0.date.timeIntervalSince(first)) < 60
        }
        let cutoff = min(first, matching?.date ?? first)
        var events = saved.events.filter { $0.date < cutoff }
        // Don't extend the last known presence across an unobserved power-off gap.
        if saved.writtenAt < first, let last = events.last, last.date <= saved.writtenAt {
            events.append(HistoryEvent(byteOffset: -1, date: saved.writtenAt,
                                       kind: .presence(present: false)))
        }
        events.append(contentsOf: incoming.events)
        var result = incoming
        result.events = events.sorted { $0.date < $1.date }
        return result
    }

    /// Archive-aware sync, with an immutable daily copy of the previous file.
    /// A malformed existing file must never be silently overwritten.
    public func mergeAndWrite(_ incoming: HistoryDocument) throws {
        var saved: HistoryDocument?
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            saved = try decoder.decode(HistoryDocument.self, from: data)
            let directory = fileURL.deletingLastPathComponent().appendingPathComponent("history-backups")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let day = String(ISO8601DateFormatter().string(from: incoming.writtenAt).prefix(10))
            let backup = directory.appendingPathComponent("history-\(day).json")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try data.write(to: backup, options: .withoutOverwriting)
            }
        }
        try write(Self.merging(saved: saved, incoming: incoming))
    }

    public func read() -> HistoryDocument? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HistoryDocument.self, from: data)
    }
}

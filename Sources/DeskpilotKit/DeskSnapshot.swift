import Foundation

/// What the widget needs, written by the app after every state change.
public struct DeskSnapshot: Codable, Equatable, Sendable {
    public var updatedAt: Date
    public var connected: Bool
    public var heightTenths: Int?
    public var isMoving: Bool
    public var isPresent: Bool
    public var isStanding: Bool?
    public var atDeskSeconds: TimeInterval
    public var standsToday: Int
    public var nextMove: NextMove?
    public var paused: Bool
    public var cruise: CruiseSlot?
    public var sittingHeightTenths: Int?
    public var standingHeightTenths: Int?

    public init(updatedAt: Date, connected: Bool, heightTenths: Int?, isMoving: Bool,
                isPresent: Bool, isStanding: Bool?, atDeskSeconds: TimeInterval, standsToday: Int,
                nextMove: NextMove?, paused: Bool, cruise: CruiseSlot?,
                sittingHeightTenths: Int?, standingHeightTenths: Int?) {
        self.updatedAt = updatedAt
        self.connected = connected
        self.heightTenths = heightTenths
        self.isMoving = isMoving
        self.isPresent = isPresent
        self.isStanding = isStanding
        self.atDeskSeconds = atDeskSeconds
        self.standsToday = standsToday
        self.nextMove = nextMove
        self.paused = paused
        self.cruise = cruise
        self.sittingHeightTenths = sittingHeightTenths
        self.standingHeightTenths = standingHeightTenths
    }

    /// The widget treats snapshots older than this as stale.
    public static let staleAfter: TimeInterval = 120
}

public struct SnapshotStore: Sendable {
    public static let appGroup = "LQV43S38FV.com.kevinpatel.tempo"
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("snapshot.json")
    }

    /// Uses the App Group container; falls back to Application Support if unavailable.
    public init(appGroup: String = SnapshotStore.appGroup) {
        let fm = FileManager.default
        let dir = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Tempo")
        self.init(directory: dir)
    }

    public func write(_ snapshot: DeskSnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    public func read() -> DeskSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DeskSnapshot.self, from: data)
    }
}

import Foundation

/// Where `TempoDesk` keeps the moves it saw happen live, so a restart of the app doesn't
/// throw away the only second-accurate timestamps it has. The desk's log stamps events to the
/// minute; a countdown anchored on a logged move can be off by up to a minute, one anchored
/// on an observed move is good to a second.
public protocol ObservedMoveStore: Sendable {
    func load() -> [HistoryEvent]
    func save(_ moves: [HistoryEvent])
}

/// `ObservedMoveStore` as a JSON file next to the snapshot and history in the App Group.
public struct ObservedMoveFile: ObservedMoveStore {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("observed-moves.json")
    }

    /// Uses the App Group container; falls back to Application Support if unavailable.
    public init(appGroup: String = SnapshotStore.appGroup) {
        let fm = FileManager.default
        let dir = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Tempo")
        self.init(directory: dir)
    }

    public func load() -> [HistoryEvent] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEvent].self, from: data)) ?? []
    }

    public func save(_ moves: [HistoryEvent]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(moves) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

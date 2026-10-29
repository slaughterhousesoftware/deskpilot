import Foundation

/// A command the dashboard queues for the menu bar app (the only BLE client) to execute.
public enum DeskCommand: Codable, Equatable, Sendable {
    case captureSittingPreset
    case captureStandingPreset
    case setCruise(CruiseSlot?)
    case setPaused(Bool)
    /// Drop the Bluetooth connection and connect again (Siri's "Reconnect Deskpilot").
    case reconnect
}

public struct CommandEnvelope: Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let command: DeskCommand

    public init(id: UUID, createdAt: Date, command: DeskCommand) {
        self.id = id
        self.createdAt = createdAt
        self.command = command
    }
}

public struct CommandResult: Codable, Equatable, Sendable {
    public let id: UUID
    public let completedAt: Date
    public let success: Bool
    public let message: String?

    public init(id: UUID, completedAt: Date, success: Bool, message: String?) {
        self.id = id
        self.completedAt = completedAt
        self.success = success
        self.message = message
    }
}

/// A simple file-backed queue in the App Group: the dashboard enqueues commands as
/// `commands/<id>.json`; the menu bar app polls `pending()`, executes each command against the
/// desk, and calls `complete` - which removes the command file and writes `results/<id>.json`
/// so the dashboard can find out what happened.
public struct CommandQueue: Sendable {
    /// A `DistributedNotificationCenter` name the dashboard posts after enqueuing, so the menu
    /// bar app can react immediately instead of waiting for its ~2 s fallback poll. Posting and
    /// observing it are not implemented here.
    public static let wakeNotificationName = "com.kevinpatel.tempo.commands"

    private let commandsDirectory: URL
    private let resultsDirectory: URL

    public init(directory: URL) {
        commandsDirectory = directory.appendingPathComponent("commands")
        resultsDirectory = directory.appendingPathComponent("results")
    }

    /// Uses the App Group container; falls back to Application Support if unavailable.
    public init(appGroup: String = SnapshotStore.appGroup) {
        let fm = FileManager.default
        let dir = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Tempo")
        self.init(directory: dir)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func fileURL(in directory: URL, id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// The file one queued command lives in. Internal rather than private so a test can age an
    /// envelope in place; nothing outside the module needs it.
    func commandFileURL(for id: UUID) -> URL { fileURL(in: commandsDirectory, id: id) }

    public func enqueue(_ command: DeskCommand) throws -> UUID {
        try FileManager.default.createDirectory(at: commandsDirectory, withIntermediateDirectories: true)
        let id = UUID()
        let envelope = CommandEnvelope(id: id, createdAt: Date(), command: command)
        let data = try Self.makeEncoder().encode(envelope)
        try data.write(to: fileURL(in: commandsDirectory, id: id), options: .atomic)
        return id
    }

    /// How long a queued command stays worth executing. The dashboard gives up waiting after
    /// 15 s and cancels, but a command written while the menu bar app was not running would
    /// otherwise sit here and be applied - moving the desk or changing its rhythm - whenever
    /// the app next started, long after the user had stopped expecting it.
    public static let staleAfter: TimeInterval = 300

    /// Pending commands, oldest first. Envelopes older than `staleAfter` are deleted rather
    /// than returned, so a stale command is dropped exactly once by whoever polls next.
    public func pending() -> [CommandEnvelope] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: commandsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = Self.makeDecoder()
        let cutoff = Date().addingTimeInterval(-Self.staleAfter)
        let envelopes = files.compactMap { url -> CommandEnvelope? in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
                  let envelope = try? decoder.decode(CommandEnvelope.self, from: data) else { return nil }
            guard envelope.createdAt >= cutoff else {
                try? fm.removeItem(at: url)
                return nil
            }
            return envelope
        }
        return envelopes.sorted { $0.createdAt < $1.createdAt }
    }

    /// Withdraws a command that hasn't been executed yet. Called by the dashboard when it stops
    /// waiting for a result, so a command the user has already been told failed can't be picked
    /// up and applied afterwards. A no-op when the command is gone - already executed, already
    /// cancelled, or never there.
    public func cancel(id: UUID) throws {
        let url = fileURL(in: commandsDirectory, id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func complete(_ id: UUID, success: Bool, message: String?) throws {
        try FileManager.default.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
        let result = CommandResult(id: id, completedAt: Date(), success: success, message: message)
        let data = try Self.makeEncoder().encode(result)
        try data.write(to: fileURL(in: resultsDirectory, id: id), options: .atomic)
        try? FileManager.default.removeItem(at: fileURL(in: commandsDirectory, id: id))
    }

    /// Enqueues `command`, wakes the menu bar app, and waits for its result: what the
    /// dashboard and the app intents both do. `nil` means nobody answered within `timeout` -
    /// the command is withdrawn first (see `cancel`), so it can't be applied after the caller
    /// has reported that it wasn't. Cancelling the calling task also withdraws it.
    public func send(_ command: DeskCommand, timeout: TimeInterval = 15,
                     pollEvery: TimeInterval = 0.5) async -> CommandResult? {
        guard let id = try? enqueue(command) else { return nil }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(Self.wakeNotificationName), object: nil, userInfo: nil, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
            if let result = result(for: id) { return result }
        }
        try? cancel(id: id)
        purge(olderThan: 3600)
        return nil
    }

    public func result(for id: UUID) -> CommandResult? {
        guard let data = try? Data(contentsOf: fileURL(in: resultsDirectory, id: id)) else { return nil }
        return try? Self.makeDecoder().decode(CommandResult.self, from: data)
    }

    /// Deletes results whose `completedAt` is older than `olderThan` seconds ago.
    public func purge(olderThan: TimeInterval) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: resultsDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-olderThan)
        let decoder = Self.makeDecoder()
        for url in files {
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
                  let result = try? decoder.decode(CommandResult.self, from: data) else { continue }
            if result.completedAt < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}

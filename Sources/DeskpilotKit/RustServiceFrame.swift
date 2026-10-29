import Foundation

/// Versioned UI stream from the Rust service. Swift owns presentation only.
public struct RustServiceFrame: Decodable, Sendable {
    public let protocolVersion: Int
    public let state: RustDeskState
    public let snapshot: DeskSnapshot
    public let savedToday: TodayStats?
    public let todaySegments: [PostureSegment]
    public let lastSyncedAt: Date?

    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let frame = try decoder.decode(Self.self, from: data)
        guard frame.protocolVersion == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported Deskpilot backend protocol"))
        }
        return frame
    }
}

public struct RustDeskState: Decodable, Sendable {
    public let status: String
    public let reconnectingInBackground: Bool
    public let heightTenths: Int?
    public let isMoving: Bool
    public let predictedHeightTenths: Int?
    public let settings: DeskSettings?
    public let today: TodayStats?
    public let lastError: String?
    public let updatedAt: Date?
    public let historyRevision: Int

    public var deskState: DeskState {
        var state = DeskState()
        switch status {
        case "connected": state.status = .connected
        case "connecting": state.status = .connecting
        case "bluetoothOff": state.status = .bluetoothOff
        case "unauthorized": state.status = .unauthorized
        default: state.status = .disconnected
        }
        state.reconnectingInBackground = reconnectingInBackground
        state.heightTenths = heightTenths
        state.isMoving = isMoving
        state.predictedHeightTenths = predictedHeightTenths
        state.settings = settings
        state.today = today
        state.lastError = lastError
        state.updatedAt = updatedAt ?? .distantPast
        state.historyRevision = historyRevision
        return state
    }
}

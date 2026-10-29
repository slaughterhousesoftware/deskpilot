import Foundation

public enum DeskError: Error, Equatable, Sendable {
    case notConnected
    /// The local Bluetooth radio is switched off.
    case bluetoothOff
    /// The user denied this app Bluetooth access.
    case unauthorized
    /// Bluetooth is unusable for some other reason (e.g. unsupported hardware).
    case bluetoothUnavailable(String)
    case timeout(String)
    case gatt(String)
    case forbiddenAddress(UInt32)
    case invalidValue(String)
    case burstIncomplete(expected: Int, got: Int)
}

extension DeskError: LocalizedError {
    /// User-facing text for `lastActionError`/command-result messages (`error.localizedDescription`
    /// picks this up automatically once the error conforms to `LocalizedError`). `.invalidValue`
    /// carries a message from the throw site; the two known internal ones get a friendlier
    /// rewrite here, and anything else - like the height-mismatch message from `capturePreset`,
    /// already written for a person to read - passes through unchanged.
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the desk."
        case .bluetoothOff: return "Bluetooth is turned off."
        case .unauthorized: return "Bluetooth access was denied."
        case .bluetoothUnavailable: return "Bluetooth isn't available on this Mac."
        // The scan is the one timeout that means "never heard from it at all".
        case .timeout("scan"): return "Couldn't find the desk. Is it on and in range?"
        case .timeout: return "The desk didn't answer in time."
        case .gatt: return "Lost contact with the desk. Try again."
        case .forbiddenAddress: return "That change isn't allowed: it could put the desk into update mode."
        case .burstIncomplete: return "The desk sent an incomplete response. Try again."
        case .invalidValue(let message):
            switch message {
            case "desk is moving": return "The desk is moving; try again once it stops."
            case "desk is still settling": return "The desk is still settling; try again in a moment."
            case "cruise timing must be positive": return "Standing and sitting times must both be greater than zero."
            default: return message
            }
        }
    }
}

public enum ConnectionEvent: Equatable, Sendable {
    case connecting
    case connected
    case disconnected(reason: String?)
    case bluetoothOff
    case unauthorized
}

/// Raw access to the desk. Implementations must serialise calls; the desk has one
/// shared address pointer and interleaved reads return the wrong register.
public protocol DeskTransport: AnyObject, Sendable {
    /// Connection lifecycle. Single consumer (TempoDesk).
    var events: AsyncStream<ConnectionEvent> { get }
    func connect() async throws
    func disconnect() async
    func readRegister(_ address: UInt32) async throws -> UInt32
    func writeRegister(_ address: UInt32, value: UInt32) async throws
    /// Reads `chunks` consecutive 20-byte chunks starting at `byteAddress`.
    func burstRead(byteAddress: UInt32, chunks: Int) async throws -> Data
    /// Writes up to 20 bytes at `byteAddress`.
    func burstWrite(byteAddress: UInt32, data: Data) async throws
}

public extension Data {
    var uint32LE: UInt32? {
        guard count >= 4 else { return nil }
        return withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }
    init(uint32LE value: UInt32) {
        var v = value.littleEndian
        self = Swift.withUnsafeBytes(of: &v) { Data($0) }
    }
}

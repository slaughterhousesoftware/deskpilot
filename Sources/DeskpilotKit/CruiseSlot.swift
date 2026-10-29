import Foundation

/// One cruise-control timing slot: `(standingSeconds << 16) | sittingSeconds`.
public struct CruiseSlot: Equatable, Sendable, Codable {
    public var standingSeconds: Int
    public var sittingSeconds: Int

    public init(standingSeconds: Int, sittingSeconds: Int) {
        self.standingSeconds = standingSeconds
        self.sittingSeconds = sittingSeconds
    }

    public init(raw: UInt32) {
        standingSeconds = Int(raw >> 16)
        sittingSeconds = Int(raw & 0xFFFF)
    }

    public var raw: UInt32 {
        UInt32(standingSeconds & 0xFFFF) << 16 | UInt32(sittingSeconds & 0xFFFF)
    }

    public var cycleSeconds: Int { standingSeconds + sittingSeconds }

    public var standingMinutesPerHour: Int {
        cycleSeconds == 0 ? 0 : Int((Double(standingSeconds) * 60 / Double(cycleSeconds)).rounded())
    }

    public enum ValidationError: Error, Equatable {
        case standingOutOfRange
        case cycleOutOfRange
        case standingNotShorterThanCycle
    }

    /// Mirrors the phone app: minutes in, seconds out, standing must be shorter than the cycle.
    public static func make(standingMinutes: Int, cycleMinutes: Int) throws -> CruiseSlot {
        guard (1...240).contains(standingMinutes) else { throw ValidationError.standingOutOfRange }
        guard (2...240).contains(cycleMinutes) else { throw ValidationError.cycleOutOfRange }
        guard standingMinutes < cycleMinutes else { throw ValidationError.standingNotShorterThanCycle }
        return CruiseSlot(standingSeconds: standingMinutes * 60,
                          sittingSeconds: (cycleMinutes - standingMinutes) * 60)
    }

    /// The phone app's "minutes standing per hour" choices.
    public static let presets: [CruiseSlot] = [5, 10, 15, 20, 22, 30, 40].map {
        CruiseSlot(standingSeconds: $0 * 60, sittingSeconds: (60 - $0) * 60)
    }
}

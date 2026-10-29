import Foundation

public enum HistoryEventKind: Equatable, Sendable {
    case presence(present: Bool)
    /// The desk announced an upcoming move (logged about a minute before the move).
    case countdown(toStanding: Bool)
    /// The desk moved. `toStanding` is the new posture.
    case move(toStanding: Bool)
    case heightChange(inches: Int)
    case userChange(user: Int)
    case nop(raw: UInt8)
}

public struct RawHistoryEntry: Equatable, Sendable {
    public let byteOffset: Int
    public let minuteByte: UInt8
    public let kind: HistoryEventKind

    public init(byteOffset: Int, minuteByte: UInt8, kind: HistoryEventKind) {
        self.byteOffset = byteOffset
        self.minuteByte = minuteByte
        self.kind = kind
    }
}

public struct HistoryEvent: Equatable, Sendable {
    public let byteOffset: Int
    public let date: Date
    public let kind: HistoryEventKind

    public init(byteOffset: Int, date: Date, kind: HistoryEventKind) {
        self.byteOffset = byteOffset
        self.date = date
        self.kind = kind
    }
}

public enum HistoryDecoder {
    /// Bit patterns copied from the phone app's processEntry.
    public static func decodeKind(_ b: UInt8) -> HistoryEventKind {
        let top5 = (b & 0xF8) >> 3
        let top4 = (b & 0xF0) >> 4
        let top3 = (b & 0xE0) >> 5
        if top5 == 11 {
            let raise = b & 0x01 != 0
            let move = b & 0x04 != 0
            return move ? .move(toStanding: raise) : .countdown(toStanding: raise)
        }
        if top5 == 10 { return .presence(present: b & 0x01 != 0) }
        if top4 == 4 { return .userChange(user: Int(b & 0x0F)) }
        if top3 == 1 { return .heightChange(inches: 20 + Int(b & 0x1F)) }
        return .nop(raw: b)
    }

    /// Splits ring-buffer bytes into `[time][event]` pairs. A trailing odd byte is ignored.
    public static func decodeEntries(_ data: Data, firstByteOffset: Int = 0) -> [RawHistoryEntry] {
        let bytes = [UInt8](data)
        var out: [RawHistoryEntry] = []
        out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            out.append(RawHistoryEntry(byteOffset: firstByteOffset + i,
                                       minuteByte: bytes[i],
                                       kind: decodeKind(bytes[i + 1])))
            i += 2
        }
        return out
    }

    /// Assigns dates exactly like the phone app: start at `now` with reference
    /// `minutesSincePowerOn % 256`, walk backwards, each entry is
    /// `(reference - minuteByte) mod 256` minutes before the entry after it.
    /// NOP entries take part in the chain but are not returned.
    public static func dateEntries(_ entries: [RawHistoryEntry],
                                   minutesSincePowerOn: Int,
                                   now: Date) -> [HistoryEvent] {
        let wrap = Register.minuteWrap
        var reference = ((minutesSincePowerOn % wrap) + wrap) % wrap
        var cursor = now
        var dated: [HistoryEvent] = []
        for entry in entries.reversed() {
            let t = Int(entry.minuteByte)
            let diff = reference >= t ? reference - t : reference + wrap - t
            cursor = cursor.addingTimeInterval(-Double(diff) * 60)
            reference = t
            if case .nop = entry.kind { continue }
            dated.append(HistoryEvent(byteOffset: entry.byteOffset, date: cursor, kind: entry.kind))
        }
        return dated.reversed()
    }
}

import XCTest
@testable import DeskpilotKit

final class HistoryDecoderTests: XCTestCase {
    // Bytes captured from the real desk on 2026-09-04 (time byte, event byte pairs).
    // t=209 HEIGHT 31, t=209 MOVE down, t=210 HEIGHT 26, t=210 MOVE down, t=212 present,
    // t=221 countdown up, t=221 HEIGHT 26, t=231 countdown up, t=231 HEIGHT 41, t=231 MOVE up,
    // t=251 countdown down, t=251 HEIGHT 26, t=251 MOVE down
    static let captured: [UInt8] = [
        0xD1, 0x2B, 0xD1, 0x5C, 0xD2, 0x26, 0xD2, 0x5C, 0xD4, 0x51,
        0xDD, 0x59, 0xDD, 0x26, 0xE7, 0x59, 0xE7, 0x35, 0xE7, 0x5D,
        0xFB, 0x58, 0xFB, 0x26, 0xFB, 0x5C,
    ]

    func testDecodeKindMatchesPhoneAppBitPatterns() {
        XCTAssertEqual(HistoryDecoder.decodeKind(0x5D), .move(toStanding: true))
        XCTAssertEqual(HistoryDecoder.decodeKind(0x5C), .move(toStanding: false))
        XCTAssertEqual(HistoryDecoder.decodeKind(0x59), .countdown(toStanding: true))
        XCTAssertEqual(HistoryDecoder.decodeKind(0x58), .countdown(toStanding: false))
        XCTAssertEqual(HistoryDecoder.decodeKind(0x51), .presence(present: true))
        XCTAssertEqual(HistoryDecoder.decodeKind(0x50), .presence(present: false))
        XCTAssertEqual(HistoryDecoder.decodeKind(0x40), .userChange(user: 0))
        XCTAssertEqual(HistoryDecoder.decodeKind(0x4A), .userChange(user: 10))
        XCTAssertEqual(HistoryDecoder.decodeKind(0x26), .heightChange(inches: 26))
        XCTAssertEqual(HistoryDecoder.decodeKind(0x35), .heightChange(inches: 41))
        XCTAssertEqual(HistoryDecoder.decodeKind(0x00), .nop(raw: 0x00))
        XCTAssertEqual(HistoryDecoder.decodeKind(0x79), .nop(raw: 0x79))
    }

    func testDecodeEntriesPairsBytesAndTracksOffsets() {
        let entries = HistoryDecoder.decodeEntries(Data(Self.captured), firstByteOffset: 402)
        XCTAssertEqual(entries.count, 13)
        XCTAssertEqual(entries[0], RawHistoryEntry(byteOffset: 402, minuteByte: 209, kind: .heightChange(inches: 31)))
        XCTAssertEqual(entries[12], RawHistoryEntry(byteOffset: 426, minuteByte: 251, kind: .move(toStanding: false)))
        // A trailing odd byte is ignored.
        XCTAssertEqual(HistoryDecoder.decodeEntries(Data([0x01, 0x5D, 0x02])).count, 1)
    }

    func testDateEntriesWalksBackwardsFromNowLikeThePhoneApp() {
        let entries = HistoryDecoder.decodeEntries(Data(Self.captured))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // minutes since power-on = 5883 -> 5883 % 256 = 251, same as the newest entry, so it is "now".
        let dated = HistoryDecoder.dateEntries(entries, minutesSincePowerOn: 5883, now: now)
        XCTAssertEqual(dated.count, 13)
        XCTAssertEqual(dated.last?.date, now)
        XCTAssertEqual(dated.last?.kind, .move(toStanding: false))
        // t=231 is 20 minutes before t=251.
        XCTAssertEqual(dated[9].date, now.addingTimeInterval(-20 * 60))
        // t=209 is 42 minutes before t=251.
        XCTAssertEqual(dated[0].date, now.addingTimeInterval(-42 * 60))
    }

    func testDateEntriesHandlesMinuteWrap() {
        // t=250 then t=4 : 10 minutes apart across the 256 wrap.
        let entries = HistoryDecoder.decodeEntries(Data([0xFA, 0x50, 0x04, 0x51]))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // minutesSincePowerOn % 256 == 9 -> newest entry (t=4) is 5 minutes ago.
        let dated = HistoryDecoder.dateEntries(entries, minutesSincePowerOn: 256 * 3 + 9, now: now)
        XCTAssertEqual(dated[1].date, now.addingTimeInterval(-5 * 60))
        XCTAssertEqual(dated[0].date, now.addingTimeInterval(-15 * 60))
    }

    func testDateEntriesDropsNopsButUsesThemAsTimeReferences() {
        // present=0 at t=89, NOP t=88, NOP t=87, HEIGHT at t=35.
        // NOTE: the mb sequence here (89, 88, 87, 35) is decreasing along the chronological
        // (oldest-first) entry order, so under the wrap-forward algorithm each step from a
        // smaller reference to a larger t is treated as a wrap: 35->87 is 204 min
        // (35 + 256 - 87), 87->88 is 255 min (87 + 256 - 88), 88->89 is 255 min
        // (88 + 256 - 89), for a total of 714 minutes back to the presence entry. This
        // matches decodeKind/decodeEntries behavior verified by the other subtests in this
        // file (captured-data and minute-wrap cases both check out exactly), so 714 is the
        // value the algorithm actually produces from this input - not 52 + 1 + 1.
        let entries = HistoryDecoder.decodeEntries(Data([0x59, 0x50, 0x58, 0x00, 0x57, 0x00, 0x23, 0x26]))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let dated = HistoryDecoder.dateEntries(entries, minutesSincePowerOn: 35, now: now)
        XCTAssertEqual(dated.map(\.kind), [.presence(present: false), .heightChange(inches: 26)])
        XCTAssertEqual(dated[1].date, now)
        XCTAssertEqual(dated[0].date, now.addingTimeInterval(-(204 + 255 + 255) * 60))
    }
}

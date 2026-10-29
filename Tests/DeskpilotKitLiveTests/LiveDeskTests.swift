import XCTest
@testable import DeskpilotKit

/// Talks to the real desk. Run with: DESKPILOT_LIVE=1 swift test --filter LiveDeskTests
final class LiveDeskTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DESKPILOT_LIVE"] == "1", "set DESKPILOT_LIVE=1")
    }

    func testReadsFirmwareStatusAndHistory() async throws {
        let transport = CoreBluetoothTransport(defaults: UserDefaults(suiteName: "tempo.live.tests")!)
        try await transport.connect()

        let fw = FirmwareVersion(raw: try await transport.readRegister(Register.firmwareApplication))
        XCTAssertEqual(fw.major, 1)
        let status = StatusWord(raw: try await transport.readRegister(Register.status))
        XCTAssertTrue((200...500).contains(status.heightTenths), "height \(status.heightTenths)")

        let pointer = Int(try await transport.readRegister(Register.historyWritePointer))
        XCTAssertGreaterThan(pointer, 0)
        let first = try await transport.burstRead(byteAddress: Register.historyBase, chunks: 2)
        XCTAssertEqual(first.count, 40)
        let second = try await transport.burstRead(byteAddress: Register.historyBase + 20, chunks: 1)
        XCTAssertEqual(second, first.subdata(in: 20..<40), "consecutive bursts must line up")

        let minutes = Int(try await transport.readRegister(Register.minutesSincePowerOn))
        let entries = HistoryDecoder.decodeEntries(first)
        let dated = HistoryDecoder.dateEntries(entries, minutesSincePowerOn: minutes, now: Date())
        XCTAssertFalse(dated.isEmpty)

        // Disconnect for real (not fire-and-forget) and give the desk a moment to
        // notice, so the next test isn't racing this one for the desk's single
        // central slot.
        await transport.disconnect()
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    func testTempoDeskEndToEnd() async throws {
        let desk = TempoDesk(transport: CoreBluetoothTransport(defaults: UserDefaults(suiteName: "tempo.live.tests")!))
        await desk.start()
        var connected: DeskState?
        for await state in await desk.states() where state.status == .connected && state.today != nil {
            connected = state; break
        }
        let state = try XCTUnwrap(connected)
        XCTAssertNotNil(state.heightTenths)
        XCTAssertNotNil(state.settings?.cruise)
        print("LIVE settings:", state.settings!, "today:", state.today!)
        await desk.stop()
    }
}

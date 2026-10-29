import Foundation
import os
@testable import DeskpilotKit

/// In-memory desk. Registers live in a dictionary; the history ring lives in `history`.
///
/// Every accessor goes through `locked`, a *synchronous* critical section: the tests drive
/// this from an actor's async methods, and taking a lock across a possible suspension point
/// is both a correctness hazard and a Swift 6 error.
final class FakeTransport: DeskTransport, @unchecked Sendable {
    let events: AsyncStream<ConnectionEvent>
    private let eventsContinuation: AsyncStream<ConnectionEvent>.Continuation
    private let lock = OSAllocatedUnfairLock()

    var registers: [UInt32: UInt32] {
        get { locked { _registers } }
        set { locked { _registers = newValue } }
    }
    var history: Data {
        get { locked { _history } }
        set { locked { _history = newValue } }
    }
    var connectError: DeskError? {
        get { locked { _connectError } }
        set { locked { _connectError = newValue } }
    }
    var readError: DeskError? {
        get { locked { _readError } }
        set { locked { _readError = newValue } }
    }
    /// Number of upcoming reads (register or burst) that fail with a transient GATT error
    /// before the transport starts behaving again. Models a flaky link.
    var failNextReads: Int {
        get { locked { _failNextReads } }
        set { locked { _failNextReads = newValue } }
    }
    /// The real desk ignores the value written to a preset register and stores its *current*
    /// height instead (docs/protocol.md, user block offsets 16/20/24/28). Tests that don't
    /// care can turn this off.
    var capturesPresets: Bool {
        get { locked { _capturesPresets } }
        set { locked { _capturesPresets = newValue } }
    }
    var strings: [UInt32: Data] { locked { _strings } }
    var writes: [(address: UInt32, value: UInt32)] { locked { _writes } }
    var burstWrites: [(address: UInt32, data: Data)] { locked { _burstWrites } }
    var connectCalls: Int { locked { _connectCalls } }
    var readCount: Int { locked { _readCount } }
    /// Reads per address (register reads keyed by register address, burst reads keyed by
    /// byte address), so a test can isolate one register's poll cadence instead of being
    /// skewed by unrelated traffic (e.g. history bursts) sharing the same overall count.
    var readCounts: [UInt32: Int] { locked { _readCounts } }

    private var _registers: [UInt32: UInt32] = [:]
    private var _history = Data()
    private var _strings: [UInt32: Data] = [:]
    private var _connectError: DeskError?
    private var _readError: DeskError?
    private var _failNextReads = 0
    private var _capturesPresets = true
    private var _writes: [(address: UInt32, value: UInt32)] = []
    private var _burstWrites: [(address: UInt32, data: Data)] = []
    private var _connectCalls = 0
    private var _readCount = 0
    private var _readCounts: [UInt32: Int] = [:]

    init() {
        (events, eventsContinuation) = AsyncStream<ConnectionEvent>.makeStream()
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func emit(_ event: ConnectionEvent) { eventsContinuation.yield(event) }

    func connect() async throws {
        let err = locked { () -> DeskError? in
            _connectCalls += 1
            return _connectError
        }
        if let err { throw err }
        emit(.connected)
    }

    func disconnect() async { emit(.disconnected(reason: "requested")) }

    func readRegister(_ address: UInt32) async throws -> UInt32 {
        try locked {
            _readCount += 1
            _readCounts[address, default: 0] += 1
            if let _readError { throw _readError }
            if _failNextReads > 0 { _failNextReads -= 1; throw DeskError.gatt("flaky") }
            if address >= Register.historyBase {
                let off = Int(address - Register.historyBase)
                guard off + 4 <= _history.count else { return 0xDEAD_BEEF }
                return _history.subdata(in: off..<(off + 4)).uint32LE!
            }
            return _registers[address] ?? 0xDEAD_BEEF
        }
    }

    func writeRegister(_ address: UInt32, value: UInt32) async throws {
        locked {
            if _capturesPresets, Self.isPresetAddress(address) {
                // The desk stores the height it is at, not the value you sent.
                _registers[address] = (_registers[Register.status] ?? 0) & 0xFFFF
            } else {
                _registers[address] = value
            }
            _writes.append((address, value))
        }
    }

    /// User block offsets 16/20/24/28 (standing, sitting, custom 1, custom 2), either user.
    private static func isPresetAddress(_ address: UInt32) -> Bool {
        [0, 1].contains { user in
            let base = Register.userBase(user)
            return address >= base + 16 && address <= base + 28 && (address - base) % 4 == 0
        }
    }

    func burstRead(byteAddress: UInt32, chunks: Int) async throws -> Data {
        try locked {
            _readCount += 1
            _readCounts[byteAddress, default: 0] += 1
            if let _readError { throw _readError }
            if _failNextReads > 0 { _failNextReads -= 1; throw DeskError.gatt("flaky") }
            // The real desk ignores the low two bits of a burst address: it always serves
            // data starting at the address rounded down to a multiple of 4
            // (docs/protocol.md, "Register access"). Model that here, for both the history
            // and string regions, so tests exercise the same quirk `TempoDesk.pollHistory`
            // has to align around.
            let alignedAddress = byteAddress & ~UInt32(3)
            var out = Data()
            if alignedAddress >= Register.historyBase {
                let start = Int(alignedAddress - Register.historyBase)
                for i in 0..<(chunks * 20) {
                    let idx = start + i
                    out.append(idx < _history.count ? _history[idx] : 0)
                }
            } else if let s = _strings[alignedAddress] {
                out = s + Data(repeating: 0, count: max(0, chunks * 20 - s.count))
            } else {
                out = Data(repeating: 0xEF, count: chunks * 20)
            }
            return out
        }
    }

    func burstWrite(byteAddress: UInt32, data: Data) async throws {
        locked {
            _strings[byteAddress] = data
            _burstWrites.append((byteAddress, data))
        }
    }

    // Helpers for tests

    /// Replaces the ring buffer and its write pointer atomically, so a poll running
    /// concurrently can never see new bytes with the old pointer or vice versa.
    func setHistory(_ bytes: [UInt8], minutesSincePowerOn: UInt32? = nil) {
        locked {
            _history = Data(bytes)
            _registers[Register.historyWritePointer] = UInt32(bytes.count)
            if let minutesSincePowerOn { _registers[Register.minutesSincePowerOn] = minutesSincePowerOn }
        }
    }

    func appendHistory(_ bytes: [UInt8]) {
        locked {
            _history.append(contentsOf: bytes)
            _registers[Register.historyWritePointer] = UInt32(_history.count)
        }
    }
}

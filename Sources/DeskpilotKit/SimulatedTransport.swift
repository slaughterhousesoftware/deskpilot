import Foundation
import os

/// A desk that lives in memory, for developing the app's UI without the real one: pick a
/// scenario and the menu bar, menu, widget and dashboard all see a desk in that state. Run
/// the menu bar app with `DESKPILOT_SIMULATE=<scenario>` in its environment.
///
/// Registers live in a dictionary and the history ring in `history`, exactly as the real
/// desk lays them out, so `TempoDesk` runs unchanged on top of it.
public final class SimulatedTransport: DeskTransport, @unchecked Sendable {
    public enum Scenario: String, CaseIterable, Sendable {
        /// Standing at the desk, next sit in about eleven minutes.
        case standing
        /// Sitting at the desk, next stand in about eleven minutes.
        case sitting
        /// Sitting, with the next stand due in about forty seconds - the countdown's end.
        case countdown
        /// Sitting; two seconds after connecting the desk announces a stand (COUNTDOWN entry),
        /// beeps for fifteen seconds, then rises.
        case beeping
        /// A realistic working day so far: irregular spells, minute-long slivers, breaks of a
        /// few minutes and of an hour, over eleven hours - what the timeline strip has to
        /// survive.
        case busyDay
        /// A day replayed from the menu bar app's `timeline` log line: `DESKPILOT_REPLAY` holds
        /// its `segs=` field (`s540-579,S579-599,b599-609,…`, minutes since the day start)
        /// and `now=` is taken from `DESKPILOT_REPLAY_NOW`, so the strip spans exactly as it did.
        case replay
        /// The desk sees nobody: looking for you.
        case away
        /// The desk is rising from sitting to standing height, over about twelve seconds.
        case moving
        /// Cruise control paused.
        case paused
        /// Cruise control turned off on the desk.
        case cruiseOff
        /// Connecting forever.
        case connecting
        /// Every connection attempt fails: out of reach.
        case outOfReach
        /// Bluetooth is switched off.
        case bluetoothOff
        /// Bluetooth access was denied.
        case unauthorized
    }

    public let events: AsyncStream<ConnectionEvent>
    private let eventsContinuation: AsyncStream<ConnectionEvent>.Continuation
    private let lock = OSAllocatedUnfairLock()
    private var registers: [UInt32: UInt32] = [:]
    private var history = Data()
    private var strings: [UInt32: Data] = [:]
    private let scenario: Scenario
    private var motion: Task<Void, Never>?

    public init(scenario: Scenario) {
        self.scenario = scenario
        (events, eventsContinuation) = AsyncStream<ConnectionEvent>.makeStream()
        seed()
    }

    /// `DESKPILOT_SIMULATE` from the environment, if it names a scenario.
    public static var scenarioFromEnvironment: Scenario? {
        ProcessInfo.processInfo.environment["DESKPILOT_SIMULATE"].flatMap(Scenario.init(rawValue:))
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - The desk's state for each scenario

    private static let sittingTenths: UInt32 = 266
    private static let standingTenths: UInt32 = 372
    /// The desk's clock, in minutes since it was powered on, at the moment the app connects.
    private static let minutesNow: UInt32 = 5883

    private func seed() {
        let user: UInt32 = 4096
        var flags: UInt32 = 0x1E3
        if scenario == .paused { flags |= 0x4 }
        let standing = [.standing, .moving].contains(scenario)
        let present = scenario != .away
        registers = [
            Register.firmwareApplication: 0x0001_0005,
            Register.minutesSincePowerOn: Self.minutesNow,
            Register.historySize: 8192,
            Register.currentUser: 0,
            Register.status: (present ? 0x100 : 0) | (scenario == .moving ? Self.sittingTenths : (standing ? Self.standingTenths : Self.sittingTenths)),
            user + Register.UserOffset.flags: flags,
            user + Register.UserOffset.activeCruiseSlot: scenario == .cruiseOff ? 0 : 1,
            user + Register.UserOffset.countdownAndPulse: 0x0008_000F,
            user + Register.UserOffset.middleOfNightHour: 4,
            user + Register.UserOffset.standingHeight: Self.standingTenths,
            user + Register.UserOffset.sittingHeight: Self.sittingTenths,
            user + Register.UserOffset.customHeightOne: 0,
            user + Register.UserOffset.customHeightTwo: 0,
            user + Register.UserOffset.moveCount: 7,
            Register.cruiseSlotAddress(user: 0, slot: 1): 0x04B0_04B0,
        ]
        // A morning at the desk, stamped in the desk's minutes: arrived 2 h ago, alternated
        // every 20 min, and the last move sets the countdown. Minute bytes are `minute % 256`.
        var log: [UInt8] = []
        func entry(minutesAgo: Int, _ kind: UInt8) {
            log.append(UInt8((Int(Self.minutesNow) - minutesAgo) % 256)); log.append(kind)
        }
        let presence: (Bool) -> UInt8 = { $0 ? 0b0101_0001 : 0b0101_0000 }
        let move: (Bool) -> UInt8 = { $0 ? 0b0101_1101 : 0b0101_1100 }
        let countdownEntry: (Bool) -> UInt8 = { $0 ? 0b0101_1001 : 0b0101_1000 }
        entry(minutesAgo: 120, presence(true))
        var toStanding = true
        var minutesAgo = 110
        while minutesAgo > 9 {
            entry(minutesAgo: minutesAgo + 1, countdownEntry(toStanding))
            entry(minutesAgo: minutesAgo, move(toStanding))
            toStanding.toggle()
            minutesAgo -= 20
        }
        // The last logged move decides the posture: make it match the scenario.
        let lastToStanding = !toStanding
        if lastToStanding != standing {
            entry(minutesAgo: 9, move(standing))
        }
        switch scenario {
        case .busyDay:
            log.removeAll()
            // (minutes, kind): "s" sitting, "S" standing, "b" break - oldest first, ending now.
            let day: [(Int, Character)] = [(41, "s"), (20, "S"), (30, "s"), (20, "S"), (33, "s"), (10, "b"),
                                           (27, "s"), (20, "S"), (5, "s"), (2, "S"), (31, "s"), (20, "S"),
                                           (65, "b"), (30, "s"), (20, "S"), (28, "s"), (3, "b"), (12, "s"),
                                           (1, "S"), (30, "s"), (20, "S"), (4, "b"), (1, "s"), (1, "S"),
                                           (33, "s"), (20, "S"), (28, "s"), (95, "b"), (21, "s"), (20, "S"), (14, "s")]
            var minutesAgo = day.reduce(0) { $0 + $1.0 }
            entry(minutesAgo: minutesAgo, presence(true))
            var previous: Character = "s"
            for (length, kind) in day {
                if kind == "b" {
                    entry(minutesAgo: minutesAgo, presence(false))
                } else {
                    if previous == "b" { entry(minutesAgo: minutesAgo, presence(true)) }
                    entry(minutesAgo: minutesAgo, move(kind == "S"))
                }
                previous = kind
                minutesAgo -= length
            }
        case .replay:
            log.removeAll()
            let env = ProcessInfo.processInfo.environment
            let nowMinute = Int(env["DESKPILOT_REPLAY_NOW"] ?? "") ?? 0
            var previousKind: Character = "b"
            for item in (env["DESKPILOT_REPLAY"] ?? "").split(separator: ",") {
                guard let kind = item.first, let dash = item.firstIndex(of: "-"),
                      let from = Int(item[item.index(after: item.startIndex)..<dash]) else { continue }
                let minutesAgo = nowMinute - from
                if kind == "b" {
                    entry(minutesAgo: minutesAgo, presence(false))
                } else {
                    if previousKind == "b" { entry(minutesAgo: minutesAgo, presence(true)) }
                    entry(minutesAgo: minutesAgo, move(kind == "S"))
                }
                previousKind = kind
            }
        case .countdown, .beeping:
            // Sat down 19 minutes ago: the next stand is due in about a minute.
            log.removeAll()
            entry(minutesAgo: 120, presence(true))
            entry(minutesAgo: 19, move(false))
        case .away:
            entry(minutesAgo: 3, presence(false))
        default:
            break
        }
        history = Data(log)
        registers[Register.historyWritePointer] = UInt32(log.count)
    }

    // MARK: - DeskTransport

    public func connect() async throws {
        switch scenario {
        case .connecting:
            eventsContinuation.yield(.connecting)
            try await Task.sleep(nanoseconds: .max / 2)
        case .outOfReach:
            throw DeskError.gatt("simulated: out of reach")
        case .bluetoothOff:
            throw DeskError.bluetoothOff
        case .unauthorized:
            throw DeskError.unauthorized
        default:
            eventsContinuation.yield(.connected)
            if scenario == .moving { startRising() }
            if scenario == .beeping { startBeeping() }
        }
    }

    public func disconnect() async {
        motion?.cancel()
        eventsContinuation.yield(.disconnected(reason: "requested"))
    }

    /// The real sequence of an automatic stand, on the real timings: the COUNTDOWN entry
    /// lands in the log, and `DayRollup.beepSeconds` later the desk rises.
    private func startBeeping() {
        motion?.cancel()
        motion = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.locked {
                guard let self else { return }
                self.history.append(contentsOf: [UInt8(Int(Self.minutesNow) % 256), 0b0101_1001])
                self.registers[Register.historyWritePointer] = UInt32(self.history.count)
            }
            try? await Task.sleep(nanoseconds: UInt64(DayRollup.beepSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.startRising()
        }
    }

    /// Ramps the status register from sitting to standing height, a tenth of an inch at a
    /// time, with the motion bit set until it settles - then does it again the other way
    /// every so often, so the menu bar's gliding readout can be watched at leisure.
    private func startRising() {
        motion?.cancel()
        motion = Task { [weak self] in
            var up = true
            while !Task.isCancelled {
                let from = up ? Self.sittingTenths : Self.standingTenths
                let to = up ? Self.standingTenths : Self.sittingTenths
                let step: Int = up ? 1 : -1
                var height = Int(from)
                while height != Int(to), !Task.isCancelled {
                    height += step
                    self?.locked { self?.registers[Register.status] = 0x8000_0100 | UInt32(height) }
                    try? await Task.sleep(nanoseconds: 110_000_000)
                }
                self?.locked { self?.registers[Register.status] = 0x100 | to }
                up.toggle()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    public func readRegister(_ address: UInt32) async throws -> UInt32 {
        locked {
            if address >= Register.historyBase {
                let off = Int(address - Register.historyBase)
                guard off + 4 <= history.count else { return 0 }
                return history.subdata(in: off..<(off + 4)).uint32LE ?? 0
            }
            return registers[address] ?? 0
        }
    }

    public func writeRegister(_ address: UInt32, value: UInt32) async throws {
        locked { registers[address] = value }
    }

    public func burstRead(byteAddress: UInt32, chunks: Int) async throws -> Data {
        locked {
            let aligned = byteAddress & ~UInt32(3)
            var out = Data()
            if aligned >= Register.historyBase {
                let start = Int(aligned - Register.historyBase)
                for i in 0..<(chunks * 20) {
                    let idx = start + i
                    out.append(idx < history.count ? history[idx] : 0)
                }
            } else if let s = strings[aligned] {
                out = s + Data(repeating: 0, count: max(0, chunks * 20 - s.count))
            } else {
                out = Data(repeating: 0, count: chunks * 20)
            }
            return out
        }
    }

    public func burstWrite(byteAddress: UInt32, data: Data) async throws {
        locked { strings[byteAddress] = data }
    }
}

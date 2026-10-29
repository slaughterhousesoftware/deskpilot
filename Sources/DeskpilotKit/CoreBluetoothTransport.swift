import Foundation
@preconcurrency import CoreBluetooth

/// The only file that talks CoreBluetooth. All GATT traffic is serialised through `gate`.
public final class CoreBluetoothTransport: NSObject, DeskTransport, @unchecked Sendable {
    public static let serviceUUID = CBUUID(string: "DA582000-796B-40FD-AEAB-B06C95C30A5E")
    static let addrUUID = CBUUID(string: "DA582001-796B-40FD-AEAB-B06C95C30A5E")
    static let dataUUID = CBUUID(string: "DA582002-796B-40FD-AEAB-B06C95C30A5E")
    static let burstAddrUUID = CBUUID(string: "DA582010-796B-40FD-AEAB-B06C95C30A5E")
    static let burstLenUUID = CBUUID(string: "DA582011-796B-40FD-AEAB-B06C95C30A5E")
    static let burstDataUUID = CBUUID(string: "DA582012-796B-40FD-AEAB-B06C95C30A5E")
    static let allCharacteristics = [addrUUID, dataUUID, burstAddrUUID, burstLenUUID, burstDataUUID]
    static let peripheralDefaultsKey = "tempo.peripheralIdentifier"

    public let events: AsyncStream<ConnectionEvent>
    private let eventsContinuation: AsyncStream<ConnectionEvent>.Continuation
    private let queue = DispatchQueue(label: "com.kevinpatel.tempo.ble")
    private let gate = AsyncGate()
    private let defaults: UserDefaults
    private let operationTimeout: TimeInterval

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]

    /// Keyed by a per-wait id so a timed-out waiter can remove exactly itself.
    private var powerWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var scanContinuation: CheckedContinuation<CBPeripheral, Error>?
    private var readContinuation: CheckedContinuation<Data, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var burstContinuation: CheckedContinuation<Data, Error>?
    private var burstExpectedBytes = 0
    private var burstBuffer = Data()

    // Bumped every time the paired slot above is (re)stored, in the same `queue.async`
    // block that stores it. A scheduled timeout captures the generation at schedule
    // time and only acts if it still matches — otherwise the slot has moved on to a
    // newer, unrelated operation and the stale timeout must not touch it.
    private var connectGeneration: UInt64 = 0
    private var scanGeneration: UInt64 = 0
    private var readGeneration: UInt64 = 0
    private var writeGeneration: UInt64 = 0
    private var burstGeneration: UInt64 = 0

    public init(defaults: UserDefaults = .standard, operationTimeout: TimeInterval = 3) {
        (events, eventsContinuation) = AsyncStream<ConnectionEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        self.defaults = defaults
        self.operationTimeout = operationTimeout
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: DeskTransport

    public func connect() async throws {
        try await gate.run {
            try await self.waitForPoweredOn()
            self.eventsContinuation.yield(.connecting)
            let peripheral = try await self.findPeripheral()
            do {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    self.queue.async {
                        self.connectGeneration &+= 1
                        let gen = self.connectGeneration
                        self.connectContinuation = c
                        self.peripheral = peripheral
                        peripheral.delegate = self
                        self.central.connect(peripheral, options: nil)
                        self.scheduleTimeout(20) {
                            guard self.connectGeneration == gen, let pending = self.connectContinuation else { return }
                            self.connectContinuation = nil
                            pending.resume(throwing: DeskError.timeout("connect"))
                        }
                    }
                }
            } catch {
                // If this attempt was for a previously-remembered peripheral, forget it:
                // otherwise every retry burns another 20 s trying the same bad id before
                // ever falling back to scanning.
                if self.defaults.string(forKey: Self.peripheralDefaultsKey) == peripheral.identifier.uuidString {
                    self.defaults.removeObject(forKey: Self.peripheralDefaultsKey)
                }
                throw error
            }
            self.defaults.set(peripheral.identifier.uuidString, forKey: Self.peripheralDefaultsKey)
            self.eventsContinuation.yield(.connected)
        }
    }

    public func disconnect() async {
        await queueAsync {
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
        }
    }

    public func readRegister(_ address: UInt32) async throws -> UInt32 {
        try await gate.run {
            try await self.write(Self.addrUUID, Data(uint32LE: address))
            let data = try await self.read(Self.dataUUID)
            guard let value = data.uint32LE else { throw DeskError.gatt("short read at \(address)") }
            return value
        }
    }

    public func writeRegister(_ address: UInt32, value: UInt32) async throws {
        try await gate.run {
            try await self.write(Self.addrUUID, Data(uint32LE: address))
            try await self.write(Self.dataUUID, Data(uint32LE: value))
        }
    }

    public func burstRead(byteAddress: UInt32, chunks: Int) async throws -> Data {
        try await gate.run {
            try await self.write(Self.burstAddrUUID, Data(uint32LE: byteAddress))
            let expected = chunks * 20
            let seconds = self.operationTimeout + Double(chunks) * 0.5
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                self.queue.async {
                    self.burstBuffer = Data()
                    self.burstExpectedBytes = expected
                    guard let p = self.peripheral, let ch = self.characteristics[Self.burstLenUUID] else {
                        c.resume(throwing: DeskError.notConnected); return
                    }
                    self.burstGeneration &+= 1
                    let gen = self.burstGeneration
                    self.burstContinuation = c
                    p.writeValue(Data(uint32LE: UInt32(chunks)), for: ch, type: .withResponse)
                    self.scheduleTimeout(seconds) {
                        guard self.burstGeneration == gen, let pending = self.burstContinuation else { return }
                        self.burstContinuation = nil
                        pending.resume(throwing: DeskError.timeout("burst read"))
                    }
                }
            }
        }
    }

    public func burstWrite(byteAddress: UInt32, data: Data) async throws {
        try await gate.run {
            try await self.write(Self.burstAddrUUID, Data(uint32LE: byteAddress))
            try await self.write(Self.burstDataUUID, data.prefix(20))
        }
    }

    // MARK: Primitives (call only inside gate.run)

    private func write(_ uuid: CBUUID, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.queue.async {
                guard let p = self.peripheral, p.state == .connected, let ch = self.characteristics[uuid] else {
                    c.resume(throwing: DeskError.notConnected); return
                }
                self.writeGeneration &+= 1
                let gen = self.writeGeneration
                self.writeContinuation = c
                p.writeValue(data, for: ch, type: .withResponse)
                self.scheduleTimeout(self.operationTimeout) {
                    guard self.writeGeneration == gen, let pending = self.writeContinuation else { return }
                    self.writeContinuation = nil
                    pending.resume(throwing: DeskError.timeout("write \(uuid)"))
                }
            }
        }
    }

    private func read(_ uuid: CBUUID) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            self.queue.async {
                guard let p = self.peripheral, p.state == .connected, let ch = self.characteristics[uuid] else {
                    c.resume(throwing: DeskError.notConnected); return
                }
                self.readGeneration &+= 1
                let gen = self.readGeneration
                self.readContinuation = c
                p.readValue(for: ch)
                self.scheduleTimeout(self.operationTimeout) {
                    guard self.readGeneration == gen, let pending = self.readContinuation else { return }
                    self.readContinuation = nil
                    pending.resume(throwing: DeskError.timeout("read \(uuid)"))
                }
            }
        }
    }

    /// Waits for the local Bluetooth radio to power on. `.poweredOff`, `.unauthorized` and
    /// `.unsupported` fail immediately: a radio that is already off reports the same state
    /// on every retry, and waiting for a `centralManagerDidUpdateState` that has already
    /// fired only turns "Bluetooth is off" into a 10 s `timeout("power on")`. The remaining
    /// states (`.unknown`, `.resetting`) are genuinely transient and do wait, but only for
    /// 10 s: switching Bluetooth off later resumes every waiter with `.bluetoothOff` via
    /// `centralManagerDidUpdateState`, and the deadline is the fallback for the case where
    /// that callback never fires again, so a wait can't survive forever. Each waiter owns
    /// its own dictionary entry, so a timeout only ever removes itself.
    private func waitForPoweredOn() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                switch self.central.state {
                case .poweredOn: c.resume()
                case .poweredOff: c.resume(throwing: DeskError.bluetoothOff)
                case .unauthorized: c.resume(throwing: DeskError.unauthorized)
                case .unsupported: c.resume(throwing: DeskError.bluetoothUnavailable("unsupported"))
                default:
                    let id = UUID()
                    self.powerWaiters[id] = c
                    self.scheduleTimeout(10) {
                        guard let pending = self.powerWaiters.removeValue(forKey: id) else { return }
                        pending.resume(throwing: DeskError.timeout("power on"))
                    }
                }
            }
        }
    }

    private func findPeripheral() async throws -> CBPeripheral {
        if let stored = defaults.string(forKey: Self.peripheralDefaultsKey),
           let id = UUID(uuidString: stored) {
            let known = await queueSync { self.central.retrievePeripherals(withIdentifiers: [id]) }
            if let p = known.first { return p }
        }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CBPeripheral, Error>) in
            self.queue.async {
                self.scanGeneration &+= 1
                let gen = self.scanGeneration
                self.scanContinuation = c
                self.central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
                self.scheduleTimeout(15) {
                    guard self.scanGeneration == gen, let pending = self.scanContinuation else { return }
                    self.scanContinuation = nil
                    self.central.stopScan()
                    pending.resume(throwing: DeskError.timeout("scan"))
                }
            }
        }
    }

    /// Runs `fire` on `queue` after `seconds`. Every call site above pairs its
    /// `*Continuation` slot with a `*Generation` counter, bumped in the same
    /// `queue.async` block that stores the continuation, and captures that generation
    /// when it schedules its timeout here. `fire` must re-check both the generation and
    /// the slot before resuming: whichever of {the real CB delegate callback, this
    /// timeout} runs first (they're serialised on `queue`, so there's no race) clears
    /// the slot, and the loser finds a nil slot or a bumped generation and no-ops.
    /// Without the generation check, a timeout for an operation that already completed
    /// could fire after a later, unrelated operation reused the same slot and wrongly
    /// abort it — a stale deadline must never resolve an operation it wasn't scheduled
    /// for.
    private func scheduleTimeout(_ seconds: TimeInterval, fire: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + seconds, execute: fire)
    }

    private func queueAsync(_ body: @escaping () -> Void) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { body(); c.resume() }
        }
    }

    private func queueSync<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            queue.async { c.resume(returning: body()) }
        }
    }

    private func failAllPending(_ error: Error) {
        connectContinuation?.resume(throwing: error); connectContinuation = nil
        if scanContinuation != nil { central.stopScan() }
        scanContinuation?.resume(throwing: error); scanContinuation = nil
        readContinuation?.resume(throwing: error); readContinuation = nil
        writeContinuation?.resume(throwing: error); writeContinuation = nil
        burstContinuation?.resume(throwing: error); burstContinuation = nil
        powerWaiters.values.forEach { $0.resume(throwing: error) }
        powerWaiters = [:]
    }
}

// MARK: - CBCentralManagerDelegate

extension CoreBluetoothTransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            powerWaiters.values.forEach { $0.resume() }
            powerWaiters = [:]
        case .poweredOff:
            eventsContinuation.yield(.bluetoothOff)
            // Drains powerWaiters too, so connect() (holding the gate, awaiting
            // waitForPoweredOn) unblocks immediately instead of relying on its 10 s
            // fallback deadline.
            failAllPending(DeskError.bluetoothOff)
        case .unauthorized:
            eventsContinuation.yield(.unauthorized)
            powerWaiters.values.forEach { $0.resume(throwing: DeskError.unauthorized) }
            powerWaiters = [:]
        case .unsupported:
            powerWaiters.values.forEach { $0.resume(throwing: DeskError.bluetoothUnavailable("unsupported")) }
            powerWaiters = [:]
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let c = scanContinuation else { return }
        scanContinuation = nil
        central.stopScan()
        c.resume(returning: peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        characteristics = [:]
        peripheral.discoverServices([Self.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let err = DeskError.gatt("connect failed: \(error?.localizedDescription ?? "unknown")")
        connectContinuation?.resume(throwing: err); connectContinuation = nil
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        characteristics = [:]
        failAllPending(DeskError.notConnected)
        eventsContinuation.yield(.disconnected(reason: error?.localizedDescription))
    }
}

// MARK: - CBPeripheralDelegate

extension CoreBluetoothTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            connectContinuation?.resume(throwing: DeskError.gatt(error.localizedDescription)); connectContinuation = nil
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            connectContinuation?.resume(throwing: DeskError.gatt("Tempo service not found")); connectContinuation = nil
            return
        }
        peripheral.discoverCharacteristics(Self.allCharacteristics, for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] { characteristics[ch.uuid] = ch }
        guard Self.allCharacteristics.allSatisfy({ characteristics[$0] != nil }) else {
            connectContinuation?.resume(throwing: DeskError.gatt("missing characteristics")); connectContinuation = nil
            return
        }
        peripheral.setNotifyValue(true, for: characteristics[Self.burstDataUUID]!)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.burstDataUUID else { return }
        if let error {
            connectContinuation?.resume(throwing: DeskError.gatt("notify: \(error.localizedDescription)"))
        } else {
            connectContinuation?.resume()
        }
        connectContinuation = nil
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // A burstLen write's success is not itself the answer — the chunks arrive as
        // burstData notifications — so this branch must never fall through to
        // writeContinuation, whether or not a burst is actually pending (a late ack
        // after the burst already timed out must be dropped, not misapplied to
        // whatever unrelated write happens to be in flight now).
        if characteristic.uuid == Self.burstLenUUID {
            guard let c = burstContinuation else { return }
            if let error {
                burstContinuation = nil
                c.resume(throwing: DeskError.gatt(error.localizedDescription))
            }
            return
        }
        guard let c = writeContinuation else { return }
        writeContinuation = nil
        if let error { c.resume(throwing: DeskError.gatt(error.localizedDescription)) } else { c.resume() }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Same reasoning as didWriteValueFor above: a burstData notification must never
        // fall through to readContinuation (it would let 20 bytes of history payload
        // satisfy a pending register read via Data.uint32LE), and a plain data-register
        // notification must never satisfy burstContinuation.
        if characteristic.uuid == Self.burstDataUUID {
            guard let c = burstContinuation else { return }
            if let error {
                burstContinuation = nil
                c.resume(throwing: DeskError.gatt(error.localizedDescription)); return
            }
            burstBuffer.append(characteristic.value ?? Data())
            if burstBuffer.count >= burstExpectedBytes {
                burstContinuation = nil
                c.resume(returning: burstBuffer.prefix(burstExpectedBytes))
            }
            return
        }
        guard characteristic.uuid == Self.dataUUID, let c = readContinuation else { return }
        readContinuation = nil
        if let error { c.resume(throwing: DeskError.gatt(error.localizedDescription)) }
        else { c.resume(returning: characteristic.value ?? Data()) }
    }
}

/// Serialises async operations (a FIFO async mutex).
actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if let next = waiters.first { waiters.removeFirst(); next.resume() } else { busy = false }
    }
}

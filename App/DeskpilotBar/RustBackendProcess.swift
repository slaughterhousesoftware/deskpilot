import AppKit
import Foundation
import os
import DeskpilotKit

private let backendLog = Logger(subsystem: "com.kevinpatel.tempo", category: "backend")

/// Owns one bundled Rust child. Closing stdin stops it; an abrupt host death also closes
/// the pipe. Unexpected exits restart with bounded backoff. No Swift Bluetooth client runs.
@MainActor
final class RustBackendProcess {
    private let directory: URL
    private let receive: (RustServiceFrame) -> Void
    private let failed: (String) -> Void
    private var process: Process?
    private var lastConnectionStatus: String?
    private var input: Pipe?
    private var reader: Task<Void, Never>?
    private var restart: Task<Void, Never>?
    private var stopping = false
    private var failures = 0
    private var wake: NSObjectProtocol?

    init(directory: URL, receive: @escaping (RustServiceFrame) -> Void, failed: @escaping (String) -> Void) {
        self.directory = directory
        self.receive = receive
        self.failed = failed
        // Every command the queue takes - from this app, the Dashboard, the widget or Siri -
        // is announced on this notification. A byte on the child's stdin has it read the
        // queue now rather than on its next check.
        wake = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(CommandQueue.wakeNotificationName), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.nudge() }
        }
    }

    func start() {
        guard !stopping, process == nil else { return }
        lastConnectionStatus = nil
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tempo-backend")
        var args = ["--data-dir", directory.path, "serve", "--hosted"]
        if let scenario = ProcessInfo.processInfo.environment["DESKPILOT_SIMULATE"] {
            let aliases = ["busyDay": "busy-day", "cruiseOff": "cruise-off", "outOfReach": "out-of-reach", "bluetoothOff": "bluetooth-off"]
            args += ["--sim", aliases[scenario] ?? scenario]
        }
        child.arguments = args
        // Status samples while the desk moves, at debug level, so a wobble in the readout
        // can be traced to the register readings that produced it.
        var environment = ProcessInfo.processInfo.environment
        if environment["RUST_LOG"] == nil { environment["RUST_LOG"] = "info,tempo_desk::desk=debug" }
        child.environment = environment
        child.standardInput = stdin
        child.standardOutput = stdout
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let log = directory.appendingPathComponent("backend.log")
            if let size = try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 5_000_000 {
                let previous = directory.appendingPathComponent("backend.previous.log")
                try? FileManager.default.removeItem(at: previous)
                try? FileManager.default.moveItem(at: log, to: previous)
            }
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            let errors = try FileHandle(forWritingTo: log)
            try errors.seekToEnd()
            child.standardError = errors
            child.terminationHandler = { [weak self] process in
                try? errors.close()
                Task { @MainActor [weak self] in self?.exited(process) }
            }
            process = child
            input = stdin
            try child.run()
            // The parent owns only the writer; do not keep an extra read end alive.
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            reader = Task.detached { [weak self] in
                do {
                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        if Task.isCancelled { break }
                        guard let data = line.data(using: .utf8) else { continue }
                        let frame = try RustServiceFrame.decode(data)
                        // NSMenu tracks in a nested run loop. Deliver in common modes so
                        // backend state keeps arriving while that menu is open. Retain
                        // backpressure: read the next line only after this one is applied.
                        await withCheckedContinuation { continuation in
                            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                                MainActor.assumeIsolated { self?.received(frame, from: child) }
                                continuation.resume()
                            }
                        }
                    }
                } catch {
                    backendLog.error("UI stream failed: \(error.localizedDescription, privacy: .public)")
                    if child.isRunning { child.terminate() }
                }
                try? stdout.fileHandleForReading.close()
            }
            backendLog.notice("Rust backend launched pid=\(child.processIdentifier)")
        } catch {
            process = nil
            input = nil
            failed("Could not start Deskpilot's backend: \(error.localizedDescription)")
            scheduleRestart()
        }
    }

    private func nudge() {
        guard !stopping, let input else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data([UInt8(ascii: "\n")]))
    }

    private func received(_ frame: RustServiceFrame, from child: Process) {
        guard process === child, !stopping else { return }
        // Connection transitions belong in the app's unified log too: installers and
        // support can check the hosted service without opening its private data directory.
        if lastConnectionStatus != frame.state.status {
            lastConnectionStatus = frame.state.status
            backendLog.notice("Rust backend connection=\(frame.state.status, privacy: .public)")
        }
        if frame.state.status == "connected" { failures = 0 }
        receive(frame)
    }

    private func exited(_ child: Process) {
        guard process === child else { return }
        backendLog.notice("Rust backend exited status=\(child.terminationStatus)")
        process = nil
        try? input?.fileHandleForWriting.close()
        input = nil
        reader?.cancel()
        reader = nil
        guard !stopping else { return }
        failed("Deskpilot's backend stopped; reconnecting…")
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !stopping else { return }
        failures += 1
        let delay = min(30, 1 << min(failures - 1, 5))
        restart?.cancel()
        restart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    func stop() {
        stopping = true
        restart?.cancel()
        // EOF requests an orderly history flush, disconnected snapshot, and BLE release.
        try? input?.fileHandleForWriting.close()
        guard let child = process else { return }
        let deadline = Date().addingTimeInterval(5)
        while child.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if child.isRunning {
            child.terminate()
            let deadline = Date().addingTimeInterval(2)
            while child.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        reader?.cancel()
    }
}

import AppKit
import OSLog
import SwiftUI
import DeskpilotKit

/// AppKit lifecycle rather than a SwiftUI `App`. The menu bar item is a plain `NSStatusItem`
/// (see `StatusItemController`) because SwiftUI's `MenuBarExtra` insets its label ~13 pt a
/// side where AppKit status items use ~9, which made ours read as having extra space next to
/// its neighbours, and because it flattens the label to one image + one string (dropping a
/// second `Text`, inline symbols, and any padding modifiers).
/// Explicit entry point: `@main` on an `NSApplicationDelegate` runs `NSApplicationMain`,
/// which only installs a delegate from a main nib - this app has none, so the delegate was
/// never called (no status item, no Bluetooth). Retain the delegate here: `NSApplication`
/// holds it weakly.
@main
enum DeskpilotBarMain {
    private static var delegate: AppDelegate?

    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: DeskModel!
    private var statusItem: StatusItemController?

    // `pkill`/launchd send SIGTERM, not an Apple Event quit, and AppKit does not install a
    // default SIGTERM handler. Without this, killing the app by signal skips
    // `applicationWillTerminate` entirely. Route SIGTERM through normal termination so
    // the model can close the Rust service's input, flush history, and disconnect the
    // widget snapshot before the app exits.
    private static let sigtermSource: DispatchSourceSignal = {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        return source
    }()

    func applicationWillTerminate(_ notification: Notification) { model?.stop() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Self.sigtermSource
        Logger(subsystem: "com.kevinpatel.tempo", category: "app").info("launched; installing status item")
        let model = DeskModel()
        self.model = model
        statusItem = StatusItemController(model: model)
        model.start()
        DevBackendVerification.run(model: model)
        DeskpilotShortcuts.updateAppShortcutParameters()
    }
}

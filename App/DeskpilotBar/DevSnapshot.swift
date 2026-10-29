import AppKit
import SwiftUI
import os

/// A developer hook for working on the menu bar UI without a desk or a person at the Mac:
/// with `DESKPILOT_DEV_SNAPSHOT=<path prefix>` in the environment (alongside `DESKPILOT_SIMULATE`),
/// a few seconds after launch the app renders its own menu bar label to `<prefix>-label.png`
/// and its menu's rows, composed offscreen, to `<prefix>-menu.png`, then quits.
/// Only the app's own windows are captured, so no screen-recording or accessibility
/// permission is involved - it works from an ssh session on a headless build machine.
@MainActor
enum DevSnapshot {
    private static let log = Logger(subsystem: "com.kevinpatel.tempo", category: "dev")

    static var prefix: String? { ProcessInfo.processInfo.environment["DESKPILOT_DEV_SNAPSHOT"] }

    /// Schedules the capture. `label` is the view inside the status item; `menu` composes
    /// the menu's rows into one view (see `StatusItemController.composedMenuView`).
    /// A SwiftUI view rendered at 2x through ImageRenderer to `<prefix><suffix>` - for
    /// checking fine drawing (the timeline strip) on a build machine with a 1x display.
    @MainActor
    static func render<V: View>(_ view: V, suffix: String, delay: TimeInterval = 4.5) {
        guard let prefix else { return }
        let delay = ProcessInfo.processInfo.environment["DESKPILOT_DEV_SNAPSHOT_DELAY"].flatMap(Double.init) ?? delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for scheme in [ColorScheme.dark, .light] {
                let renderer = ImageRenderer(content: view
                    .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.96))
                    .environment(\.colorScheme, scheme))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: prefix + (scheme == .dark ? "" : "-light") + suffix))
                }
            }
        }
    }

    static func schedule(label: NSView, menu: @escaping @MainActor () -> NSView, delay: TimeInterval = 5) {
        guard let prefix else { return }
        let delay = ProcessInfo.processInfo.environment["DESKPILOT_DEV_SNAPSHOT_DELAY"].flatMap(Double.init) ?? delay
        log.info("snapshot scheduled for \(prefix, privacy: .public) in \(delay, privacy: .public)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            log.info("snapshot firing")
            capture(label, to: prefix + "-label.png")
            let composed = menu()
            // SwiftUI rows only render properly through the window server, so the composed
            // menu goes into a real window parked off the visible area, and that window's
            // image is captured (our own window: no screen-recording permission involved).
            let window = NSWindow(contentRect: composed.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = composed
            window.isOpaque = false
            window.backgroundColor = .clear
            window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let frames = max(1, min(600, Int(ProcessInfo.processInfo.environment["DESKPILOT_DEV_FRAMES"] ?? "1") ?? 1))
                let interval = max(0.05, Double(ProcessInfo.processInfo.environment["DESKPILOT_DEV_INTERVAL"] ?? "0.1") ?? 0.1)
                @MainActor func record(_ frame: Int) {
                    let suffix = frames == 1 ? "" : String(format: "-%04d", frame)
                    captureWindow(window, to: prefix + suffix + "-menu.png")
                    capture(label, to: prefix + suffix + "-label.png")
                    if frame + 1 < frames {
                        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { record(frame + 1) }
                    } else {
                        window.orderOut(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
                    }
                }
                record(0)
            }
        }
    }

    private static func captureWindow(_ window: NSWindow, to path: String) {
        let id = CGWindowID(window.windowNumber)
        guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) else {
            log.error("could not image window \(id, privacy: .public)")
            return
        }
        let size = NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2)
        let image = NSImage(size: size)
        image.addRepresentation(NSBitmapImageRep(cgImage: cg))
        write(image, to: path)
    }

    /// Renders a view at 2x onto the menu bar's dark blue, so the PNG shows what a person
    /// sees, and writes it.
    private static func capture(_ view: NSView, to path: String, padding: CGFloat = 12, tint: Bool = true) {
        // Preserve the native backing resolution. A Retina display supplies 2x
        // pixels; enlarging this logical canvas again would only resample them.
        let scale: CGFloat = 1
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            log.error("no bitmap for \(path, privacy: .public) (bounds \(String(describing: bounds), privacy: .public))")
            return
        }
        view.cacheDisplay(in: bounds, to: rep)
        let size = NSSize(width: (bounds.width + 2 * padding) * scale, height: (bounds.height + 2 * padding / 3) * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(red: 12 / 255, green: 38 / 255, blue: 94 / 255, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let drawn: NSImage
        if tint {
            // Template images draw black; the menu bar tints them white. Do the same.
            drawn = NSImage(size: bounds.size)
            drawn.lockFocus()
            rep.draw(in: NSRect(origin: .zero, size: bounds.size))
            NSColor.white.set()
            NSRect(origin: .zero, size: bounds.size).fill(using: .sourceIn)
            drawn.unlockFocus()
        } else {
            drawn = NSImage(size: bounds.size)
            drawn.addRepresentation(rep)
        }
        drawn.draw(in: NSRect(x: padding * scale, y: padding / 3 * scale, width: bounds.width * scale, height: bounds.height * scale))
        image.unlockFocus()
        write(image, to: path)
    }

    private static func write(_ image: NSImage, to path: String) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            log.info("wrote \(path, privacy: .public)")
        } catch {
            log.error("could not write \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `DESKPILOT_DEV_OPEN_MENU=<path>`: opens the real status menu a few seconds after launch and
    /// images its window (our own window: no screen-recording permission involved) to `<path>`,
    /// then quits. Unlike the composed snapshot this goes through the menu's own material and
    /// vibrancy, so colours are what a person sees.
    static func openMenu(item: NSStatusItem, menu: NSMenu, delay: TimeInterval = 6) {
        guard let path = ProcessInfo.processInfo.environment["DESKPILOT_DEV_OPEN_MENU"] else { return }
        let delay = ProcessInfo.processInfo.environment["DESKPILOT_DEV_SNAPSHOT_DELAY"].flatMap(Double.init) ?? delay
        // Menu tracking runs its own run loop mode, so use timers in the common modes.
        // The timer's block is `@Sendable`, but it fires on the main run loop it is added to,
        // so it is on the main actor and the menu is safe to use there.
        // Stage the current wallpaper in a temporary native window so unrelated
        // desktop files do not appear in documentation. Glass still composites live
        // against real screen pixels; no background is removed after capture.
        let backdrop: NSWindow?
        if ProcessInfo.processInfo.environment["DESKPILOT_DEV_DESKTOP_CONTEXT"] == "1",
           let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
           let wallpaper = NSImage(contentsOf: url) {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            let image = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
            image.image = wallpaper
            image.imageScaling = .scaleAxesIndependently
            window.contentView = image
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            backdrop = window
        } else { backdrop = nil }
        nonisolated(unsafe) let menu = menu
        let frames = max(1, min(600, Int(ProcessInfo.processInfo.environment["DESKPILOT_DEV_FRAMES"] ?? "1") ?? 1))
        let interval = max(0.05, Double(ProcessInfo.processInfo.environment["DESKPILOT_DEV_INTERVAL"] ?? "0.1") ?? 0.1)
        @MainActor func record(_ frame: Int) {
            let pid = ProcessInfo.processInfo.processIdentifier
            let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
            let mine = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
            let candidate = mine.compactMap { info -> (CGWindowID, CGFloat)? in
                guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                      let bounds = info[kCGWindowBounds as String] as? [String: CGFloat], let h = bounds["Height"] else { return nil }
                guard id != backdrop.map({ CGWindowID($0.windowNumber) }) else { return nil }
                return (id, h)
            }.max { $0.1 < $1.1 }
            let contextual = ProcessInfo.processInfo.environment["DESKPILOT_DEV_DESKTOP_CONTEXT"] == "1"
            let captureImage: CGImage? = {
                guard let (id, _) = candidate else { return nil }
                if contextual,
                   let info = mine.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == id }),
                   let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                   let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] {
                    // Capture actual composited pixels: menu, shadow, status item and
                    // the desktop behind the glass. A window-only PNG loses that material.
                    let desktop = CGDisplayBounds(CGMainDisplayID())
                    let buttonFrame = item.button.flatMap { button in
                        button.window?.convertToScreen(button.convert(button.bounds, to: nil))
                    }
                    let left = max(desktop.minX, min(x, buttonFrame?.minX ?? x) - 24)
                    let right = min(desktop.maxX, max(x + width, buttonFrame?.maxX ?? (x + width)) + 24)
                    let rect = CGRect(x: left, y: desktop.minY, width: right - left,
                                      height: min(y + height + 12, desktop.height))
                    return CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
                }
                return CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution])
            }()
            if let cg = captureImage {
                let image = NSImage(size: NSSize(width: cg.width, height: cg.height))
                image.addRepresentation(NSBitmapImageRep(cgImage: cg))
                write(image, to: frames == 1 ? path : path + String(format: "-%04d.png", frame))
            }
            if let label = item.button { capture(label, to: path + String(format: "-label-%04d.png", frame)) }
            if frame + 1 < frames {
                let timer = Timer(timeInterval: interval, repeats: false) { _ in MainActor.assumeIsolated { record(frame + 1) } }
                RunLoop.main.add(timer, forMode: .common)
            } else {
                menu.cancelTracking()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            }
        }
        let timer = Timer(timeInterval: delay + 1, repeats: false) { _ in MainActor.assumeIsolated { record(0) } }
        RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { item.button?.performClick(nil) }
    }
}

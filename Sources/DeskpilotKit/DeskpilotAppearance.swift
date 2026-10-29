import SwiftUI
import Observation

/// Ocean is the shared palette for the dashboard and menu bar popup. The posture colours are
/// Display P3, like the system's own: as sRGB they come out flat on a Mac's wide-gamut
/// screen (sRGB's blue reads as (74, 154, 248) there, next to the system blue's richer one).
public enum DeskpilotAppearance {
    public static let sitting = Color(.displayP3, red: 0.03, green: 0.53, blue: 1)
    public static let standing = Color(.displayP3, red: 0, green: 0.79, blue: 0.72)
    /// Warm selected cells remain distinct from the blue activity scale.
    public static let heatmapSelection = Color(red: 0.98, green: 0.66, blue: 0.17)
    /// A readable violet on light cards and a softer lavender on dark cards.
    public static let selection = Color(nsColor: NSColor(name: "DeskpilotSelection") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.75, green: 0.63, blue: 0.96, alpha: 1)
        }
        return NSColor(srgbRed: 0.46, green: 0.27, blue: 0.79, alpha: 1)
    })
}

public enum DeskpilotDisplayMode: String, CaseIterable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var title: String { self == .system ? "System" : rawValue.capitalized }
    public var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }

}

/// Appearance shared by dashboard and Settings windows, independent of desk settings.
@Observable
public final class DeskpilotDisplayPreferences {
    public static let shared = DeskpilotDisplayPreferences()
    public private(set) var mode: DeskpilotDisplayMode
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observer: NSObjectProtocol?
    private static let key = "tempoDisplayMode"
    private static let changed = Notification.Name("com.kevinpatel.tempo.displayModeChanged")

    public init(defaults: UserDefaults = UserDefaults(suiteName: SnapshotStore.appGroup) ?? .standard) {
        self.defaults = defaults
        mode = DeskpilotDisplayMode(rawValue: defaults.string(forKey: Self.key) ?? "") ?? .system
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.changed, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }
    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }
    public func select(_ mode: DeskpilotDisplayMode) {
        defaults.set(mode.rawValue, forKey: Self.key)
        defaults.synchronize()
        self.mode = mode
        DistributedNotificationCenter.default().postNotificationName(Self.changed, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
    }
    public func reload() {
        defaults.synchronize()
        let incoming = DeskpilotDisplayMode(rawValue: defaults.string(forKey: Self.key) ?? "") ?? .system
        if incoming != mode { mode = incoming }
    }

}

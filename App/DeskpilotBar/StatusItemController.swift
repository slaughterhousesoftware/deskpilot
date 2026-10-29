import AppKit
import os
import OSLog
import SwiftUI
import DeskpilotKit

/// Owns the menu bar item: hosts `MenuBarLabel` (SwiftUI) inside the status item's button,
/// keeps the item's width in step with the label, and attaches a real `NSMenu` - which gets
/// the system's own menu panel (Liquid Glass, no arrow, native positioning and row metrics),
/// where an `NSPopover` kept its arrow and a heavier tinted material and looked like nothing
/// else in the menu bar.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// Extra space either side of the label, on top of the ~8 pt AppKit itself puts between
    /// a status item's button and the edge of its window. Measured on this Mac: plain AppKit
    /// items (Wispr Flow, Wacom) show ~8.5 pt between their ink and the next item's window,
    /// `MenuBarExtra` items ~12 - so no extra at all matches the AppKit neighbours.
    private static let inset: CGFloat = 0

    private let model: DeskModel
    private let item: NSStatusItem
    private let hostingView: LabelHostingView
    private let menu = NSMenu()

    init(model: DeskModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        hostingView = LabelHostingView(rootView: LabelRoot(model: model))
        super.init()

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.onSizeChange = { [weak self] size in self?.labelSizeChanged(size) }

        if let button = item.button {
            button.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                hostingView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }

        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu

        labelSizeChanged(hostingView.intrinsicContentSize)
        DevSnapshot.schedule(label: hostingView, menu: { [unowned self] in self.composedMenuView() })
        DevSnapshot.render(MenuStatsRow(model: model).frame(width: MenuMetrics.width).padding(.vertical, 6),
                           suffix: "-stats.png")
        DevSnapshot.render(Self.headerSamples, suffix: "-header.png")
        DevSnapshot.render(Self.labelSamples, suffix: "-labels.png")
        DevSnapshot.openMenu(item: item, menu: menu)
    }

    /// Dev only: the header's layouts with the switch beside them, for
    /// checking spacing without a desk in a state to show them.
    private static var headerSamples: some View {
        let samples: [(String?, String, Bool)] = [("Sitting in", "8:29", true), ("Standing in", "12:04", true),
                                                  (nil, "Standing up…", false), ("Cruise control", "Paused", true),
                                                  (nil, "Out of reach", false), ("Connecting", "4 s", false)]
        return VStack(spacing: 0) {
            ForEach(samples.indices, id: \.self) { i in
                HStack {
                    MenuHeadline(label: samples[i].0, value: samples[i].1)
                        .frame(minWidth: samples[i].0 != nil ? MenuHeadline.headlineColumn : 0, alignment: .leading)
                    if samples[i].2 {
                        MenuHeadline(label: "At desk", value: i == 0 ? "6h 33m" : "10h 02m")
                            .frame(width: MenuHeadline.statColumn, alignment: .leading)
                            .padding(.leading, MenuHeadline.statSpacing)
                        MenuHeadline(label: "Stands", value: i == 0 ? "4" : "12")
                            .frame(width: MenuHeadline.statColumn, alignment: .leading)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: .constant(i != 2)).toggleStyle(MenuSwitchStyle()).labelsHidden()
                }
                .padding(.horizontal, MenuMetrics.horizontalInset)
                .padding(.top, 2).padding(.bottom, 4)
                Divider().padding(.horizontal, MenuMetrics.horizontalInset).padding(.vertical, 5)
            }
        }
        .padding(.vertical, 6)
        .frame(width: MenuMetrics.width)
    }

    /// The menu bar label in the states around a cancellation, one per row, for checking the
    /// cancelled arrow against the countdown it replaces.
    private static var labelSamples: some View {
        let now = Date()
        func state(_ today: TodayStats, standing: Bool) -> DeskState {
            var state = DeskState()
            state.status = .connected
            state.heightTenths = standing ? 411 : 266
            state.updatedAt = now
            state.today = today
            return state
        }
        let samples: [DeskState] = [
            state(TodayStats(isStanding: false, isPresent: true,
                             nextMove: NextMove(at: now.addingTimeInterval(509), toStanding: true)), standing: false),
            state(TodayStats(isStanding: false, isPresent: true,
                             nextMove: NextMove(at: now.addingTimeInterval(12), toStanding: true, announcedAt: now)), standing: false),
            state(TodayStats(isStanding: false, isPresent: true,
                             cancelledMove: CancelledMove(at: now, toStanding: true, reason: .wavedOff)), standing: false),
            state(TodayStats(isStanding: true, isPresent: true,
                             cancelledMove: CancelledMove(at: now, toStanding: false, reason: .wavedOff)), standing: true),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(samples.indices, id: \.self) { i in
                MenuBarLabel(state: samples[i]).padding(.horizontal, 8)
            }
        }
        .padding(8)
    }

    private func labelSizeChanged(_ size: CGSize) {
        guard size.width > 0 else { return }
        let length = ceil(size.width) + 2 * Self.inset
        guard length != item.length else { return }
        item.length = length
        Logger(subsystem: "com.kevinpatel.tempo", category: "app")
            .info("status item length=\(length, privacy: .public) label=\(size.width, privacy: .public)")
    }

    // MARK: Menu

    /// Rebuilt from the desk state each time the menu opens. The custom rows are SwiftUI
    /// views that keep updating live for as long as the menu stays open (the countdown
    /// ticks, the height readout follows the desk); the standard items are fixed per opening.
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        // The header carries the cruise control switch, and answers to Command-P for it: a
        // custom-view item can carry a key equivalent and an action of its own.
        let header = row(MenuHeaderRow(model: model))
        header.keyEquivalent = "p"
        header.target = self
        header.action = #selector(togglePause)
        menu.addItem(header)
        menu.addItem(.separator())
        // Today's numbers and the Dashboard stay on hand out of reach too, as of the last sync.
        menu.addItem(row(MenuStatsRow(model: model)))
        menu.addItem(.separator())
        menu.addItem(action("Dashboard…", #selector(openDashboard), key: "d"))
        if model.state.status != .connected {
            menu.addItem(action("Reconnect", #selector(reconnect), key: "r"))
        }
        if let error = model.lastActionError {
            menu.addItem(row(MenuMessageRow(text: error, isError: true)))
        }
        menu.addItem(.separator())
        menu.addItem(action("Quit", #selector(quit), key: "q"))
    }

    /// Dev only (see `DevSnapshot`): the menu's rows as it would build them now, stacked into
    /// one view on a menu-like background - the custom rows exactly as they are, the standard
    /// items as plain labels.
    func composedMenuView() -> NSView {
        menuWillOpen(menu)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        for menuItem in menu.items {
            let piece: NSView
            if menuItem.isSeparatorItem {
                let line = NSBox()
                line.boxType = .separator
                let wrapper = NSView()
                wrapper.addSubview(line)
                line.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    wrapper.heightAnchor.constraint(equalToConstant: 11),
                    line.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
                    line.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: MenuMetrics.horizontalInset),
                    line.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -MenuMetrics.horizontalInset),
                ])
                piece = wrapper
            } else if let view = menuItem.view {
                // A hosting view won't take a position from the stack directly; a plain
                // wrapper does, and the hosting view fills it. The height is the one the
                // menu itself would give the row.
                let height = max(view.fittingSize.height, view.frame.height)
                let wrapper = NSView()
                wrapper.addSubview(view)
                view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    wrapper.heightAnchor.constraint(equalToConstant: height),
                    view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                    view.topAnchor.constraint(equalTo: wrapper.topAnchor),
                    view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
                ])
                piece = wrapper
            } else {
                let label = NSTextField(labelWithString: menuItem.title)
                label.font = .menuFont(ofSize: 13)
                let key = NSTextField(labelWithString: menuItem.keyEquivalent.isEmpty ? "" : "⌘" + menuItem.keyEquivalent.uppercased())
                key.font = .menuFont(ofSize: 13)
                key.textColor = .secondaryLabelColor
                let rowView = NSView()
                rowView.addSubview(label)
                rowView.addSubview(key)
                label.translatesAutoresizingMaskIntoConstraints = false
                key.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    rowView.heightAnchor.constraint(equalToConstant: 24),
                    label.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: MenuMetrics.horizontalInset),
                    label.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
                    key.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -MenuMetrics.horizontalInset),
                    key.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
                ])
                piece = rowView
            }
            piece.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(piece)
            piece.widthAnchor.constraint(equalToConstant: MenuMetrics.width).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
        container.layer?.cornerRadius = 12
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.frame = NSRect(origin: .zero, size: container.fittingSize)
        return container
    }

    private func row<Content: View>(_ content: Content) -> NSMenuItem {
        let view = NSHostingView(rootView: ThemedMenuRow(content: content).frame(width: MenuMetrics.width))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func togglePause() {
        let paused = model.state.settings?.paused == true
        Task { _ = await model.setPaused(!paused) }
    }

    @objc private func openDashboard() { DashboardLauncher.open() }
    @objc private func reconnect() { model.reconnect() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// The hosted root: re-renders `MenuBarLabel` as the model changes (it's `@Observable`).
private struct LabelRoot: View {
    let model: DeskModel

    var body: some View {
        MenuBarLabel(state: model.state)
    }
}

/// Reports the label's ideal size whenever SwiftUI invalidates it, so the status item can be
/// resized to fit. (A `GeometryReader`/preference inside the label never fired here - the
/// item stayed at the empty button's default width and the label was clipped to its middle.)
private final class LabelHostingView: NSHostingView<LabelRoot> {
    var onSizeChange: ((CGSize) -> Void)?

    required init(rootView: LabelRoot) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @objc required dynamic init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?(intrinsicContentSize)
    }

    override func layout() {
        super.layout()
        onSizeChange?(intrinsicContentSize)
    }
}

/// Applies the shared Ocean accent to menu controls.
private struct ThemedMenuRow<Content: View>: View {
    let content: Content
    var body: some View { content.tint(DeskpilotAppearance.sitting) }
}

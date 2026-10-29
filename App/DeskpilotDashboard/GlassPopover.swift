import AppKit
import SwiftUI

// A popover drawn inside the window rather than in one of its own, so it can follow the pointer
// from item to item, animate as we choose, and render in the window's active glass. Its look is
// the system popover's, taken from a live `NSPopover` on macOS 27: the frame is an
// `NSGlassView` (a subclass of `NSGlassEffectView`) with glass variant 20, a 20-point continuous
// corner, and one outline - its private `_path` - that runs the arrow into the body. The curve
// points below are that outline's, read back from the real thing.

/// The popover's outline: a rounded body with an arrow on one edge pointing at `tip`.
enum PopoverOutline {
    /// How far the arrow stands off the body.
    static let arrowHeight: CGFloat = 11.2
    /// Half the arrow's base, curved shoulders included.
    static let arrowHalfWidth: CGFloat = 16
    static let cornerRadius: CGFloat = 20

    /// A continuous corner's extent along each edge, as a multiple of its radius.
    private static let cornerExtent: CGFloat = 1.52866
    /// One continuous corner, in (along the next edge, back along the last edge) units of the
    /// radius: the start point, then three cubic curves.
    private static let corner: [CGPoint] = [
        CGPoint(x: 0, y: 1.52866),
        CGPoint(x: 0, y: 1.10849), CGPoint(x: 0, y: 0.88840), CGPoint(x: 0.07491, y: 0.65150),
        CGPoint(x: 0.16906, y: 0.39283), CGPoint(x: 0.39283, y: 0.16906), CGPoint(x: 0.65150, y: 0.07491),
        CGPoint(x: 0.88840, y: 0), CGPoint(x: 1.10849, y: 0), CGPoint(x: 1.52866, y: 0),
    ]
    /// The arrow, as (along the edge from its middle, out from the body) offsets: a line to its
    /// start, then the shoulder, the flank, the tip, the other flank and the other shoulder.
    private enum ArrowStep { case line(CGPoint), curve(CGPoint, CGPoint, CGPoint) }
    private static let arrow: [ArrowStep] = [
        .line(CGPoint(x: -15.9925, y: 0)),
        .curve(CGPoint(x: -13.8933, y: 0), CGPoint(x: -11.8827, y: 0.8461), CGPoint(x: -10.4152, y: 2.3471)),
        .line(CGPoint(x: -3.9041, y: 9.00682)),
        .curve(CGPoint(x: -1.796, y: 11.16299), CGPoint(x: 1.6608, y: 11.20199), CGPoint(x: 3.817, y: 9.09391)),
        .curve(CGPoint(x: 3.8464, y: 9.06521), CGPoint(x: 3.8754, y: 9.03618), CGPoint(x: 3.9041, y: 9.00682)),
        .line(CGPoint(x: 10.4152, y: 2.3471)),
        .curve(CGPoint(x: 11.8827, y: 0.8461), CGPoint(x: 13.8933, y: 0), CGPoint(x: 15.9925, y: 0)),
    ]

    /// The outline in a y-up space (AppKit's, and the glass's): `body` is the rounded rectangle,
    /// `edge` the side the arrow comes out of, `along` the arrow's middle on that edge, measured
    /// from the body's left (top and bottom edges) or bottom (left and right edges).
    /// The corner radius a body of this size gets: the popover's 20, or less for a small one.
    static func radius(for size: CGSize) -> CGFloat {
        min(cornerRadius, size.width / (2 * cornerExtent), size.height / (2 * cornerExtent))
    }

    /// How close to either end of an edge the arrow's middle can come without running into a
    /// corner.
    static func arrowInset(for size: CGSize) -> CGFloat {
        cornerExtent * radius(for: size) + arrowHalfWidth
    }

    static func path(body: CGRect, edge: Edge, along: CGFloat) -> CGPath {
        let radius = radius(for: body.size)
        let path = CGMutablePath()
        /// A corner at `p`, arriving along `u` and leaving along `v`.
        func addCorner(at p: CGPoint, arriving u: CGVector, leaving v: CGVector, first: Bool) {
            func point(_ q: CGPoint) -> CGPoint {
                CGPoint(x: p.x + (v.dx * q.x - u.dx * q.y) * radius, y: p.y + (v.dy * q.x - u.dy * q.y) * radius)
            }
            if first { path.move(to: point(corner[0])) } else { path.addLine(to: point(corner[0])) }
            for i in stride(from: 1, to: corner.count, by: 3) {
                path.addCurve(to: point(corner[i + 2]), control1: point(corner[i]), control2: point(corner[i + 1]))
            }
        }
        /// The arrow centred at `c` on an edge run along `d`, standing out along `n`.
        func addArrow(at c: CGPoint, along d: CGVector, out n: CGVector) {
            func point(_ q: CGPoint) -> CGPoint { CGPoint(x: c.x + d.dx * q.x + n.dx * q.y, y: c.y + d.dy * q.x + n.dy * q.y) }
            for step in arrow {
                switch step {
                case .line(let p): path.addLine(to: point(p))
                case .curve(let c1, let c2, let p): path.addCurve(to: point(p), control1: point(c1), control2: point(c2))
                }
            }
        }
        let lo = cornerExtent * radius + arrowHalfWidth
        func clampAlong(_ length: CGFloat) -> CGFloat { min(max(along, lo), max(lo, length - lo)) }

        // Anticlockwise from the bottom-left corner, as the system's outline runs.
        addCorner(at: CGPoint(x: body.minX, y: body.minY), arriving: CGVector(dx: 0, dy: -1), leaving: CGVector(dx: 1, dy: 0), first: true)
        if edge == .bottom {
            addArrow(at: CGPoint(x: body.minX + clampAlong(body.width), y: body.minY), along: CGVector(dx: 1, dy: 0), out: CGVector(dx: 0, dy: -1))
        }
        addCorner(at: CGPoint(x: body.maxX, y: body.minY), arriving: CGVector(dx: 1, dy: 0), leaving: CGVector(dx: 0, dy: 1), first: false)
        if edge == .trailing {
            addArrow(at: CGPoint(x: body.maxX, y: body.minY + clampAlong(body.height)), along: CGVector(dx: 0, dy: 1), out: CGVector(dx: 1, dy: 0))
        }
        addCorner(at: CGPoint(x: body.maxX, y: body.maxY), arriving: CGVector(dx: 0, dy: 1), leaving: CGVector(dx: -1, dy: 0), first: false)
        if edge == .top {
            addArrow(at: CGPoint(x: body.minX + clampAlong(body.width), y: body.maxY), along: CGVector(dx: -1, dy: 0), out: CGVector(dx: 0, dy: 1))
        }
        addCorner(at: CGPoint(x: body.minX, y: body.maxY), arriving: CGVector(dx: -1, dy: 0), leaving: CGVector(dx: 0, dy: -1), first: false)
        if edge == .leading {
            addArrow(at: CGPoint(x: body.minX, y: body.minY + clampAlong(body.height)), along: CGVector(dx: 0, dy: -1), out: CGVector(dx: -1, dy: 0))
        }
        path.closeSubpath()
        return path
    }
}

/// The popover's glass and shadow, filling its view: the body, plus the arrow's room on `edge`.
struct PopoverGlass: NSViewRepresentable {
    let edge: Edge
    /// The arrow's middle along its edge, from the body's leading (top and bottom edges) or top
    /// (leading and trailing edges) side, in SwiftUI's top-down points.
    let along: CGFloat

    func makeNSView(context: Context) -> PopoverGlassView { PopoverGlassView() }

    func updateNSView(_ view: PopoverGlassView, context: Context) {
        view.edge = edge
        view.along = along
        view.needsLayout = true
    }
}

final class PopoverGlassView: NSView {
    var edge: Edge = .bottom
    var along: CGFloat = 0

    /// The glass the system's popover frame asks for (`NSPopoverFrame._glassVariant`).
    private static let popoverVariant = 20
    /// The shadows only fall outside the outline, as a window's does; under translucent glass
    /// they would show through and grey it.
    private let shadowMask = CAShapeLayer()
    private let glass: NSView
    private let keyShadow = CAShapeLayer()
    private let edgeShadow = CAShapeLayer()

    override init(frame: NSRect) {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = PopoverOutline.cornerRadius
            self.glass = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .popover
            blur.blendingMode = .withinWindow
            blur.state = .active
            self.glass = blur
        }
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        shadowMask.fillRule = .evenOdd
        // A soft shadow beneath and a tight one at the edge, in place of the window shadow the
        // real popover gets from the window server.
        for (shadow, radius, opacity, offset) in [(keyShadow, 12.0, 0.16, -5.0), (edgeShadow, 1.5, 0.14, -0.5)] {
            shadow.fillColor = NSColor.clear.cgColor
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowRadius = radius
            shadow.shadowOpacity = Float(opacity)
            shadow.shadowOffset = CGSize(width: 0, height: offset)
            layer?.addSublayer(shadow)
        }
        addSubview(glass)
        Self.call(glass, "set_variant:", Self.popoverVariant)
        // The popover's glass takes its light or dark look from the window (1); a plain glass
        // view adapts to what is behind it instead (2), which reads darker over a chart.
        Self.call(glass, "set_adaptiveAppearance:", 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The popover frame draws its glass in the vibrant appearances, as the real one does.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        glass.appearance = NSAppearance(named: dark ? .vibrantDark : .vibrantLight)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let h = PopoverOutline.arrowHeight
        var body = bounds
        switch edge {
        case .bottom: body.origin.y += h; body.size.height -= h
        case .top: body.size.height -= h
        case .leading: body.origin.x += h; body.size.width -= h
        case .trailing: body.size.width -= h
        }
        // `along` is top-down for the side edges; this space is bottom-up.
        let position = (edge == .leading || edge == .trailing) ? body.height - along : along
        let outline = PopoverOutline.path(body: body, edge: edge, along: position)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        keyShadow.frame = bounds
        edgeShadow.frame = bounds
        keyShadow.shadowPath = outline
        edgeShadow.shadowPath = outline
        let outside = CGMutablePath()
        outside.addRect(bounds.insetBy(dx: -40, dy: -40))
        outside.addPath(outline)
        shadowMask.path = outside
        shadowMask.frame = bounds
        let maskCopy = CAShapeLayer()
        maskCopy.fillRule = .evenOdd
        maskCopy.path = outside
        keyShadow.mask = shadowMask
        edgeShadow.mask = maskCopy
        CATransaction.commit()
        if !Self.callPath(glass, outline), let blur = glass as? NSVisualEffectView {
            // Before the system glass: the material, masked to the outline.
            let mask = CAShapeLayer()
            mask.path = outline
            blur.wantsLayer = true
            blur.layer?.mask = mask
        }
    }

    // MARK: - The glass's private setters, called only when they exist with the expected types

    private static func call(_ view: NSView, _ name: String, _ value: Int) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(type(of: view), selector),
              let types = method_getTypeEncoding(method), String(cString: types).hasPrefix("v") else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(view, selector, value)
    }

    @discardableResult
    private static func callPath(_ view: NSView, _ path: CGPath) -> Bool {
        let selector = NSSelectorFromString("_setPath:")
        guard let method = class_getInstanceMethod(type(of: view), selector),
              let types = method_getTypeEncoding(method), String(cString: types).contains("CGPath") else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, CGPath) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(view, selector, path)
        return true
    }
}

/// A popover in the window, pointing at `anchor`. Where it goes is worked out each time: every
/// side in `sides`, slid along that side, is tried, and the one that covers least of
/// `obstacles` - the chart's other marks - while staying inside `bounds` wins, the earlier
/// sides breaking ties. It scales out of its arrow's tip as it appears, follows the pointer
/// from item to item, and fades as it goes.
struct GlassPopover<Content: View>: View {
    let anchor: CGRect?
    let bounds: CGRect
    /// The sides of the item to try, in order of preference: `.top` puts the popover above it.
    var sides: [Edge] = [.top, .bottom]
    /// What it should rather not cover.
    var obstacles: [CGRect] = []
    @ViewBuilder let content: Content

    @State private var size: CGSize = .zero
    /// Where it last pointed, kept while it fades out.
    @State private var last: CGRect?
    private static var gap: CGFloat { 2 }
    private var h: CGFloat { PopoverOutline.arrowHeight }

    var body: some View {
        let placement = choose(last ?? .zero)
        content
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 11)
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
            .background {
                if !DevPerfDriver.omits("glass") {
                    PopoverGlass(edge: placement.arrowEdge, along: placement.along)
                        .padding(placement.arrowInsets)
                }
            }
            .scaleEffect(anchor == nil ? 0.86 : 1, anchor: placement.tip)
            .opacity(anchor == nil || size == .zero ? 0 : 1)
            .animation(anchor == nil ? .easeOut(duration: 0.14) : .spring(duration: 0.3, bounce: 0.18), value: anchor == nil)
            .position(x: placement.center.x, y: placement.center.y)
            .animation(.spring(duration: 0.26, bounce: 0), value: placement.center)
            .allowsHitTesting(false)
            .onChange(of: anchor, initial: true) { old, new in
                guard let new else { return }
                if old == nil {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { last = new }
                } else {
                    last = new
                }
            }
    }

    private struct Placement {
        var center: CGPoint
        /// The popover with its arrow, for judging what it covers.
        var frame: CGRect
        /// The edge of the popover the arrow leaves from.
        var arrowEdge: Edge
        var along: CGFloat
        /// Negative insets that give the glass room for the arrow outside the content.
        var arrowInsets: EdgeInsets
        /// The arrow's tip in the content's unit space, for the appearing scale.
        var tip: UnitPoint
    }

    /// The best of every side and slide that fits; the first side, pulled inside, if none does.
    private func choose(_ item: CGRect) -> Placement {
        var best: (placement: Placement, score: CGFloat)?
        for (rank, side) in sides.enumerated() {
            for (slideRank, slide) in [0, -1, 1, -0.5, 0.5].enumerated() {
                guard let placement = place(item, side: side, slide: CGFloat(slide)),
                      bounds.insetBy(dx: -0.5, dy: -0.5).contains(placement.frame) else { continue }
                // What it covers, in square points, with a small price on each step away from
                // the preferred side and from centred, so those win when nothing is covered.
                let covered = obstacles.reduce(CGFloat(0)) { total, obstacle in
                    let overlap = obstacle.intersection(placement.frame.insetBy(dx: -3, dy: -3))
                    return overlap.isNull ? total : total + overlap.width * overlap.height
                }
                let score = covered + CGFloat(rank) * 120 + CGFloat(slideRank) * 30
                if score < (best?.score ?? .infinity) { best = (placement, score) }
            }
        }
        if let best { return best.placement }
        let fallback = place(item, side: sides.first ?? .top, slide: 0, force: true)!
        var clamped = fallback
        clamped.center.x = min(max(fallback.center.x, bounds.minX + fallback.frame.width / 2), max(bounds.minX, bounds.maxX - fallback.frame.width / 2))
        return clamped
    }

    /// The popover on `side` of the item, slid along that side by `slide` (-1 to 1) of the room
    /// its arrow allows. Nil when its arrow could not then point at the item.
    private func place(_ item: CGRect, side: Edge, slide: CGFloat, force: Bool = false) -> Placement? {
        let w = size.width, ht = size.height, gap = Self.gap
        guard w > 0, ht > 0 else { return force ? Placement(center: CGPoint(x: item.midX, y: item.minY), frame: .zero, arrowEdge: .bottom,
                                                              along: 0, arrowInsets: EdgeInsets(), tip: .bottom) : nil }
        let inset = PopoverOutline.arrowInset(for: size)
        switch side {
        case .top, .bottom:
            guard w >= 2 * inset || force else { return nil }
            let above = side == .top
            let x = item.midX - slide * max(0, w / 2 - inset)
            let y = above ? item.minY - gap - h - ht / 2 : item.maxY + gap + h + ht / 2
            let along = item.midX - (x - w / 2)
            let frame = CGRect(x: x - w / 2, y: above ? y - ht / 2 : y - ht / 2 - h, width: w, height: ht + h)
            return Placement(center: CGPoint(x: x, y: y), frame: frame, arrowEdge: above ? .bottom : .top, along: along,
                             arrowInsets: above ? EdgeInsets(top: 0, leading: 0, bottom: -h, trailing: 0)
                                                : EdgeInsets(top: -h, leading: 0, bottom: 0, trailing: 0),
                             tip: UnitPoint(x: along / w, y: above ? 1 + h / ht : -h / ht))
        case .leading, .trailing:
            guard ht >= 2 * inset || force else { return nil }
            let right = side == .trailing
            // Tall items are pointed at near their top, where the eye lands.
            let target = min(item.midY, item.minY + 40)
            let x = right ? item.maxX + gap + h + w / 2 : item.minX - gap - h - w / 2
            let y = target - slide * max(0, ht / 2 - inset)
            let along = target - (y - ht / 2)
            let frame = CGRect(x: right ? x - w / 2 - h : x - w / 2, y: y - ht / 2, width: w + h, height: ht)
            return Placement(center: CGPoint(x: x, y: y), frame: frame, arrowEdge: right ? .leading : .trailing, along: along,
                             arrowInsets: right ? EdgeInsets(top: 0, leading: -h, bottom: 0, trailing: 0)
                                                : EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: -h),
                             tip: UnitPoint(x: right ? -h / w : 1 + h / w, y: along / ht))
        }
    }
}

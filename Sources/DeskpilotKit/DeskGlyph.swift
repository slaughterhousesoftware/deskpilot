import SwiftUI

/// Which desk pictogram to draw: the same standing desk in every glyph, and what is (or isn't)
/// at it carries the meaning.
public enum DeskGlyph: Sendable, Hashable, CaseIterable {
    /// Someone standing at the raised desk.
    case standing
    /// Someone seated at the lowered desk.
    case sitting
    /// Nobody at the desk: the presence sensor's waves sweeping the empty spot - the desk is
    /// looking for the user.
    case looking
    /// An ellipsis where the person would be - the app is still connecting to the desk.
    case searching
    /// The desk alone - out of Bluetooth reach, which is normal when the Mac has left the room.
    /// Drawn dimmed by whoever shows it.
    case outOfReach
    /// An exclamation mark where the person would be - something needs fixing before the desk
    /// can be reached (Bluetooth off, or access denied).
    case unavailable
    /// The desk alone on a canvas trimmed to it - no empty spot beside it for a person. Out
    /// of Bluetooth reach, which is normal when the Mac has left the room; drawn dimmed in the
    /// menu bar, the way macOS shows an item that's switched off.
    case unreachable
    /// Z's drifting up from the empty spot, out of the tabletop's front edge - the user is on
    /// a break away from the desk.
    case resting
}

/// Single-colour pictograms built the way SF Symbols are: the people are Apple's own `figure`
/// drawings (see `SymbolOutline`), and everything else is round-capped bars at the Regular
/// symbol stroke weight, all unioned into one outline. Designed on an 20x18 canvas (menu bar
/// size, ink 16 tall like a symbol's) and scaled uniformly to fit whatever rect is given.
public struct DeskGlyphShape: Shape {
    public let glyph: DeskGlyph

    public init(_ glyph: DeskGlyph) {
        self.glyph = glyph
    }

    /// The design is authored on a canvas this tall (and `DeskGlyph.designWidth` wide);
    /// `path(in:)` scales it uniformly to fit `rect`.
    static let designHeight: CGFloat = 18

    public func path(in rect: CGRect) -> Path {
        let designWidth = glyph.designWidth
        let scale = min(rect.width / designWidth, rect.height / Self.designHeight)
        let dx = rect.minX + (rect.width - designWidth * scale) / 2
        let dy = rect.minY + (rect.height - Self.designHeight * scale) / 2
        var transform = CGAffineTransform(translationX: dx, y: dy)
        transform = transform.scaledBy(x: scale, y: scale)
        return Self.design(glyph).applying(transform)
    }

    /// The glyph on the 18-unit canvas.
    public static func design(_ glyph: DeskGlyph) -> Path {
        switch glyph {
        case .standing: return standingPictogram()
        case .sitting: return union(figureSeated(), desk(tabletopTop: loweredTabletop))
        case .looking: return union(desk(tabletopTop: raisedTabletop), sensorWaves())
        case .searching: return union(desk(tabletopTop: raisedTabletop), radioBadge())
        case .outOfReach: return desk(tabletopTop: raisedTabletop)
        case .unavailable: return union(desk(tabletopTop: raisedTabletop), exclamationBadge())
        case .resting: return union(desk(tabletopTop: raisedTabletop), sleepBadge())
        case .unreachable:
            return desk(tabletopTop: raisedTabletop)
                .applying(CGAffineTransform(translationX: -unreachableTrim, y: 0))
        }
    }

    // MARK: - Proportions

    /// The standing figure is 16 tall (a symbol's full ink height, canvas y 1...17); every
    /// other part is sized off it. `unit` converts SF Symbols font units at that scale.
    static let figureHeight: CGFloat = 16
    static let unit = figureHeight / SymbolOutline.figureStand.bounds.height
    /// The Regular symbol stroke: the desk's column and foot, waves, the exclamation stem.
    static let stroke = SymbolOutline.strokeWidth * unit
    /// Limbs are a little heavier than the stroke (a symbol figure's leg is ~175 units).
    static let limb: CGFloat = 210 * unit
    static let top: CGFloat = 1
    static let floor: CGFloat = 17
    /// Tabletop height with the desk raised (standing, chest high) and lowered (the seated
    /// figure's hands rest on it); the monitor rides up and down with it.
    static let raisedTabletop: CGFloat = 7.0
    static let loweredTabletop: CGFloat = 9.1
    /// How much of the canvas's left the trimmed desk-only glyph drops: up to just shy of the
    /// tabletop's left end (8.6), leaving the same margin the desk has on its right.
    static let unreachableTrim: CGFloat = 8.0

    // MARK: - People

    /// A person standing at the desk in profile, built to the measurements of Apple's own
    /// upright side-on figure (`figure.archery`, Regular weight, in 2048/em font units): a
    /// 348-unit head, an upright 332x536 torso, a 169-unit arm from the shoulder, here
    /// angled down to rest a hand on the raised tabletop, and two straight 200-unit legs
    /// standing a little apart the way `figure.golf` stands.
    static func figureStanding() -> Path {
        standingVariant(ProcessInfo.processInfo.environment["DESKPILOT_STANDING_VARIANT"].flatMap(Int.init) ?? 0)
    }

    /// Candidate constructions for the standing figure (`DESKPILOT_STANDING_VARIANT=n` picks one
    /// at run time; `tools/glyph-harness --variants` draws them all). 0 is the shipping one.
    public static func standingVariant(_ variant: Int) -> Path {
        func place(_ body: Path, height: CGFloat = figureHeight, x: CGFloat = 1.0) -> Path {
            let bounds = body.boundingRect
            let scale = height / bounds.height
            return body.applying(CGAffineTransform(translationX: x - bounds.minX * scale, y: floor - height - bounds.minY * scale)
                .scaledBy(x: scale, y: scale))
        }
        func heavyBody(head: CGFloat = 400, torso: CGSize = CGSize(width: 440, height: 560)) -> Path {
            var body = Path(ellipseIn: CGRect(x: 670 - head / 2, y: 60, width: head, height: head))
            body.addRoundedRect(in: CGRect(x: 670 - torso.width / 2, y: 60 + head + 80, width: torso.width, height: torso.height),
                                cornerSize: CGSize(width: 110, height: 110))
            return body
        }
        func legs(_ body: Path, from y: CGFloat, to sole: CGFloat, width: CGFloat = 235, spread: CGFloat = 140) -> Path {
            body.union(capsule(from: CGPoint(x: 585, y: y), to: CGPoint(x: 560, y: sole), width: width))
                .union(capsule(from: CGPoint(x: 760, y: y), to: CGPoint(x: 760 + spread, y: sole), width: width))
        }
        switch variant {
        case 1:
            // Heavy profile, arm bent at the elbow: upper arm down, forearm level to the keys.
            var body = heavyBody()
            let shoulder = CGPoint(x: 780, y: 640), elbow = CGPoint(x: 900, y: 940)
            body = body.union(capsule(from: shoulder, to: elbow, width: 210))
            body = body.union(capsule(from: elbow, to: CGPoint(x: 1380, y: 900), width: 210))
            return place(legs(body, from: 1000, to: 1960))
        case 2:
            // Apple's archery figure verbatim - head, torso, front arm - on straight legs.
            var body = Path(ellipseIn: CGRect(x: 528, y: 116, width: 348, height: 348))
            body.addRoundedRect(in: CGRect(x: 454, y: 543, width: 332, height: 540), cornerSize: CGSize(width: 80, height: 80))
            body = body.union(capsule(from: CGPoint(x: 700, y: 628), to: CGPoint(x: 1290, y: 890), width: 169))
            body = body.union(capsule(from: CGPoint(x: 555, y: 1000), to: CGPoint(x: 540, y: 2010), width: 200))
            body = body.union(capsule(from: CGPoint(x: 690, y: 1000), to: CGPoint(x: 830, y: 2010), width: 200))
            return place(body)
        case 3:
            // The elliptical figure's leaning torso (as the seated one) on straight legs.
            let hips: CGFloat = -770
            var body = SymbolOutline.figureEllipticalUpper.path().subtracting(Path(CGRect(x: 0, y: hips, width: 3000, height: 3000)))
            let hip = CGPoint(x: 615, y: hips - 100)
            body = body.union(capsule(from: hip, to: CGPoint(x: 570, y: 400), width: 215))
            body = body.union(capsule(from: hip, to: CGPoint(x: 850, y: 400), width: 215))
            return place(body, x: 0.6)
        case 4:
            // Apple's frontal figure.stand with one arm out to the desk.
            var body = SymbolOutline.figureStand.path()
            body = body.union(capsule(from: CGPoint(x: 980, y: -960), to: CGPoint(x: 1560, y: -760), width: 175))
            return place(body, x: 0.4)
        case 5:
            // Apple's frontal figure.stand, untouched (what shipped before).
            return place(SymbolOutline.figureStand.path(), x: 0.6)
        case 6:
            // Heavy profile, feet together: one broad leg like figure.fishing.
            var body = heavyBody()
            body = body.union(capsule(from: CGPoint(x: 760, y: 650), to: CGPoint(x: 1340, y: 930), width: 210))
            body = body.union(Path(roundedRect: CGRect(x: 520, y: 1000, width: 300, height: 1080), cornerRadius: 120))
            return place(body)
        case 7:
            // Heavy profile with a bigger head and shorter legs, closer to figure.stand's proportions.
            var body = heavyBody(head: 460, torso: CGSize(width: 470, height: 600))
            body = body.union(capsule(from: CGPoint(x: 790, y: 700), to: CGPoint(x: 1360, y: 960), width: 220))
            return place(legs(body, from: 1080, to: 1900, width: 250, spread: 120))
        case 8:
            // Heavy profile, straight arm, torso a capsule (shoulders rounded like figure.walk).
            var body = Path(ellipseIn: CGRect(x: 470, y: 60, width: 400, height: 400))
            body.addRoundedRect(in: CGRect(x: 450, y: 540, width: 440, height: 600), cornerSize: CGSize(width: 220, height: 220))
            body = body.union(capsule(from: CGPoint(x: 760, y: 680), to: CGPoint(x: 1340, y: 940), width: 210))
            return place(legs(body, from: 1040, to: 1960))
        case 9:
            // Heavy profile, straight arm angled down to the tabletop (shipped 2026-09-11 pm).
            var body = heavyBody()
            let shoulder = CGPoint(x: 760, y: 650)
            let reach: CGFloat = 640
            let angle: CGFloat = 26 * .pi / 180
            body = body.union(capsule(from: shoulder, to: CGPoint(x: shoulder.x + reach * cos(angle), y: shoulder.y + reach * sin(angle)), width: 210))
            return place(legs(body, from: 1000, to: 1960))
        case 10:
            return figureStandingUpright()
        default:
            return figureStandingAtKeyboard()
        }
    }

    /// The same person as the seated glyph - Apple's `figure.elliptical` head, torso and
    /// forward arm - stood up: the torso turned upright about the hips (the elliptical leans
    /// into its stride, which reads as slouching when standing still), on two straight legs
    /// at the seated figure's limb weight, one a little forward, feet on the floor. Same
    /// scale as the seated figure, so the two are visibly the same person.
    static func figureStandingUpright() -> Path {
        let hips: CGFloat = -770
        let hip = CGPoint(x: 615, y: hips - 60)
        var body = SymbolOutline.figureEllipticalUpper.path().subtracting(Path(CGRect(x: 0, y: hips, width: 3000, height: 3000)))
        // Drop the elliptical's straight forward arm; a bent one goes on below.
        body = body.subtracting(Path(CGRect(x: 1095, y: -1420, width: 1000, height: 420)))
        body = body.applying(CGAffineTransform(translationX: hip.x, y: hip.y).rotated(by: -5 * .pi / 180).translatedBy(x: -hip.x, y: -hip.y))
        // Arm at a right angle: upper arm down and forward from the shoulder, forearm level
        // over the tabletop, at the figure's own limb weight.
        let shoulder = CGPoint(x: 990, y: -1190), elbow = CGPoint(x: 1160, y: -830), hand = CGPoint(x: 1660, y: -850)
        body = body.union(capsule(from: shoulder, to: elbow, width: 215))
        body = body.union(capsule(from: elbow, to: hand, width: 215))
        body = body.union(capsule(from: CGPoint(x: hip.x - 30, y: hip.y), to: CGPoint(x: hip.x - 60, y: 520), width: 215))
        body = body.union(capsule(from: CGPoint(x: hip.x + 70, y: hip.y), to: CGPoint(x: hip.x + 300, y: 520), width: 215))
        let bounds = body.boundingRect
        let scale = 14.5 / 2363.0   // the seated figure's scale: the same person at the same size
        let height = bounds.height * scale
        // Placed so the hand reaches the tabletop's near edge.
        let handX = bounds.maxX
        return body.applying(
            CGAffineTransform(translationX: 8.9 - handX * scale, y: floor - height - bounds.minY * scale)
                .scaledBy(x: scale, y: scale))
    }

    /// The person at the desk the way the classic standing-desk pictogram draws them, in
    /// Apple's smooth vocabulary. Proportions measured off the reference (head 150 px on an
    /// 860 px figure): head 2.8, torso 3.0 x 6.9 with rounded shoulders and a rounded back,
    /// legs one 1.9-wide block set forward so the back shows, arm 1.4 thick bent square at
    /// the elbow with the forearm just above the tabletop, feet flat on the floor line.
    static func figureStandingAtKeyboard() -> Path {
        let backX: CGFloat = 0.6
        let headDiameter: CGFloat = 2.8
        var path = Path(ellipseIn: CGRect(x: backX + 0.25, y: top, width: headDiameter, height: headDiameter))
        let torso = CGRect(x: backX, y: top + headDiameter + 0.4, width: 3.0, height: 6.9)
        var torsoPath = Path(roundedRect: torso, cornerRadius: 1.2)
        // Square the front bottom corner, where the legs continue; the back stays rounded.
        torsoPath.addRect(CGRect(x: torso.midX, y: torso.midY, width: torso.width / 2, height: torso.height / 2))
        path = path.union(torsoPath)
        let legs = CGRect(x: backX + 0.8, y: torso.maxY - 0.8, width: 1.9, height: floorLineTop - (torso.maxY - 0.8))
        path = path.union(Path(roundedRect: legs, cornerSize: CGSize(width: 0.25, height: 0.25)))
        let armWidth: CGFloat = 1.4
        let shoulder = CGPoint(x: torso.maxX - 0.6, y: torso.minY + 0.9)
        let elbow = CGPoint(x: torso.maxX + 0.55, y: raisedTabletop - 1.0)
        let hand = CGPoint(x: 9.1, y: raisedTabletop - 1.0)
        path = path.union(capsule(from: shoulder, to: elbow, width: armWidth))
        path = path.union(capsule(from: elbow, to: hand, width: armWidth))
        return path
    }

    /// How far the Tempo desk is shifted left under the standing figure: the reference
    /// person is compact (the hand reaches only ~4.5 units in front of the back), so the
    /// desk comes to them rather than leaving a gap.
    static let standingDeskShift: CGFloat = 2.4

    /// The standing figure is one straight column, back to front, with rounded shoulders and
    /// feet. A single outline avoids a hip-shaped bump where separate torso and leg shapes
    /// meet at menu-bar size.
    static func standingPictogram() -> Path {
        let s: CGFloat = figureHeight / 825
        func X(_ px: CGFloat) -> CGFloat { 0.6 + (px - 445) * s }
        func Y(_ px: CGFloat) -> CGFloat { top + (px - 321) * s }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: X(x), y: Y(y)) }
        // The head a touch larger than the reference's, with a clear gap above the shoulders
        // so the two don't run together at menu bar size.
        let head: CGFloat = 152
        var path = Path(ellipseIn: CGRect(x: X(518.5 - head / 2), y: Y(321), width: head * s, height: head * s))
        let shoulders: CGFloat = 321 + head + 28
        var body = Path()
        // One straight column from the shoulders to the feet, the same width all the way down:
        // a chest wider than the legs read as a belly at menu bar size.
        let front: CGFloat = 552
        body.move(to: point(498, shoulders))
        body.addCurve(to: point(front, shoulders + 54), control1: point(528, shoulders), control2: point(front, shoulders + 24))
        body.addLine(to: point(front, 1106))
        body.addCurve(to: point(front - 40, 1146), control1: point(front, 1128), control2: point(front - 18, 1146))
        body.addLine(to: point(485, 1146))
        body.addCurve(to: point(445, 1106), control1: point(463, 1146), control2: point(445, 1128))
        body.addLine(to: point(445, shoulders + 54))
        body.addCurve(to: point(498, shoulders), control1: point(445, shoulders + 24), control2: point(468, shoulders))
        body.closeSubpath()
        path = path.union(body)
        // Arm: the upper arm starts inside the torso so its top edge continues the shoulder
        // curve; the forearm lies level with its underside 0.3 above the tabletop, as in the
        // reference, and the hand reaches over the desk.
        let armWidth = 75 * s
        let forearmY = raisedTabletop - 0.3 - armWidth / 2
        let elbow = CGPoint(x: X(622), y: forearmY)
        path = path.union(capsule(from: CGPoint(x: X(535), y: Y(shoulders + 41)), to: elbow, width: armWidth))
        path = path.union(capsule(from: elbow, to: CGPoint(x: X(773), y: forearmY), width: armWidth))
        let deskPath = desk(tabletopTop: raisedTabletop).applying(CGAffineTransform(translationX: -standingDeskShift, y: 0))
        return path.union(deskPath)
    }

    /// Top of the floor line the standing figure and the desk stand on.
    static let floorLineTop: CGFloat = floor - 0.6

    /// Apple's upright figure with an arm reaching forward (from `figure.elliptical`), cut off
    /// at the hips and seated on bent legs, at a size that keeps its head close to the
    /// standing figure's.
    static func figureSeated() -> Path {
        let upper = SymbolOutline.figureEllipticalUpper
        let hips: CGFloat = -600
        var body = upper.path().subtracting(Path(CGRect(x: 0, y: hips, width: 3000, height: 3000)))
        let knee = CGPoint(x: 1250, y: hips + 40)
        body = body.union(capsule(from: CGPoint(x: 600, y: knee.y), to: knee, width: 220))
        body = body.union(capsule(from: knee, to: CGPoint(x: knee.x, y: 320), width: 210))
        let bounds = body.boundingRect
        let height: CGFloat = 13.0
        let scale = height / bounds.height
        let withChair = ProcessInfo.processInfo.environment["DESKPILOT_CHAIR"] == "1"
        let x0: CGFloat = withChair ? 2.0 : 1.2
        let figure = body.applying(
            // Placed so the hand rests on the tabletop's end.
            CGAffineTransform(translationX: x0 - bounds.minX * scale, y: floor - height - bounds.minY * scale)
                .scaledBy(x: scale, y: scale))
        guard withChair else { return figure }
        // Hip and knee in canvas units, for seating the chair under the thigh.
        let hipY = floor - height + (knee.y - bounds.minY) * scale
        let thighBottom = hipY + 110 * scale
        let backX = x0 + (445 - bounds.minX) * scale
        return figure.union(leapChair(backX: backX, seatTop: thighBottom, seatFront: x0 + (knee.x - bounds.minX) * scale - 0.3))
    }

    /// A Steelcase Leap seen from the side, as line work at the limbs' weight: the tall back
    /// with its lumbar curve leaning a little back, the seat with a waterfall front edge, the
    /// cylinder, and the base on two casters.
    static func leapChair(backX: CGFloat, seatTop: CGFloat, seatFront: CGFloat) -> Path {
        let stroke: CGFloat = 0.95
        var chair = Path()
        // Back: from behind the seat up past the shoulders, bowed for the lumbar.
        var back = Path()
        let backBottom = CGPoint(x: backX - 0.55, y: seatTop + 0.3)
        let backTop = CGPoint(x: backX - 1.1, y: seatTop - 7.2)
        back.move(to: backBottom)
        back.addCurve(to: backTop,
                      control1: CGPoint(x: backX - 1.45, y: seatTop - 2.2),
                      control2: CGPoint(x: backX - 0.75, y: seatTop - 5.2))
        chair = chair.union(back.strokedPath(StrokeStyle(lineWidth: stroke, lineCap: .round)))
        // Seat, rounded at the front.
        chair = chair.union(capsule(from: CGPoint(x: backX - 0.3, y: seatTop + stroke / 2),
                                    to: CGPoint(x: seatFront, y: seatTop + stroke / 2), width: stroke))
        // Cylinder and base.
        let cx = (backX + seatFront) / 2 - 0.2
        chair = chair.union(Path(CGRect(x: cx - 0.45, y: seatTop + stroke, width: 0.9, height: floor - 1.5 - (seatTop + stroke))))
        chair = chair.union(capsule(from: CGPoint(x: cx - 1.9, y: floor - 1.15), to: CGPoint(x: cx + 1.9, y: floor - 1.15), width: 0.8))
        for wx in [cx - 2.0, cx + 2.0] {
            chair = chair.union(Path(ellipseIn: CGRect(x: wx - 0.5, y: floor - 1.0, width: 1.0, height: 1.0)))
        }
        return chair
    }

    // MARK: - Where the person would be

    /// Three arcs like the left half of `dot.radiowaves.left.and.right`, sweeping out from the
    /// front edge of the tabletop across the empty spot.
    static func sensorWaves() -> Path {
        waves(center: CGPoint(x: 8.9, y: raisedTabletop + slab + 1.6), radii: [2.2, 4.4, 6.6], towards: .degrees(180))
    }

    /// An ellipsis where the person would be: the app is still connecting to the desk.
    static func radioBadge() -> Path {
        var path = Path()
        let radius: CGFloat = 1.0
        for x in [2.4, 4.9, 7.4] as [CGFloat] {
            path.addEllipse(in: CGRect(x: x - radius, y: 11.2 - radius, width: 2 * radius, height: 2 * radius))
        }
        return path
    }

    /// Three Z's drifting up from under the tabletop through the empty spot, growing as they
    /// rise and swaying like steam - low by the desk, out to the left, back over to the right
    /// at the top - rather than marching in a line. Round-capped bars a little lighter than
    /// the symbol stroke, so each Z stays open at menu bar size.
    static func sleepBadge() -> Path {
        func z(x: CGFloat, y: CGFloat, size: CGFloat, weight: CGFloat) -> Path {
            var letter = Path()
            letter.move(to: CGPoint(x: x, y: y))
            letter.addLine(to: CGPoint(x: x + size, y: y))
            letter.addLine(to: CGPoint(x: x, y: y + size))
            letter.addLine(to: CGPoint(x: x + size, y: y + size))
            return letter.strokedPath(StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
        }
        return union(z(x: 5.4, y: 12.6, size: 2.6, weight: stroke * 0.75),
                     z(x: 0.7, y: 7.2, size: 3.4, weight: stroke * 0.85),
                     z(x: 4.0, y: 1.0, size: 4.3, weight: stroke * 0.95))
    }

    /// Apple's `exclamationmark` proportions (stem 200, gap 267, dot 284 of 1901 tall), as
    /// tall as the standing figure's body.
    static func exclamationBadge() -> Path {
        let scale = 12.0 / 1901
        let x: CGFloat = 4.0
        let stem = 200 * scale
        let dot = 284 * scale
        var path = Path(roundedRect: CGRect(x: x - stem / 2, y: 3.0, width: stem, height: 1350 * scale),
                        cornerRadius: stem / 2)
        path.addEllipse(in: CGRect(x: x - dot / 2, y: 3.0 + (1901 - 284) * scale, width: dot, height: dot))
        return path
    }

    /// The floor under the standing glyph, spanning from behind the figure to the desk's foot.
    static func floorLine() -> Path {
        Path(roundedRect: CGRect(x: 0.3, y: floorLineTop, width: 19.4 - 0.3, height: floor - floorLineTop), cornerRadius: 0.3)
    }

    // MARK: - The desk

    static let slab: CGFloat = 1.1

    /// The standing desk seen from the side, like the figures: tabletop slab on a two-stage
    /// telescoping column (the upper stage extends as the desk rises), standing on a wide
    /// foot with sloped shoulders, and at the back a monitor. `tabletopTop` is where
    /// the slab starts - the desk is drawn raised or lowered.
    static func desk(tabletopTop: CGFloat) -> Path {
        let left: CGFloat = 8.6
        let right: CGFloat = 19.4
        var path = Path(roundedRect: CGRect(x: left, y: tabletopTop, width: right - left, height: slab),
                        cornerRadius: 0.3)
        // Foot: a low trapezoid, corners rounded by a round-joined stroke of itself.
        let footLeft: CGFloat = 10.2
        let footHeight: CGFloat = 1.6
        let shoulder: CGFloat = 0.9
        var foot = Path()
        foot.move(to: CGPoint(x: footLeft, y: floor))
        foot.addLine(to: CGPoint(x: right, y: floor))
        foot.addLine(to: CGPoint(x: right - shoulder, y: floor - footHeight))
        foot.addLine(to: CGPoint(x: footLeft + shoulder, y: floor - footHeight))
        foot.closeSubpath()
        // Shrink the trapezoid by `inset` on every side, then stroke it back out by `inset`
        // with round joins: same outline, rounded corners, bottom exactly on the floor - the
        // figures' feet are on that same line. (The shrink used to be off by the inset, so
        // the foot reached 0.4 below the floor and the people looked like they floated.)
        let inset: CGFloat = 0.35
        let scaleY = (footHeight - 2 * inset) / footHeight
        let footCore = foot.applying(CGAffineTransform(translationX: (footLeft + right) / 2, y: floor)
            .scaledBy(x: (right - footLeft - 2 * inset) / (right - footLeft), y: scaleY)
            .translatedBy(x: -(footLeft + right) / 2, y: -floor - inset / scaleY))
        path = path.union(footCore.union(footCore.strokedPath(StrokeStyle(lineWidth: 2 * inset, lineJoin: .round))))
        // Column in two stages: the lower stage is fixed; the upper, thinner one telescopes
        // out of it up to the tabletop.
        // Column: one straight bar from the tabletop into the foot, at the limbs' weight.
        let columnX = (footLeft + right) / 2
        let columnWidth: CGFloat = 1.5
        path = path.union(Path(CGRect(x: columnX - columnWidth / 2, y: tabletopTop + slab / 2, width: columnWidth,
                                      height: floor - footHeight / 2 - (tabletopTop + slab / 2))))
        path = path.union(monitor(panelBaseX: 13.9, tabletopTop: tabletopTop))
        return path
    }

    /// Monitor on the tabletop, edge-on the classic way: a panel leaning back, held by an
    /// angled strut down to the tabletop behind it. Shared by every glyph so the monitor is
    /// the same in all of them.
    static func monitor(panelBaseX: CGFloat, tabletopTop: CGFloat) -> Path {
        let panelBase = CGPoint(x: panelBaseX, y: tabletopTop - 1.1)
        let tilt: CGFloat = 15 * .pi / 180
        let panelHeight: CGFloat = 5.0
        let panel = Path(roundedRect: CGRect(x: -0.8, y: -panelHeight, width: 1.6, height: panelHeight), cornerRadius: 0.3)
            .applying(CGAffineTransform(translationX: panelBase.x, y: panelBase.y).rotated(by: tilt))
        let panelMid = CGPoint(x: panelBase.x + 2.5 * sin(tilt), y: panelBase.y - 2.5 * cos(tilt))
        return panel.union(capsule(from: panelMid, to: CGPoint(x: panelBaseX + 3.8, y: tabletopTop + 0.3), width: 1.1))
    }

    // MARK: - Drawing helpers

    /// A round-capped bar, the way a symbol's limbs and lines are drawn.
    static func capsule(from: CGPoint, to: CGPoint, width: CGFloat) -> Path {
        var line = Path()
        line.move(to: from)
        line.addLine(to: to)
        return line.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
    }

    /// Radio-wave arcs: 90 degree sweeps at the symbol stroke weight with round ends, fanning
    /// out in the `towards` direction.
    static func waves(center: CGPoint, radii: [CGFloat], towards: Angle) -> Path {
        var path = Path()
        for radius in radii {
            var arc = Path()
            arc.addArc(center: center, radius: radius, startAngle: towards - .degrees(45), endAngle: towards + .degrees(45), clockwise: false)
            path = path.union(arc.strokedPath(StrokeStyle(lineWidth: stroke, lineCap: .round)))
        }
        return path
    }

    static func union(_ paths: Path...) -> Path {
        paths.dropFirst().reduce(paths[0]) { $0.union($1) }
    }
}

public extension DeskGlyph {
    var shape: DeskGlyphShape { DeskGlyphShape(self) }

    /// Width of the design canvas, in the same units as its 18-unit height: a little wider
    /// than tall so the desk's foot can be as wide as a real one.
    var designWidth: CGFloat {
        switch self {
        case .standing: return 20 - DeskGlyphShape.standingDeskShift
        case .unreachable: return 20 - DeskGlyphShape.unreachableTrim
        default: return 20
        }
    }

    /// Width divided by height of the design canvas, for sizing frames that hold the glyph.
    var aspectRatio: CGFloat {
        designWidth / DeskGlyphShape.designHeight
    }
}

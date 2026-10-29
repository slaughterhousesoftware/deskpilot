import SwiftUI

/// Figures lifted from Apple's own SF Symbols drawings (SF Pro, Regular weight, medium scale),
/// so the people in the desk glyphs are drawn exactly the way Apple draws them. Each outline
/// is the glyph's path in font units (2048 per em) with y pointing down, plus its bounding box.
enum SymbolOutline {
    /// `figure.stand`.
    static let figureStand = Outline(
        bounds: CGRect(x: 255, y: -1620, width: 848, height: 2003),
        d: "M678 -1228 C788 -1228 875 -1315 875 -1424 C875 -1533 788 -1620 678 -1620 C570 -1620 483 -1533 483 -1424 C483 -1315 570 -1228 678 -1228 Z M561 383 C610 383 648 345 648 296 L648 -343 C648 -358 663 -373 678 -373 C695 -373 709 -358 709 -343 L709 296 C709 345 748 383 797 383 C845 383 885 345 885 296 L885 -753 C885 -770 898 -782 914 -782 C930 -782 943 -770 943 -753 L943 -407 C943 -362 978 -326 1023 -326 C1067 -326 1103 -362 1103 -407 L1103 -793 C1103 -994 957 -1125 744 -1125 L613 -1125 C400 -1125 255 -994 255 -793 L255 -407 C255 -362 291 -326 335 -326 C379 -326 414 -362 414 -407 L414 -753 C414 -770 427 -782 444 -782 C460 -782 473 -770 473 -753 L473 296 C473 345 512 383 561 383 Z")

    /// The person from `figure.roll` (head, forward-leaning torso, reaching arm, thigh),
    /// mirrored to face right and given a shin down to the floor where the wheel was: an
    /// upright seated figure, drawn the way Apple draws one.
    static let figureSeated = Outline(
        bounds: CGRect(x: 241, y: -1815, width: 1522, height: 2195),
        d: "M600 -1380 C479 -1380 382 -1477 382 -1598 C382 -1718 479 -1815 600 -1815 C721 -1815 818 -1718 818 -1598 C818 -1477 721 -1380 600 -1380 Z M241 -347 C241 -576 350 -710 554 -710 L688 -710 C711 -710 726 -725 717 -753 L625 -1032 C583 -1160 643 -1276 785 -1312 L1198 -1416 C1238 -1426 1268 -1419 1304 -1398 L1705 -1172 C1752 -1145 1763 -1076 1730 -1032 C1698 -987 1641 -979 1590 -1005 L1222 -1200 L1007 -1143 C965 -1131 949 -1102 963 -1063 L1076 -746 C1128 -597 1040 -470 896 -470 L524 -470 C447 -470 441 -424 441 -347 L441 280 C441 335 396 380 341 380 C286 380 241 335 241 280 L241 -347 Z")

    /// Head, torso and forward-reaching arm of `figure.elliptical` (the standing leg is still
    /// attached; the seated glyph cuts it off at the hips and adds bent legs).
    static let figureEllipticalUpper = Outline(
        bounds: CGRect(x: 415, y: -1938, width: 1230, height: 2048),
        d: "M757 -1501 C877 -1501 976 -1600 976 -1720 C976 -1839 877 -1938 757 -1938 C637 -1938 539 -1839 539 -1720 C539 -1600 637 -1501 757 -1501 Z M1277 86 C1319 66 1346 17 1319 -51 L1143 -492 C1138 -506 1128 -517 1106 -533 L784 -771 L808 -1126 C809 -1146 824 -1152 843 -1146 L1052 -1075 C1072 -1069 1097 -1066 1119 -1069 L1507 -1112 C1645 -1128 1620 -1329 1484 -1314 L1108 -1271 L725 -1398 C585 -1445 464 -1366 452 -1226 L424 -876 C415 -771 470 -669 560 -617 L969 -380 L1131 24 C1159 95 1229 110 1277 86 Z")

    /// Regular-weight stroke width of SF Symbols, in font units, for drawing the parts that
    /// go with the figures at the same weight.
    static let strokeWidth: CGFloat = 161

    struct Outline: Sendable {
        let bounds: CGRect
        let d: String

        /// Adds the outline to `path`, scaled so its bounding box is `height` tall and placed
        /// with the box's top-left corner at `topLeft` (in the caller's coordinates).
        func add(to path: inout Path, height: CGFloat, topLeft: CGPoint) {
            let scale = height / bounds.height
            path.addPath(self.path().applying(
                CGAffineTransform(translationX: topLeft.x - bounds.minX * scale, y: topLeft.y - bounds.minY * scale)
                    .scaledBy(x: scale, y: scale)))
        }

        /// The outline in font units (y down).
        func path() -> Path {
            // Tokens are "M678", "-1228", "C788", ... - a command letter glued to its first number.
            var numbers: [Double] = []
            var command: Character = "M"
            var sub = Path()
            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
            func flush() {
                switch command {
                case "M": sub.move(to: point(numbers[0], numbers[1]))
                case "L": sub.addLine(to: point(numbers[0], numbers[1]))
                case "C": sub.addCurve(to: point(numbers[4], numbers[5]),
                                       control1: point(numbers[0], numbers[1]),
                                       control2: point(numbers[2], numbers[3]))
                case "Z": sub.closeSubpath()
                default: preconditionFailure("unknown path command \(command)")
                }
                numbers.removeAll()
            }
            for token in d.split(separator: " ") {
                if let first = token.first, first.isLetter {
                    if !numbers.isEmpty || command == "Z" { flush() }
                    command = first
                    if token.count > 1 { numbers.append(Double(token.dropFirst())!) }
                    if command == "Z" { flush() }
                } else {
                    numbers.append(Double(token)!)
                }
            }
            if !numbers.isEmpty { flush() }
            return sub
        }

        /// Width of the outline when drawn `height` tall.
        func width(forHeight height: CGFloat) -> CGFloat {
            bounds.width * height / bounds.height
        }
    }
}

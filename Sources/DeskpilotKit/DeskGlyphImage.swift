#if canImport(AppKit)
import SwiftUI
import AppKit

public extension DeskGlyph {
    /// Renders the glyph as a template `NSImage` sized for the menu bar (or any other AppKit
    /// spot that wants a black-filled, tint-aware image instead of the SwiftUI `Shape`).
    /// Cached per glyph/size so repeated menu bar redraws don't re-render.
    @MainActor
    /// `verticalOffset` nudges the drawing inside its box (negative = up), because the glyph
    /// design has more empty space above the figure than below and would otherwise sit low
    /// when AppKit centres the image's frame in a menu bar row.
    func templateImage(pointSize: CGFloat = 18, verticalOffset: CGFloat = 0) -> NSImage {
        let key = DeskGlyphImageCache.Key(glyph: self, pointSize: pointSize, verticalOffset: verticalOffset)
        if let cached = DeskGlyphImageCache.storage[key] {
            return cached
        }

        // `pointSize` is the height; the width follows the glyph's canvas (wider for the handset).
        let width = (pointSize * aspectRatio).rounded()
        let renderer = ImageRenderer(content: shape.fill(.black)
            .frame(width: width, height: pointSize)
            .offset(y: verticalOffset)
            .frame(width: width, height: pointSize)
            .clipped())
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: CGSize(width: width, height: pointSize))
        image.isTemplate = true
        image.size = CGSize(width: width, height: pointSize)

        DeskGlyphImageCache.storage[key] = image
        return image
    }
}

@MainActor
private enum DeskGlyphImageCache {
    struct Key: Hashable {
        let glyph: DeskGlyph
        let pointSize: CGFloat
        let verticalOffset: CGFloat
    }

    static var storage: [Key: NSImage] = [:]
}
#endif

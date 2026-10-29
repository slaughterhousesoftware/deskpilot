#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
@testable import DeskpilotKit

@MainActor
final class DeskGlyphTests: XCTestCase {
    private static let outputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tempo-glyphs")

    override class func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        print("glyph previews: \(outputDirectory.path)")
    }

    func testRendersEveryGlyph() throws {
        for glyph in DeskGlyph.allCases {
            try render(glyph, pointSize: 96, fileName: "\(glyph).png")
            try renderTemplate(glyph, fileName: "\(glyph)-18.png")
        }
    }

    /// Renders the raw `DeskGlyphShape` at `pointSize` (scale 2) and writes it to `fileName`
    /// under the scratch output directory, asserting the PNG is non-empty and has some
    /// non-transparent (i.e. actually drawn) pixels.
    private func render(_ glyph: DeskGlyph, pointSize: CGFloat, fileName: String) throws {
        let renderer = ImageRenderer(
            content: glyph.shape.fill(.black).frame(width: pointSize * glyph.aspectRatio, height: pointSize)
        )
        renderer.scale = 2

        let nsImage = try XCTUnwrap(renderer.nsImage, "ImageRenderer produced no NSImage for \(glyph)")
        let url = Self.outputDirectory.appendingPathComponent(fileName)
        let data = try writePNG(nsImage, to: url)

        XCTAssertFalse(data.isEmpty, "\(fileName) should not be empty")
        XCTAssertFalse(url.path.isEmpty)
        XCTAssertTrue(hasNonTransparentPixels(nsImage), "\(fileName) should have visible (non-transparent) pixels")
    }

    /// Exercises the production `templateImage()` path at 18pt (menu bar size, @2x) and writes
    /// it to `fileName`, with the same non-empty / non-transparent assertions.
    private func renderTemplate(_ glyph: DeskGlyph, fileName: String) throws {
        let nsImage = glyph.templateImage(pointSize: 18)
        let url = Self.outputDirectory.appendingPathComponent(fileName)
        let data = try writePNG(nsImage, to: url)

        XCTAssertFalse(data.isEmpty, "\(fileName) should not be empty")
        XCTAssertFalse(url.path.isEmpty)
        XCTAssertTrue(hasNonTransparentPixels(nsImage), "\(fileName) should have visible (non-transparent) pixels")
    }

    @discardableResult
    private func writePNG(_ image: NSImage, to url: URL) throws -> Data {
        let bitmap = try XCTUnwrap(bitmapRep(for: image), "no bitmap representation for \(url.lastPathComponent)")
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]),
                                  "failed to encode PNG for \(url.lastPathComponent)")
        try data.write(to: url)
        return data
    }

    private func hasNonTransparentPixels(_ image: NSImage) -> Bool {
        guard let bitmap = bitmapRep(for: image) else { return false }
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else { return false }

        var x = 0
        while x < width {
            var y = 0
            while y < height {
                if bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.05 {
                    return true
                }
                y += max(1, height / 32)
            }
            x += max(1, width / 32)
        }
        return false
    }

    private func bitmapRep(for image: NSImage) -> NSBitmapImageRep? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }
}
#endif

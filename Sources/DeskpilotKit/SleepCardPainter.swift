import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Draws a posture timeline the way the Health app's sleep card draws the night. The
/// proportions were measured from reference screenshots; in units of
/// the block height H:
///
/// - blocks with 0.16 H corners;
/// - a halo in the block's colour: 0.105 H on an edge facing another lane, 0.07 H on an outer
///   edge and the sides; blocks in a lane closer than 0.16 H share one halo;
/// - at every transition a neck 0.15 H wide centred on the transition, running the height of
///   both blocks to their halos' corners, a gradient between the two colours;
/// - each transition (its two halos plus its neck) morphologically closed with radius 0.21 H,
///   capped on each side of the neck at half the gap to the nearest neck on the same lane edge,
///   so two necks under one block meet as a round-topped slot instead of crossing;
/// - the pale layer drawn supersampled, softened, and composited once at a tint.
public struct SleepCardMetrics: Equatable {
    public var haloIn: CGFloat
    public var haloOut: CGFloat
    public var neck: CGFloat
    public var closing: CGFloat
    public var radius: CGFloat
    public var merge: CGFloat
    public var soft: CGFloat
    public var supersample: CGFloat
    public var minimumBlockWidth: CGFloat

    public init(haloIn: CGFloat, haloOut: CGFloat, neck: CGFloat, closing: CGFloat, radius: CGFloat, merge: CGFloat,
                soft: CGFloat, supersample: CGFloat = 2, minimumBlockWidth: CGFloat = 2) {
        self.haloIn = haloIn; self.haloOut = haloOut; self.neck = neck; self.closing = closing; self.radius = radius
        self.merge = merge; self.soft = soft; self.supersample = supersample; self.minimumBlockWidth = minimumBlockWidth
    }

    /// Apple's proportions for a block `h` points tall.
    public static func forBlockHeight(_ h: CGFloat) -> SleepCardMetrics {
        SleepCardMetrics(haloIn: 0.105 * h, haloOut: 0.07 * h, neck: 0.15 * h, closing: 0.21 * h, radius: 0.16 * h,
                         merge: 0.16 * h, soft: 0.008 * h)
    }
}

/// A block on the timeline: its frame in the drawing's coordinates, which lane it is on
/// (0 the uppermost, counting down) and its colour.
public struct SleepCardBlock: Equatable {
    public var rect: CGRect
    public var lane: Int
    public var color: NSColor
    public init(rect: CGRect, lane: Int, color: NSColor) { self.rect = rect; self.lane = lane; self.color = color }
}

/// A transition between two blocks on different lanes, at `x`.
public struct SleepCardJunction: Equatable {
    public var a: Int
    public var b: Int
    public var x: CGFloat
    public init(a: Int, b: Int, x: CGFloat) { self.a = a; self.b = b; self.x = x }
}

public enum SleepCardPainter {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let ciContext = CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace])
    /// Built pale layers, least recently used first, and the keys being built in the background.
    /// Guarded by `lock`: layers are built off the main thread (see `drawWhenReady`).
    nonisolated(unsafe) private static var cache: [(key: String, image: CGImage)] = []
    /// For each key being built, who to tell when it's done (a chart waiting to draw it in).
    nonisolated(unsafe) private static var building: [String: [@MainActor () -> Void]] = [:]
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "com.kevinpatel.tempo.sleepcard", qos: .userInitiated)
    /// Room for a week of days either side of the one shown, flicked through and prepared ahead.
    private static let cacheLimit = 40

    /// Draws the pale layer at `tint` and the solid blocks on top, building the pale layer here
    /// if it isn't ready (a few tens of milliseconds; the menu's single strip draws this way).
    @MainActor
    public static func draw(in context: inout GraphicsContext, size: CGSize, scale: CGFloat, blocks: [SleepCardBlock],
                            junctions: [SleepCardJunction], metrics: SleepCardMetrics, tint: Double) {
        let pale = paleLayer(size: size, scale: scale, blocks: blocks, junctions: junctions, metrics: metrics)
        composite(in: &context, size: size, scale: scale, pale: pale, blocks: blocks, metrics: metrics, tint: tint)
    }

    /// Draws the blocks now and the pale layer once it's built, never building it on the main
    /// thread: on a miss it's built in the background and `onReady` runs (on the main thread)
    /// to redraw. For charts that scroll through days, where a build per new day would drop
    /// frames.
    @MainActor
    public static func drawWhenReady(in context: inout GraphicsContext, size: CGSize, scale: CGFloat, blocks: [SleepCardBlock],
                                     junctions: [SleepCardJunction], metrics: SleepCardMetrics, tint: Double,
                                     onReady: @escaping @MainActor () -> Void) {
        let key = cacheKey(size: size, scale: scale, blocks: blocks, junctions: junctions, metrics: metrics)
        let pale = cached(key)
        if pale == nil { prepare(key: key, size: size, scale: scale, blocks: blocks, junctions: junctions, metrics: metrics, onReady: onReady) }
        composite(in: &context, size: size, scale: scale, pale: pale, blocks: blocks, metrics: metrics, tint: tint)
    }

    /// Builds a pale layer in the background ahead of its first draw (days either side of the
    /// one shown), unless it's built or being built.
    public static func prepare(size: CGSize, scale: CGFloat, blocks: [SleepCardBlock], junctions: [SleepCardJunction],
                               metrics: SleepCardMetrics) {
        let key = cacheKey(size: size, scale: scale, blocks: blocks, junctions: junctions, metrics: metrics)
        guard cached(key) == nil else { return }
        prepare(key: key, size: size, scale: scale, blocks: blocks, junctions: junctions, metrics: metrics, onReady: nil)
    }

    private static func prepare(key: String, size: CGSize, scale: CGFloat, blocks: [SleepCardBlock], junctions: [SleepCardJunction],
                                metrics: SleepCardMetrics, onReady: (@MainActor () -> Void)?) {
        // Already being built (say, ahead of a scroll): just join the ones waiting for it.
        lock.lock()
        let started = building[key] == nil
        building[key, default: []].append(contentsOf: onReady.map { [$0] } ?? [])
        lock.unlock()
        guard started else { return }
        nonisolated(unsafe) let blocks = blocks
        queue.async {
            let image = render(size: size, scale: scale, blocks: blocks, junctions: junctions, m: metrics)
            lock.lock()
            nonisolated(unsafe) let waiting = building.removeValue(forKey: key) ?? []
            if let image { store(key, image) }
            lock.unlock()
            guard !waiting.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { waiting.forEach { $0() } } }
        }
    }

    @MainActor
    private static func composite(in context: inout GraphicsContext, size: CGSize, scale: CGFloat, pale: CGImage?,
                                  blocks: [SleepCardBlock], metrics: SleepCardMetrics, tint: Double) {
        if let pale {
            var layer = context
            layer.opacity = tint
            layer.draw(Image(decorative: pale, scale: scale), in: CGRect(origin: .zero, size: size))
        }
        for b in blocks {
            let r = min(metrics.radius, b.rect.width / 2, b.rect.height / 2)
            context.fill(Path(roundedRect: b.rect, cornerRadius: r), with: .color(Color(nsColor: b.color)))
        }
    }

    private static func cacheKey(size: CGSize, scale: CGFloat, blocks: [SleepCardBlock], junctions: [SleepCardJunction],
                                 metrics: SleepCardMetrics) -> String {
        "\(size) \(scale) \(metrics) " + blocks.map { "\($0.rect) \($0.lane) \($0.color)" }.joined(separator: ";")
            + junctions.map { "\($0.a),\($0.b),\($0.x)" }.joined(separator: ";")
    }

    /// A built layer, marked most recently used.
    private static func cached(_ key: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let index = cache.firstIndex(where: { $0.key == key }) else { return nil }
        let hit = cache.remove(at: index)
        cache.append(hit)
        return hit.image
    }

    /// Call with `lock` held.
    private static func store(_ key: String, _ image: CGImage) {
        cache.removeAll { $0.key == key }
        cache.append((key, image))
        if cache.count > cacheLimit { cache.removeFirst(cache.count - cacheLimit) }
    }

    /// The halos and necks as one opaque bitmap at the display scale, built here on a miss.
    public static func paleLayer(size: CGSize, scale: CGFloat, blocks: [SleepCardBlock], junctions: [SleepCardJunction],
                                 metrics: SleepCardMetrics) -> CGImage? {
        let key = cacheKey(size: size, scale: scale, blocks: blocks, junctions: junctions, metrics: metrics)
        if let hit = cached(key) { return hit }
        guard let image = render(size: size, scale: scale, blocks: blocks, junctions: junctions, m: metrics) else { return nil }
        lock.lock()
        store(key, image)
        lock.unlock()
        return image
    }

    private static func render(size: CGSize, scale: CGFloat, blocks: [SleepCardBlock], junctions: [SleepCardJunction],
                               m: SleepCardMetrics) -> CGImage? {
        let k = scale * m.supersample
        let width = Int((size.width * k).rounded(.up)), height = Int((size.height * k).rounded(.up))
        guard width > 0, height > 0, !blocks.isEmpty else { return nil }
        func makeContext(_ box: CGRect) -> CGContext? {
            let w = Int((box.width * k).rounded(.up)), h = Int((box.height * k).rounded(.up))
            guard w > 0, h > 0, let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            c.translateBy(x: 0, y: CGFloat(h))
            c.scaleBy(x: k, y: -k)                       // top-left origin, in points
            c.translateBy(x: -box.minX, y: -box.minY)
            return c
        }
        // Blocks in a lane closer than `merge` share one halo.
        var span = blocks.map { $0.rect }
        // At least two lanes, so a day on one lane draws as it always has.
        let lastLane = max(1, blocks.map(\.lane).max() ?? 0)
        for lane in 0...lastLane {
            let idx = blocks.indices.filter { blocks[$0].lane == lane }.sorted { blocks[$0].rect.minX < blocks[$1].rect.minX }
            var group: [Int] = []
            func flush() {
                let r = group.reduce(CGRect.null) { $0.union(blocks[$1].rect) }
                for i in group { span[i] = r }
                group.removeAll()
            }
            for i in idx {
                if let last = group.last, blocks[i].rect.minX - blocks[last].rect.maxX >= m.merge { flush() }
                group.append(i)
            }
            if !group.isEmpty { flush() }
        }
        func haloRect(_ i: Int) -> CGRect {
            let r = span[i]
            // The wider halo on each edge that faces another lane: the top lane's lower edge,
            // the bottom lane's upper edge, and both edges of any lane between.
            let lane = blocks[i].lane
            let top = lane == 0 ? m.haloOut : m.haloIn, bottom = lane == lastLane ? m.haloOut : m.haloIn
            return CGRect(x: r.minX - m.haloOut, y: r.minY - top, width: r.width + 2 * m.haloOut, height: r.height + top + bottom)
        }
        func drawHalo(_ c: CGContext, _ i: Int) {
            let r = haloRect(i), corner = min(m.radius + m.haloOut, r.width / 2, r.height / 2)
            c.setFillColor(blocks[i].color.cgColor)
            c.addPath(CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil))
            c.fillPath()
        }
        func ends(_ j: SleepCardJunction) -> (upper: Int, lower: Int) { blocks[j.a].lane < blocks[j.b].lane ? (j.a, j.b) : (j.b, j.a) }
        func cornerStart(_ i: Int) -> CGFloat { min(m.radius + m.haloOut, haloRect(i).width / 2) }
        func drawNeck(_ c: CGContext, _ j: SleepCardJunction) {
            let (upper, lower) = ends(j)
            // the height of both blocks, stopping where each halo's corner begins
            let top = min(blocks[upper].rect.minY + cornerStart(upper), blocks[upper].rect.maxY)
            let bottom = max(blocks[lower].rect.maxY - cornerStart(lower), blocks[lower].rect.minY)
            let rect = CGRect(x: j.x - m.neck / 2, y: top, width: m.neck, height: bottom - top)
            guard rect.height > 0,
                  let gradient = CGGradient(colorsSpace: colorSpace, colors: [blocks[upper].color.cgColor, blocks[lower].color.cgColor] as CFArray,
                                            locations: [0, 1]) else { return }
            c.saveGState()
            c.clip(to: rect)
            c.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: blocks[upper].rect.maxY),
                                 end: CGPoint(x: rect.midX, y: blocks[lower].rect.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            c.restoreGState()
        }
        /// The closing radius on one side of a junction's neck at one of its blocks: capped at
        /// half the gap to the nearest neck meeting the same lane edge on that side.
        func sideRadius(_ j: SleepCardJunction, upperEnd: Bool, left: Bool) -> CGFloat {
            let lane = blocks[upperEnd ? ends(j).upper : ends(j).lower].lane
            var r = m.closing
            for other in junctions where other.x != j.x {
                let o = ends(other)
                guard blocks[upperEnd ? o.upper : o.lower].lane == lane else { continue }
                let dx = other.x - j.x
                if left ? dx < 0 : dx > 0 { r = min(r, max(0, (abs(dx) - m.neck) / 2)) }
            }
            return r
        }
        let joined = Set(junctions.flatMap { [$0.a, $0.b] })
        guard let layer = makeContext(CGRect(origin: .zero, size: size)) else { return nil }
        for i in blocks.indices where !joined.contains(i) { drawHalo(layer, i) }
        for j in junctions {
            let (upper, lower) = ends(j)
            let pad = m.closing + 2
            let box = haloRect(j.a).union(haloRect(j.b)).insetBy(dx: -pad, dy: -pad).integral
            guard let c = makeContext(box) else { continue }
            drawHalo(c, j.a); drawHalo(c, j.b); drawNeck(c, j)
            let w = c.width, h = c.height
            guard let out = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            // Each quarter around the neck (side x end) closed with its own radius; the cuts
            // fall where no flare reaches (the neck's middle) and inside the neck (its centre).
            let cx = ((j.x - box.minX) * k).rounded()
            let middle = CGFloat(h) - ((blocks[upper].rect.maxY + blocks[lower].rect.minY) / 2 - box.minY) * k
            var closedByRadius: [Int: CGImage] = [:]
            for (left, top) in [(true, true), (false, true), (true, false), (false, false)] {
                let r = sideRadius(j, upperEnd: top, left: left) * k
                let key = Int((r * 8).rounded())
                if closedByRadius[key] == nil { closedByRadius[key] = ExactClosing.close(context: c, radius: r) }
                guard let image = closedByRadius[key] else { continue }
                let x0 = left ? 0 : cx, x1 = left ? cx : CGFloat(w)
                let y0 = top ? middle : 0, y1 = top ? CGFloat(h) : middle
                out.saveGState()
                out.clip(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
                out.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                out.restoreGState()
            }
            guard let piece = out.makeImage() else { continue }
            layer.saveGState()
            layer.concatenate(layer.ctm.inverted())
            layer.draw(piece, in: CGRect(x: box.minX * k, y: CGFloat(height) - box.maxY * k, width: CGFloat(w), height: CGFloat(h)))
            layer.restoreGState()
        }
        guard let big = layer.makeImage() else { return nil }
        var result = CIImage(cgImage: big)
        if m.soft > 0 {
            let blur = CIFilter.gaussianBlur(); blur.inputImage = result; blur.radius = Float(m.soft * k)
            result = blur.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)) ?? result
        }
        guard let softened = ciContext.createCGImage(result, from: CGRect(x: 0, y: 0, width: width, height: height)) else { return nil }
        let tw = Int((size.width * scale).rounded(.up)), th = Int((size.height * scale).rounded(.up))
        guard let small = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        small.interpolationQuality = .high
        small.draw(softened, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return small.makeImage()
    }
}

/// Exact Euclidean morphological closing of an RGBA8 (premultiplied) bitmap's coverage, with
/// anti-aliased edges from the distance field and fillet pixels coloured from the nearest
/// original pixel. Core Image's morphology filters are neither circular nor reliable at large
/// radii, which showed as facets, steps and missing flares.
enum ExactClosing {
    /// 1-D squared distance transform (Felzenszwalb & Huttenlocher) that also returns the
    /// index of the minimising source.
    @_optimize(speed)
    private static func transform1D(_ f: UnsafeMutablePointer<Float>, _ src: UnsafeMutablePointer<Int32>, _ n: Int,
                                    d: UnsafeMutablePointer<Float>, arg: UnsafeMutablePointer<Int32>,
                                    v: UnsafeMutablePointer<Int>, z: UnsafeMutablePointer<Float>) {
        var k = 0
        v[0] = 0; z[0] = -Float.greatestFiniteMagnitude; z[1] = Float.greatestFiniteMagnitude
        for q in 1..<n {
            var s: Float
            while true {
                let vk = v[k]
                s = ((f[q] + Float(q * q)) - (f[vk] + Float(vk * vk))) / Float(2 * (q - vk))
                if s <= z[k] && k > 0 { k -= 1 } else { break }
            }
            if s <= z[k] { // k == 0 and the new parabola dominates
                v[0] = q; z[0] = -Float.greatestFiniteMagnitude; z[1] = Float.greatestFiniteMagnitude; k = 0
            } else {
                k += 1; v[k] = q; z[k] = s; z[k + 1] = Float.greatestFiniteMagnitude
            }
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Float(q) { k += 1 }
            let vk = v[k]
            d[q] = Float((q - vk) * (q - vk)) + f[vk]
            arg[q] = src[vk]
        }
    }

    /// Squared Euclidean distance from every pixel to the nearest pixel where `inside` is true,
    /// and that pixel's index. Pixels inside get 0 and themselves.
    @_optimize(speed)
    static func distanceTransform(inside: [Bool], width w: Int, height h: Int) -> (dist2: [Float], nearest: [Int32]) {
        let inf: Float = 1e12
        var f = [Float](repeating: inf, count: w * h)
        var src = [Int32](repeating: -1, count: w * h)
        for i in 0..<(w * h) where inside[i] { f[i] = 0; src[i] = Int32(i) }
        let n = max(w, h)
        var d = [Float](repeating: 0, count: w * h), arg = [Int32](repeating: -1, count: w * h)
        var fRow = [Float](repeating: 0, count: n), sRow = [Int32](repeating: 0, count: n)
        var dRow = [Float](repeating: 0, count: n), aRow = [Int32](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n + 1), z = [Float](repeating: 0, count: n + 2)
        // rows: for a pixel with no source in its row, f stays inf and the column pass sees inf
        for y in 0..<h {
            var any = false
            for x in 0..<w { fRow[x] = f[y * w + x]; sRow[x] = src[y * w + x]; if fRow[x] == 0 { any = true } }
            if !any { for x in 0..<w { d[y * w + x] = inf; arg[y * w + x] = -1 }; continue }
            fRow.withUnsafeMutableBufferPointer { fp in sRow.withUnsafeMutableBufferPointer { sp in
            dRow.withUnsafeMutableBufferPointer { dp in aRow.withUnsafeMutableBufferPointer { ap in
            v.withUnsafeMutableBufferPointer { vp in z.withUnsafeMutableBufferPointer { zp in
                transform1D(fp.baseAddress!, sp.baseAddress!, w, d: dp.baseAddress!, arg: ap.baseAddress!, v: vp.baseAddress!, z: zp.baseAddress!)
            } } } } } }
            for x in 0..<w { d[y * w + x] = dRow[x]; arg[y * w + x] = aRow[x] }
        }
        var out = [Float](repeating: inf, count: w * h), near = [Int32](repeating: -1, count: w * h)
        for x in 0..<w {
            var any = false
            for y in 0..<h { fRow[y] = d[y * w + x]; sRow[y] = arg[y * w + x]; if fRow[y] < inf { any = true } }
            if !any { continue }
            fRow.withUnsafeMutableBufferPointer { fp in sRow.withUnsafeMutableBufferPointer { sp in
            dRow.withUnsafeMutableBufferPointer { dp in aRow.withUnsafeMutableBufferPointer { ap in
            v.withUnsafeMutableBufferPointer { vp in z.withUnsafeMutableBufferPointer { zp in
                transform1D(fp.baseAddress!, sp.baseAddress!, h, d: dp.baseAddress!, arg: ap.baseAddress!, v: vp.baseAddress!, z: zp.baseAddress!)
            } } } } } }
            for y in 0..<h { out[y * w + x] = dRow[y]; near[y * w + x] = aRow[y] }
        }
        return (out, near)
    }

    /// The closing of the bitmap's coverage by a disc of radius `r` (pixels), as a new bitmap.
    /// `rgba` is premultiplied RGBA8, row-major, `bytesPerRow` may pad.
    @_optimize(speed)
    static func close(rgba: UnsafePointer<UInt8>, width w: Int, height h: Int, bytesPerRow: Int, radius r: Float) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        var inside = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w { inside[y * w + x] = rgba[y * bytesPerRow + x * 4 + 3] >= 128 } }
        if r < 0.25 {
            for y in 0..<h { for x in 0..<w { for c in 0..<4 { out[(y * w + x) * 4 + c] = rgba[y * bytesPerRow + x * 4 + c] } } }
            return out
        }
        let (d1, near) = distanceTransform(inside: inside, width: w, height: h)
        let r2 = r * r
        var dilated = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { dilated[i] = d1[i] <= r2 }
        var outsideDilated = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { outsideDilated[i] = !dilated[i] }
        let (d2, _) = distanceTransform(inside: outsideDilated, width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                // Outside the dilated set can't be in the closing. (Below half a pixel the
                // anti-aliasing term alone left every such pixel a sliver of coverage, which
                // filled a transition's whole working box with a faint rectangle.)
                guard dilated[i] else { continue }
                let dist = d2[i].squareRoot()
                let coverage = min(max(dist - r + 0.5, 0), 1)    // eroded set, anti-aliased at its edge
                guard coverage > 0 else { continue }
                let source = inside[i] ? i : Int(near[i])
                guard source >= 0 else { continue }
                let sy = source / w, sx = source % w
                let p = sy * bytesPerRow + sx * 4
                let a = Float(rgba[p + 3])
                guard a > 0 else { continue }
                let scale = coverage * 255 / a
                out[i * 4 + 0] = UInt8(min(255, Float(rgba[p + 0]) * scale))
                out[i * 4 + 1] = UInt8(min(255, Float(rgba[p + 1]) * scale))
                out[i * 4 + 2] = UInt8(min(255, Float(rgba[p + 2]) * scale))
                out[i * 4 + 3] = UInt8(coverage * 255)
            }
        }
        return out
    }

    /// Closing of a CGContext's contents (premultipliedLast RGBA8), returned as a CGImage.
    static func close(context c: CGContext, radius: CGFloat) -> CGImage? {
        guard let data = c.data else { return nil }
        let w = c.width, h = c.height
        var bytes = close(rgba: data.assumingMemoryBound(to: UInt8.self), width: w, height: h, bytesPerRow: c.bytesPerRow, radius: Float(radius))
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        return bytes.withUnsafeMutableBytes { buf -> CGImage? in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }
}


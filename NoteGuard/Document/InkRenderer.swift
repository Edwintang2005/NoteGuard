import UIKit
import PencilKit

/// Draws PencilKit ink into Core Graphics as vector paths, so saved PDFs stay sharp at any zoom and
/// stay small. Textured inks (pencil, crayon, watercolour) have no vector equivalent; those strokes
/// are drawn as high-resolution images, one stroke at a time so layering order is preserved.
nonisolated enum InkRenderer {
    /// Draws `drawing` into `context`, whose coordinate space must match the drawing's
    /// (top-left origin, y pointing down, 1 unit = 1 point).
    static func draw(_ drawing: PKDrawing, in context: CGContext, rasterScale: CGFloat = 4) {
        for stroke in drawing.strokes {
            if isVector(stroke.ink.inkType) {
                drawVector(stroke, in: context)
            } else {
                drawRaster(stroke, in: context, scale: rasterScale)
            }
        }
    }

    /// Inks whose look is a solid, untextured fill.
    static func isVector(_ type: PKInk.InkType) -> Bool {
        switch type {
        case .pen, .monoline, .fountainPen, .marker: true
        default: false
        }
    }

    /// Markers are see-through and darken what's under them, like a highlighter.
    private static let markerOpacity: CGFloat = 0.55
    /// Within one stroke, consecutive samples whose widths stay within this ratio share one path.
    private static let widthTolerance: CGFloat = 0.12

    private static func drawVector(_ stroke: PKStroke, in context: CGContext) {
        let samples = Array(stroke.path.interpolatedPoints(by: .distance(1)))
        guard let first = samples.first else { return }

        let ink = stroke.ink
        let resolved = ink.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var alpha = resolved.cgColor.alpha
        let isMarker = ink.inkType == .marker
        if isMarker { alpha *= markerOpacity }
        let averageOpacity = samples.reduce(CGFloat(0)) { $0 + $1.opacity } / CGFloat(samples.count)
        alpha *= max(0, min(averageOpacity, 1))
        let opaque = resolved.withAlphaComponent(1).cgColor

        context.saveGState()
        context.concatenate(stroke.transform)
        if let mask = stroke.mask {
            context.addPath(mask.cgPath)
            context.clip()
        }
        if isMarker { context.setBlendMode(.multiply) }
        context.setAlpha(alpha)
        // A transparency group makes overlapping parts of one stroke blend once, not twice.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setStrokeColor(opaque)
        context.setFillColor(opaque)
        context.setLineCap(isMarker ? .square : .round)
        context.setLineJoin(.round)

        // PencilKit's rendered thickness isn't the points' nominal size (pens thin out when narrow and
        // swell when wide), so calibrate against PencilKit itself.
        let scale = widthScale(for: stroke, sample: samples[samples.count / 2])
        func width(of point: PKStrokePoint) -> CGFloat { max(point.size.width * scale, 0.3) }

        if samples.count == 1 {
            let d = width(of: first)
            context.fillEllipse(in: CGRect(x: first.location.x - d / 2, y: first.location.y - d / 2, width: d, height: d))
        } else {
            // Split into runs of near-constant width and stroke each run as one path. Runs overlap by
            // one sample so they join without gaps.
            var runStart = 0
            var runSum = width(of: first)
            for i in 1..<samples.count {
                let w = width(of: samples[i])
                let mean = runSum / CGFloat(i - runStart)
                if abs(w - mean) / max(mean, 0.1) > widthTolerance {
                    strokeRun(samples[runStart...i], width: mean, in: context)
                    runStart = i
                    runSum = w
                } else {
                    runSum += w
                }
            }
            if runStart < samples.count - 1 {
                strokeRun(samples[runStart...], width: runSum / CGFloat(samples.count - runStart), in: context)
            }
        }

        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static func strokeRun(_ run: ArraySlice<PKStrokePoint>, width: CGFloat, in context: CGContext) {
        guard let first = run.first else { return }
        context.beginPath()
        context.move(to: first.location)
        for point in run.dropFirst() { context.addLine(to: point.location) }
        context.setLineWidth(width)
        context.strokePath()
    }

    private static let scaleCache = WidthScaleCache()

    /// Ratio of PencilKit's rendered thickness to the nominal point width. Measured by rendering a
    /// short, straight, horizontal probe stroke with the same ink and point attributes and counting
    /// solid pixels across its middle. Cached, since a person's strokes mostly share attributes.
    private static func widthScale(for stroke: PKStroke, sample: PKStrokePoint) -> CGFloat {
        guard sample.size.width > 0 else { return 1 }
        let key = WidthScaleCache.Key(ink: stroke.ink.inkType.rawValue,
                                      size: Int((sample.size.width * 8).rounded()),
                                      force: Int((sample.force * 20).rounded()),
                                      altitude: Int((sample.altitude * 20).rounded()))
        if let cached = scaleCache[key] { return cached }

        let probePoints = [0, 100, 200].map { x in
            PKStrokePoint(location: CGPoint(x: CGFloat(x), y: 0), timeOffset: TimeInterval(x) / 1000,
                          size: sample.size, opacity: 1, force: sample.force,
                          azimuth: sample.azimuth, altitude: sample.altitude)
        }
        let ink = PKInk(stroke.ink.inkType, color: .black)
        let probe = PKDrawing(strokes: [PKStroke(ink: ink, path: PKStrokePath(controlPoints: probePoints, creationDate: Date()),
                                                 transform: .identity, mask: nil)])
        let halfHeight = max(sample.size.width * 3, 10)
        let pixelsPerPoint: CGFloat = 4
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = probe.image(from: CGRect(x: 95, y: -halfHeight, width: 10, height: halfHeight * 2), scale: pixelsPerPoint)
        }
        var scale: CGFloat = 1
        if let cg = image?.cgImage, let solidRows = solidRowCount(in: cg) {
            scale = max(CGFloat(solidRows) / pixelsPerPoint / sample.size.width, 0.05)
        }
        scaleCache[key] = scale
        return scale
    }

    /// Rows in the middle column of `image` whose alpha is at least half: the stroke's thickness.
    private static func solidRowCount(in image: CGImage) -> Int? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let column = width / 2
        return (0..<height).filter { pixels[($0 * width + column) * 4 + 3] >= 128 }.count
    }

    /// Thread-safe memo of measured width scales (PDFKit may draw annotations off the main thread).
    final class WidthScaleCache: @unchecked Sendable {
        struct Key: Hashable { let ink: String; let size: Int; let force: Int; let altitude: Int }
        private var values: [Key: CGFloat] = [:]
        private let lock = NSLock()

        subscript(key: Key) -> CGFloat? {
            get { lock.withLock { values[key] } }
            set { lock.withLock { values[key] = newValue } }
        }
    }

    private static func drawRaster(_ stroke: PKStroke, in context: CGContext, scale: CGFloat) {
        let single = PKDrawing(strokes: [stroke])
        let bounds = single.bounds
        guard !bounds.isNull, !bounds.isEmpty else { return }
        var image: UIImage?
        // Render in light mode so dark-mode colour inversion never leaks into the file.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = single.image(from: bounds, scale: scale)
        }
        guard let image else { return }
        UIGraphicsPushContext(context)
        image.draw(in: bounds) // UIKit drawing assumes the same top-left space as the context.
        UIGraphicsPopContext()
    }
}

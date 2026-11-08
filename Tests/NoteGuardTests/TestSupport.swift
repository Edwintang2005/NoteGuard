import UIKit
import PencilKit
@testable import NoteGuard

/// A PencilKit stroke through `points` with a constant width.
func makeStroke(_ points: [CGPoint], width: CGFloat = 3, ink: PKInk = PKInk(.pen, color: .black)) -> PKStroke {
    let samples = points.enumerated().map { i, p in
        PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: CGSize(width: width, height: width),
                      opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    return PKStroke(ink: ink, path: PKStrokePath(controlPoints: samples, creationDate: Date()), transform: .identity, mask: nil)
}

/// Points every `spacing` along the polygon through `corners` (closed if `closed`), with a small,
/// deterministic wobble so recognisers see something hand-drawn.
func roughPath(_ corners: [CGPoint], closed: Bool, spacing: CGFloat = 4, wobble: CGFloat = 2) -> [CGPoint] {
    let vertices = closed ? corners + [corners[0]] : corners
    var out: [CGPoint] = []
    var n = 0
    for i in 0..<(vertices.count - 1) {
        let a = vertices[i], b = vertices[i + 1]
        let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / spacing))
        for s in 0..<steps {
            let t = CGFloat(s) / CGFloat(steps)
            let jitter = sin(CGFloat(n) * 0.9) * wobble
            out.append(CGPoint(x: a.x + (b.x - a.x) * t + jitter, y: a.y + (b.y - a.y) * t - jitter))
            n += 1
        }
    }
    out.append(vertices[vertices.count - 1])
    return out
}

/// A fresh one-page notebook file in a temporary folder.
func makeNotebook(_ template: PageTemplate = .lined) throws -> URL {
    try PageSource.builtIn(template).makeNotebookFile()
}

/// Runs `body` as its own undo group, so tests can undo operations one at a time.
func undoGroup(_ document: NoteDocument, _ body: () -> Void) {
    document.undoManager.groupsByEvent = false
    document.undoManager.beginUndoGrouping()
    body()
    document.undoManager.endUndoGrouping()
}

/// Draws with `draw` into a transparent RGBA bitmap (top-left origin) and returns the alpha channel.
func alphaChannel(size: CGSize, _ draw: (CGContext) -> Void) -> [UInt8] {
    let width = Int(size.width), height = Int(size.height)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        draw(context)
    }
    return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
}

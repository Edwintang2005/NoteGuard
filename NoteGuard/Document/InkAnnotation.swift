import UIKit
import PDFKit
import PencilKit

/// A full-page stamp annotation that renders a page's ink and carries its PencilKit data.
///
/// Other apps show the appearance stream (vector paths for most inks); NoteGuard reads the embedded
/// stroke data back so ink stays fully editable.
nonisolated final class InkAnnotation: PDFAnnotation {
    static let dataKey = PDFAnnotationKey(rawValue: "/NoteGuardInk")
    /// Key used before the app was renamed; still read so older notebooks keep editable ink.
    private static let legacyDataKey = PDFAnnotationKey(rawValue: "/NoteShieldInk")

    private let ink: PKDrawing

    init(drawing: PKDrawing, pageBounds: CGRect) {
        ink = drawing
        super.init(bounds: pageBounds, forType: .stamp, withProperties: nil)
        setValue(drawing.dataRepresentation().base64EncodedString(), forAnnotationKey: Self.dataKey)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static let writingKey = "NoteGuard.writingInk"

    /// Runs `body` (a `PDFDocument.dataRepresentation()` call) with ink painting switched on for this
    /// thread only.
    ///
    /// PDFKit calls `draw` both to build the appearance stream that gets written to the file and to
    /// paint pages on screen. On screen the page's live canvas already shows the ink, and PDFView can
    /// keep a painted copy of a page after this annotation is removed again, which leaves a ghost
    /// of the old ink under the canvas (lasso moves look like copies, erasing looks like it fails).
    /// So the annotation paints only inside this call, and only on the thread writing the file.
    static func whileWriting<T>(_ body: () throws -> T) rethrows -> T {
        let thread = Thread.current
        thread.threadDictionary[writingKey] = true
        defer { thread.threadDictionary.removeObject(forKey: writingKey) }
        return try body()
    }

    private static var isWriting: Bool { Thread.current.threadDictionary[writingKey] as? Bool == true }

    /// Called by PDFKit to build the appearance stream when the document is written out.
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard Self.isWriting else { return }
        context.saveGState()
        // Ink space has a top-left origin with y down; PDF space is bottom-left with y up.
        context.translateBy(x: bounds.minX, y: bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        InkRenderer.draw(ink, in: context)
        context.restoreGState()
    }

    static func drawing(from annotation: PDFAnnotation) -> PKDrawing? {
        let value = annotation.value(forAnnotationKey: dataKey) ?? annotation.value(forAnnotationKey: legacyDataKey)
        guard let encoded = value as? String, let data = Data(base64Encoded: encoded) else { return nil }
        return try? PKDrawing(data: data)
    }
}

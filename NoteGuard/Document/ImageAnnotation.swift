import UIKit
import PDFKit
import ImageIO

/// A picture placed on a page. Saved as a stamp annotation whose appearance is the image (so every
/// PDF viewer shows it) and which carries the encoded image, so NoteGuard can move and resize it later.
nonisolated final class ImageAnnotation: PDFAnnotation {
    static let dataKey = PDFAnnotationKey(rawValue: "/NoteGuardImage")
    /// Longest side, in pixels, that imported images are scaled down to.
    static let maxPixelSize: CGFloat = 1600

    let imageData: Data
    private let image: CGImage?

    /// Width ÷ height of the image (1 if it couldn't be decoded).
    var aspectRatio: CGFloat {
        guard let image, image.height > 0 else { return 1 }
        return CGFloat(image.width) / CGFloat(image.height)
    }

    init(imageData: Data, bounds: CGRect) {
        self.imageData = imageData
        if let source = CGImageSourceCreateWithData(imageData as CFData, nil) {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            image = nil
        }
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        setValue(imageData.base64EncodedString(), forAnnotationKey: Self.dataKey)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let image else { return }
        context.saveGState()
        context.interpolationQuality = .high
        // PDF space is y-up, which is what CGContext.draw expects for an upright image.
        context.draw(image, in: bounds)
        context.restoreGState()
    }

    func duplicate(offsetBy offset: CGPoint) -> ImageAnnotation {
        ImageAnnotation(imageData: imageData, bounds: bounds.offsetBy(dx: offset.x, dy: offset.y))
    }

    /// Rebuilds a NoteGuard image from an annotation read out of a saved PDF.
    static func restore(from annotation: PDFAnnotation) -> ImageAnnotation? {
        guard let encoded = annotation.value(forAnnotationKey: dataKey) as? String,
              let data = Data(base64Encoded: encoded) else { return nil }
        return ImageAnnotation(imageData: data, bounds: annotation.bounds)
    }

    /// Scales `image` down to a sensible size and encodes it (PNG if it has transparency, else JPEG).
    static func encode(_ image: UIImage) -> Data? {
        guard let cg = image.cgImage else { return nil }
        let pixelSize = CGSize(width: CGFloat(cg.width), height: CGFloat(cg.height))
        let scale = min(1, maxPixelSize / max(pixelSize.width, pixelSize.height))
        let target = CGSize(width: (pixelSize.width * scale).rounded(), height: (pixelSize.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let alpha = cg.alphaInfo
        let hasAlpha = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        format.opaque = !hasAlpha
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return hasAlpha ? resized.pngData() : resized.jpegData(compressionQuality: 0.85)
    }
}

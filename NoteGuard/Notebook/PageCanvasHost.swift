import UIKit
import PencilKit

/// The view PDFKit puts over a page; it holds that page's PencilKit canvas at screen resolution.
///
/// PDFKit sizes page overlays in PDF points (with a content scale of 1) and then magnifies them to
/// the page's on-screen size: over 2× for slide-sized pages at fit width, more when zoomed in.
/// PencilKit renders ink for the canvas's own size and zoom, so a canvas sized in points drew its
/// ink small and was then stretched, which made thin strokes soft.
///
/// So the canvas is made as large as the page appears on screen and zoomed in by the same factor
/// (its drawing stays in page points, which is what gets saved), then scaled back down to fit this
/// view. PDFKit's magnification undoes that scale-down, leaving ink drawn at full resolution.
final class PageCanvasHost: UIView {
    let canvas: PKCanvasView
    /// NoteGuard's resizable lasso, over the canvas; in page (drawing) coordinates like this view.
    let lasso = InkLassoView()
    private(set) var magnification: CGFloat = 1

    /// Upper limits, so a deep zoom can't ask PencilKit for an enormous canvas: at most 8× and at
    /// most 8192 pixels along the page's longer side. Past that, ink softens slightly instead.
    private let maximumMagnification: CGFloat = 8
    private let maximumPixels: CGFloat = 8192

    init(canvas: PKCanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        addSubview(canvas)
        lasso.canvas = canvas
        addSubview(lasso)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Call when the PDF zoom changes; re-renders the ink only if the magnification moved enough.
    func refreshResolution() {
        if abs(currentMagnification() - magnification) / magnification > 0.1 { setNeedsLayout() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let m = currentMagnification()
        magnification = m
        let scale = window?.screen.scale ?? traitCollection.displayScale

        canvas.transform = .identity
        canvas.bounds = CGRect(origin: .zero, size: CGSize(width: bounds.width * m, height: bounds.height * m))
        canvas.minimumZoomScale = m
        canvas.maximumZoomScale = m
        canvas.zoomScale = m
        canvas.contentSize = canvas.bounds.size
        canvas.contentOffset = .zero
        canvas.contentScaleFactor = scale
        canvas.transform = CGAffineTransform(scaleX: 1 / m, y: 1 / m)
        canvas.center = CGPoint(x: bounds.midX, y: bounds.midY)
        lasso.frame = bounds
        lasso.magnification = m
    }

    /// How many screen points one page point covers right now.
    private func currentMagnification() -> CGFloat {
        guard let window, bounds.width > 0 else { return 1 }
        let shown = convert(bounds, to: nil).width / bounds.width
        let pixelLimit = maximumPixels / (max(bounds.width, bounds.height) * window.screen.scale)
        // Rounded so small zoom jitters don't re-render the ink.
        return min(max((shown * 4).rounded() / 4, 1), maximumMagnification, max(pixelLimit, 1))
    }
}

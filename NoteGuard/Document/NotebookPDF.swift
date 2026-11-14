import Foundation
import PDFKit

/// The PDF behind a notebook. Its pages draw layered content (optional content) the way other
/// viewers do; see `ContentStreamRewriter`. Saving is unaffected: the file keeps its original
/// content and layers, so every other app still sees the document as it was.
nonisolated final class NotebookPDF: PDFDocument, @unchecked Sendable {
    private(set) var optionalContent = OptionalContentState(document: nil)

    override init() {
        super.init()
    }

    override init?(data: Data) {
        super.init(data: data)
        optionalContent = OptionalContentState(document: documentRef)
    }

    override init?(url: URL) {
        super.init(url: url)
        optionalContent = OptionalContentState(document: documentRef)
    }

    override var pageClass: AnyClass { NotebookPDFPage.self }

    /// The `/State` array of a link's "set layer state" action, if it has one.
    func layerToggle(for link: PDFAnnotation, on page: PDFPage) -> CGPDFArrayRef? {
        guard optionalContent.hasLayers, let annots = page.pageRef?.dictionary?.array("Annots") else { return nil }
        let target = link.bounds
        for annotation in annots.dictionaries() where annotation.name("Subtype") == "Link" {
            let r = annotation.numbers("Rect")
            guard r.count == 4 else { continue }
            let rect = CGRect(x: min(r[0], r[2]), y: min(r[1], r[3]), width: abs(r[2] - r[0]), height: abs(r[3] - r[1]))
            guard abs(rect.minX - target.minX) < 0.5, abs(rect.minY - target.minY) < 0.5,
                  abs(rect.width - target.width) < 0.5, abs(rect.height - target.height) < 0.5,
                  let action = annotation.dictionary("A"), action.name("S") == "SetOCGState" else { continue }
            return action.array("State")
        }
        return nil
    }
}

/// A page that, when its content uses layers or clip-mode text, draws a rewritten copy of itself.
///
/// PDFKit creates pages through its own initialiser, so Swift stored properties on this class
/// would never be initialised; per-page state lives in `PageRenderCache` instead.
nonisolated final class NotebookPDFPage: PDFPage, @unchecked Sendable {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        guard let replacement = PageRenderCache.shared.replacement(for: self) else {
            super.draw(with: box, to: context)
            return
        }
        context.saveGState()
        transform(context, for: box)
        context.clip(to: bounds(for: box))
        context.drawPDFPage(replacement.page)
        if displaysAnnotations {
            for annotation in annotations where annotation.shouldDisplay {
                annotation.draw(with: box, in: context)
            }
        }
        context.restoreGState()
    }

    fileprivate func makeReplacement(state: OptionalContentState) -> RenderedPage? {
        guard let source = pageRef else { return nil }
        let content = source.contentBytes()
        guard ContentStreamRewriter.mightNeedRewrite(content) else { return nil }
        let resources = source.inheritedDictionary("Resources")
        let hooks = ContentStreamRewriter.Hooks(
            isPropertyHidden: { name in
                guard let dict = resources?.dictionary("Properties")?.dictionary(name) else { return false }
                return state.isHidden(optionalContent: dict)
            },
            isXObjectHidden: { name in
                guard let stream = resources?.dictionary("XObject")?.stream(name),
                      let dict = CGPDFStreamGetDictionary(stream),
                      let oc = dict.dictionary("OC") else { return false }
                return state.isHidden(optionalContent: oc)
            }
        )
        // Apple's renderer applies a layer's starting state but never a change to it, so once a
        // layered page has been rewritten it always draws through here, even when nothing is hidden.
        let layered = state.hasLayers && ContentStreamRewriter.usesOptionalContent(content)
        guard let rewritten = ContentStreamRewriter.rewrite(content, hooks: hooks) ?? (layered ? content : nil),
              let data = PageExtractor.makePDF(from: source, content: rewritten),
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        return RenderedPage(document: document, page: page)
    }
}

/// A rewritten page, holding its document so the page stays valid.
nonisolated final class RenderedPage: @unchecked Sendable {
    let document: CGPDFDocument
    let page: CGPDFPage
    init(document: CGPDFDocument, page: CGPDFPage) {
        self.document = document
        self.page = page
    }
}

/// Rewritten pages, rebuilt when the layer state changes. Keys are held weakly.
nonisolated final class PageRenderCache: @unchecked Sendable {
    static let shared = PageRenderCache()

    private final class Entry {
        let version: Int
        let rendered: RenderedPage?
        init(version: Int, rendered: RenderedPage?) {
            self.version = version
            self.rendered = rendered
        }
    }

    private let lock = NSLock()
    private let entries = NSMapTable<NotebookPDFPage, Entry>.weakToStrongObjects()

    fileprivate func replacement(for page: NotebookPDFPage) -> RenderedPage? {
        guard let state = (page.document as? NotebookPDF)?.optionalContent else { return nil }
        let version = state.version
        lock.lock()
        if let entry = entries.object(forKey: page), entry.version == version {
            lock.unlock()
            return entry.rendered
        }
        lock.unlock()
        // Built outside the lock: pages render in parallel.
        let rendered = page.makeReplacement(state: state)
        lock.lock()
        entries.setObject(Entry(version: version, rendered: rendered), forKey: page)
        lock.unlock()
        return rendered
    }
}

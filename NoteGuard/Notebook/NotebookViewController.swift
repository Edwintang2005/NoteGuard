import UIKit
import SwiftUI
import PDFKit
import PencilKit
import Combine
import os

/// Shows an open PDF with a PencilKit canvas laid over each page.
///
/// Any touch draws (a capacitive stylus is indistinguishable from a finger), so scrolling and
/// zooming use two fingers. The hand tool switches to one-finger scrolling.
final class NotebookViewController: UIViewController {
    private let document: NoteDocument
    private let onClosed: () -> Void
    private let tools = InkToolState()
    private let pdfView = PDFView()
    private let thumbnails = PDFThumbnailView()
    /// Canvases for the pages PDFKit currently has on screen.
    private var canvases: [ObjectIdentifier: PKCanvasView] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var isClosing = false
    private let log = Logger(subsystem: "NoteGuard", category: "Notebook")

    init(document: NoteDocument, onClosed: @escaping () -> Void) {
        self.document = document
        self.onClosed = onClosed
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// One undo stack for every page; PencilKit registers strokes through the responder chain.
    override var undoManager: UndoManager? { document.undoManager }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground

        pdfView.pageOverlayViewProvider = self
        pdfView.isInMarkupMode = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displayBox = .cropBox
        pdfView.autoScales = true
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.document = document.pdf

        thumbnails.pdfView = pdfView
        thumbnails.layoutMode = .vertical
        thumbnails.thumbnailSize = CGSize(width: 64, height: 90)
        thumbnails.backgroundColor = .systemBackground
        thumbnails.isHidden = true
        thumbnails.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let content = UIStackView(arrangedSubviews: [pdfView, thumbnails])
        content.axis = .horizontal
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)

        let toolbar = UIHostingController(rootView: NotebookToolbar(
            tools: tools,
            store: .shared,
            title: document.localizedName,
            actions: NotebookActions(
                close: { [weak self] in self?.close() },
                undo: { [weak self] in self?.document.undoManager.undo() },
                redo: { [weak self] in self?.document.undoManager.redo() },
                addPage: { [weak self] template in self?.addPage(template) },
                deletePage: { [weak self] in self?.confirmDeletePage() },
                toggleThumbnails: { [weak self] in self?.toggleThumbnails() },
                editZones: { [weak self] in
                    if let self { ZoneEditorPresenter.present(from: self) }
                }
            )
        ))
        toolbar.sizingOptions = .intrinsicContentSize
        toolbar.view.backgroundColor = .clear
        toolbar.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(toolbar)
        view.addSubview(toolbar.view)
        toolbar.didMove(toParent: self)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            toolbar.view.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6),
            toolbar.view.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            toolbar.view.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 12),
            toolbar.view.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: toolbar.view.bottomAnchor, constant: 6),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // @Published emits before the value changes, so use the emitted values directly.
        Publishers.CombineLatest(tools.$tool, tools.$colorIndex)
            .sink { [weak self] tool, colorIndex in self?.applyTool(tool, colorIndex: colorIndex) }
            .store(in: &cancellables)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyTool(tools.tool, colorIndex: tools.colorIndex)
    }

    // MARK: Tools

    private var documentScrollView: UIScrollView? {
        func find(in view: UIView) -> UIScrollView? {
            for sub in view.subviews {
                if let scroll = sub as? UIScrollView, !(scroll is PKCanvasView) { return scroll }
                if let found = find(in: sub) { return found }
            }
            return nil
        }
        return find(in: pdfView)
    }

    private func applyTool(_ tool: InkToolState.Tool, colorIndex: Int) {
        let pkTool = InkToolState.pkTool(tool, colorIndex: colorIndex)
        let drawing = tool != .scroll
        for canvas in canvases.values {
            canvas.tool = pkTool
            canvas.isUserInteractionEnabled = drawing
        }
        // One finger draws; two fingers scroll. In scroll mode one finger scrolls.
        documentScrollView?.panGestureRecognizer.minimumNumberOfTouches = drawing ? 2 : 1
    }

    // MARK: Pages

    private var currentPageIndex: Int {
        guard let page = pdfView.currentPage else { return max(document.pdf.pageCount - 1, 0) }
        return document.pdf.index(for: page)
    }

    private func addPage(_ template: PageTemplate) {
        let size = pdfView.currentPage?.bounds(for: .cropBox).size ?? PageTemplate.a4
        guard let page = template.makePage(size: size) else { return }
        let index = min(currentPageIndex + 1, document.pdf.pageCount)
        document.insert(page, at: index)
        pdfView.layoutDocumentView()
        if let inserted = document.pdf.page(at: index) { pdfView.go(to: inserted) }
    }

    private func confirmDeletePage() {
        guard document.pdf.pageCount > 1, let page = pdfView.currentPage else {
            let alert = UIAlertController(title: "Can't delete the only page", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let number = document.pdf.index(for: page) + 1
        let alert = UIAlertController(title: "Delete page \(number)?",
                                      message: "The page and its handwriting are removed from the PDF when it saves.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            canvases[ObjectIdentifier(page)] = nil
            document.remove(page)
            pdfView.layoutDocumentView()
        })
        present(alert, animated: true)
    }

    private func toggleThumbnails() {
        UIView.animate(withDuration: 0.25) { self.thumbnails.isHidden.toggle() }
    }

    // MARK: Closing

    func close(completion: (() -> Void)? = nil) {
        guard !isClosing else { return }
        isClosing = true
        Task { [weak self] in
            guard let self else { return }
            let success = await document.close()
            if !success { log.error("Saving \(self.document.fileURL.lastPathComponent, privacy: .public) failed") }
            onClosed()
            dismiss(animated: true, completion: completion)
        }
    }
}

// MARK: - Page overlays

extension NotebookViewController: PDFPageOverlayViewProvider {
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let key = ObjectIdentifier(page)
        if let existing = canvases[key] { return existing }

        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.overrideUserInterfaceStyle = .light // keep ink colours true in Dark Mode
        canvas.drawing = document.drawings[key] ?? PKDrawing()
        canvas.tool = InkToolState.pkTool(tools.tool, colorIndex: tools.colorIndex)
        canvas.isUserInteractionEnabled = tools.tool != .scroll
        canvas.delegate = self // after loading the drawing, so opening doesn't mark the file edited
        canvases[key] = canvas
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        log.debug("overlay \(String(describing: overlayView.bounds), privacy: .public) page \(String(describing: page.bounds(for: .cropBox)), privacy: .public)")
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        canvases[ObjectIdentifier(page)] = nil
    }
}

extension NotebookViewController: PKCanvasViewDelegate {
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let page = document.pdf.pageIndex(containing: canvasView, in: canvases) else { return }
        document.setDrawing(canvasView.drawing, for: page)
    }
}

private extension PDFDocument {
    func pageIndex(containing canvas: PKCanvasView, in canvases: [ObjectIdentifier: PKCanvasView]) -> PDFPage? {
        guard let key = canvases.first(where: { $0.value === canvas })?.key else { return nil }
        for i in 0..<pageCount {
            if let page = page(at: i), ObjectIdentifier(page) == key { return page }
        }
        return nil
    }
}

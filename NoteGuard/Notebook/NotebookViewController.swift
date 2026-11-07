import UIKit
import SwiftUI
import PDFKit
import PencilKit
import Combine
import os

/// Observable state for the notebook's top bar.
final class NotebookChrome: ObservableObject {
    @Published var title: String
    /// One-finger scrolling instead of drawing.
    @Published var isScrollMode = false
    @Published var isPaletteVisible = true

    init(title: String) { self.title = title }
}

/// Shows an open PDF with a PencilKit canvas over each page and the system tool palette
/// (the same one Markup in the Files app uses — drag it to any edge or let it float).
///
/// Any touch draws (a capacitive stylus is indistinguishable from a finger), so scrolling and
/// zooming use two fingers. The hand button switches to one-finger scrolling.
final class NotebookViewController: UIViewController {
    typealias Renamer = (_ url: URL, _ newName: String, _ completion: @escaping (Result<URL, Error>) -> Void) -> Void

    private let document: NoteDocument
    private let rename: Renamer
    private let onClosed: () -> Void
    private let chrome: NotebookChrome
    private let pdfView = PDFView()
    private let thumbnails = PDFThumbnailView()
    private let toolPicker = PKToolPicker()
    private var toolbarHost: UIHostingController<NotebookToolbar>?
    /// Canvases (and their shape helpers) for the pages PDFKit currently has on screen.
    private var canvases: [ObjectIdentifier: PKCanvasView] = [:]
    private var shapeAssists: [ObjectIdentifier: ShapeAssist] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var isClosing = false
    private let log = Logger(subsystem: "NoteGuard", category: "Notebook")

    init(document: NoteDocument, rename: @escaping Renamer, onClosed: @escaping () -> Void) {
        self.document = document
        self.rename = rename
        self.onClosed = onClosed
        self.chrome = NotebookChrome(title: document.localizedName)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// One undo stack for every page; PencilKit and the palette's undo buttons use the responder chain.
    override var undoManager: UndoManager? { document.undoManager }

    /// The palette is shown for this controller, so it stays up whichever page is under your pen.
    override var canBecomeFirstResponder: Bool { true }

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

        let toolbar = UIHostingController(rootView: NotebookToolbar(chrome: chrome, store: .shared, actions: makeActions()))
        toolbar.sizingOptions = .intrinsicContentSize
        toolbar.view.backgroundColor = .clear
        toolbar.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(toolbar)
        view.addSubview(toolbar.view)
        toolbar.didMove(toParent: self)
        toolbarHost = toolbar

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

        // The system palette: all Markup tools, colour picker, widths, ruler, lasso, undo/redo.
        // Its position (docked edge or floating) and selected tool are remembered between launches.
        toolPicker.stateAutosaveName = "NoteGuard.toolPicker"
        toolPicker.showsDrawingPolicyControls = false // fingers and stylus both draw
        toolPicker.colorUserInterfaceStyle = .light   // pages are white, so keep ink colours true
        toolPicker.addObserver(self)

        // @Published emits before the value changes, so use the emitted value directly.
        chrome.$isScrollMode
            .sink { [weak self] scrolling in self?.applyInteractionMode(scrolling: scrolling) }
            .store(in: &cancellables)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        showPalette(chrome.isPaletteVisible)
        applyInteractionMode(scrolling: chrome.isScrollMode)
    }

    // MARK: Tools

    private var currentTool: PKTool {
        toolPicker.selectedToolItem.tool ?? PKInkingTool(.pen, color: .black, width: 3)
    }

    private func showPalette(_ visible: Bool) {
        toolPicker.setVisible(visible, forFirstResponder: self)
        if visible { becomeFirstResponder() }
    }

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

    private func applyInteractionMode(scrolling: Bool) {
        for canvas in canvases.values { canvas.isUserInteractionEnabled = !scrolling }
        // Drawing mode: one finger draws, two scroll. Scroll mode: one finger scrolls.
        documentScrollView?.panGestureRecognizer.minimumNumberOfTouches = scrolling ? 1 : 2
    }

    // MARK: Actions

    private func makeActions() -> NotebookActions {
        NotebookActions(
            close: { [weak self] in self?.close() },
            undo: { [weak self] in self?.document.undoManager.undo() },
            redo: { [weak self] in self?.document.undoManager.redo() },
            rename: { [weak self] in self?.promptRename() },
            share: { [weak self] in self?.share() },
            print: { [weak self] in self?.printDocument() },
            togglePalette: { [weak self] in
                guard let self else { return }
                chrome.isPaletteVisible.toggle()
                showPalette(chrome.isPaletteVisible)
            },
            addPage: { [weak self] template in self?.addPage(template) },
            deletePage: { [weak self] in self?.confirmDeletePage() },
            toggleThumbnails: { [weak self] in self?.toggleThumbnails() },
            editZones: { [weak self] in
                if let self { ZoneEditorPresenter.present(from: self) }
            }
        )
    }

    /// Where popovers (share, print) point: the title at the leading end of the bar.
    private var titleAnchor: CGRect {
        guard let bar = toolbarHost?.view else { return .zero }
        let frame = bar.convert(bar.bounds, to: view)
        return CGRect(x: frame.minX + 40, y: frame.minY, width: 200, height: frame.height)
    }

    private func promptRename() {
        let alert = UIAlertController(title: "Rename notebook", message: nil, preferredStyle: .alert)
        alert.addTextField { [chrome] field in
            field.text = chrome.title
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
            field.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.showPalette(self?.chrome.isPaletteVisible ?? true) })
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            showPalette(chrome.isPaletteVisible)
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, name != chrome.title else { return }
            performRename(to: name)
        })
        present(alert, animated: true)
    }

    private func performRename(to name: String) {
        // Save first so nothing in memory is lost if the file moves under us.
        Task { [weak self] in
            guard let self else { return }
            _ = await document.save(to: document.fileURL, for: .forOverwriting)
            rename(document.fileURL, name) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(url):
                    chrome.title = url.deletingPathExtension().lastPathComponent
                case let .failure(error):
                    showAlert("Couldn't rename", message: error.localizedDescription)
                }
            }
        }
    }

    private func share() {
        Task { [weak self] in
            guard let self else { return }
            _ = await document.save(to: document.fileURL, for: .forOverwriting)
            let sheet = UIActivityViewController(activityItems: [document.fileURL], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = view
            sheet.popoverPresentationController?.sourceRect = titleAnchor
            present(sheet, animated: true)
        }
    }

    private func printDocument() {
        Task { [weak self] in
            guard let self else { return }
            _ = await document.save(to: document.fileURL, for: .forOverwriting)
            let printer = UIPrintInteractionController.shared
            let info = UIPrintInfo.printInfo()
            info.jobName = chrome.title
            info.outputType = .general
            printer.printInfo = info
            printer.printingItem = document.fileURL
            printer.present(from: titleAnchor, in: view, animated: true)
        }
    }

    private func showAlert(_ title: String, message: String?) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
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
            showAlert("Can't delete the only page", message: nil)
            return
        }
        let number = document.pdf.index(for: page) + 1
        let alert = UIAlertController(title: "Delete page \(number)?",
                                      message: "The page and its handwriting are removed from the PDF when it saves.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            let key = ObjectIdentifier(page)
            if let canvas = canvases.removeValue(forKey: key) { toolPicker.removeObserver(canvas) }
            shapeAssists[key] = nil
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
        toolPicker.setVisible(false, forFirstResponder: self)
        Task { [weak self] in
            guard let self else { return }
            let success = await document.close()
            if !success { log.error("Saving \(self.document.fileURL.lastPathComponent, privacy: .public) failed") }
            onClosed()
            dismiss(animated: true, completion: completion)
        }
    }
}

// MARK: - Tool palette

extension NotebookViewController: PKToolPickerObserver {
    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        if chrome.isPaletteVisible != toolPicker.isVisible, !isClosing, presentedViewController == nil {
            chrome.isPaletteVisible = toolPicker.isVisible
        }
    }

    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        // Picking a tool means you want to draw.
        if chrome.isScrollMode { chrome.isScrollMode = false }
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
        canvas.tool = currentTool
        canvas.isRulerActive = toolPicker.isRulerActive
        canvas.isUserInteractionEnabled = !chrome.isScrollMode
        canvas.delegate = self // after loading the drawing, so opening doesn't mark the file edited
        toolPicker.addObserver(canvas) // follows the palette's tool and ruler
        canvases[key] = canvas
        shapeAssists[key] = ShapeAssist(canvas: canvas)
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        let key = ObjectIdentifier(page)
        if let canvas = canvases.removeValue(forKey: key) { toolPicker.removeObserver(canvas) }
        shapeAssists[key] = nil
    }
}

extension NotebookViewController: PKCanvasViewDelegate {
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let key = canvases.first(where: { $0.value === canvasView })?.key else { return }
        // A snapped shape replaces the stroke and triggers another change; save on that one.
        if shapeAssists[key]?.drawingDidChange() == true { return }
        guard let page = document.pdf.page(withKey: key) else { return }
        document.setDrawing(canvasView.drawing, for: page)
    }
}

private extension PDFDocument {
    func page(withKey key: ObjectIdentifier) -> PDFPage? {
        for i in 0..<pageCount {
            if let page = page(at: i), ObjectIdentifier(page) == key { return page }
        }
        return nil
    }
}

import UIKit
import SwiftUI
import PDFKit
import PencilKit
import PhotosUI
import UniformTypeIdentifiers
import Combine
import os

enum InteractionMode {
    /// One finger scrolls. Text boxes and images can be tapped, dragged, resized and (double-tap)
    /// edited; handwriting is left alone. Notebooks open in this mode.
    case scroll
    /// The tool palette is open (its lasso selects handwriting); one finger or the stylus draws
    /// with its tool; two fingers scroll.
    case draw
    /// Laser pointer: a fading red dot for presenting; nothing is drawn. Two fingers scroll.
    case laser
}

/// Observable state for the notebook's top bar.
final class NotebookChrome: ObservableObject {
    @Published var title: String
    @Published var mode: InteractionMode = .scroll
    @Published var isSidebarVisible = false
    @Published var isCurrentPageBookmarked = false
    @Published var customTemplates: [CustomTemplate] = []

    init(title: String) { self.title = title }
}

/// Shows an open PDF with a PencilKit canvas over each page, the system tool palette (the same
/// one Markup in the Files app uses), the page sidebar and the Select tool.
final class NotebookViewController: UIViewController {
    typealias Renamer = (_ url: URL, _ newName: String, _ completion: @escaping (Result<URL, Error>) -> Void) -> Void

    private let document: NoteDocument
    private let rename: Renamer
    private let onClosed: () -> Void
    private let chrome: NotebookChrome
    private let pdfView = PDFView()
    private lazy var sidebar = PageSidebar(document: document)
    private lazy var objectEditor = ObjectEditor(pdfView: pdfView, document: document)
    private var laser: LaserPointer?
    private let toolPicker = PKToolPicker()
    private var toolbarHost: UIHostingController<NotebookToolbar>?
    /// Canvases (and their shape helpers) for the pages PDFKit currently has on screen.
    private var canvases: [ObjectIdentifier: PKCanvasView] = [:]
    private var shapeAssists: [ObjectIdentifier: ShapeAssist] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var isClosing = false
    /// Screens presented over the notebook that haven't gone away yet (weak, so one that never
    /// appeared can't keep the palette hidden forever).
    private let coveringControllers = NSHashTable<UIViewController>.weakObjects()
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

    /// One undo stack for every page and object; PencilKit and the palette use the responder chain.
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

        sidebar.isHidden = true
        sidebar.alpha = 0
        sidebar.onSelect = { [weak self] page in self?.pdfView.go(to: page) }
        sidebar.onMove = { [weak self] from, to in self?.document.movePage(from: from, to: to) }
        sidebar.menuProvider = { [weak self] page in self?.pageMenu(for: page) ?? UIMenu() }
        sidebar.onRemoveBookmark = { [weak self] outline in self?.document.removeBookmark(outline) }

        // Thumbnails on the left, like most notes apps.
        let content = UIStackView(arrangedSubviews: [sidebar, pdfView])
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
        laser = LaserPointer(target: pdfView, container: view, above: content)

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

        objectEditor.onTextEditingChanged = { [weak self] editing in
            if !editing { self?.syncPalette() }
        }

        document.onPagesChanged = { [weak self] in self?.pagesDidChange() }
        document.onBookmarksChanged = { [weak self] in
            self?.sidebar.reloadBookmarks()
            self?.sidebar.reloadPages()
            self?.updatePageState()
        }
        document.onAnnotationsChanged = { [weak self] page in self?.sidebar.invalidateThumbnail(for: page) }

        NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: pdfView)
            .sink { [weak self] _ in self?.updatePageState() }
            .store(in: &cancellables)

        // @Published emits before the value changes, so use the emitted value directly.
        chrome.$mode
            .sink { [weak self] mode in self?.applyMode(mode) }
            .store(in: &cancellables)

        chrome.customTemplates = TemplateLibrary.shared.all()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        objectEditor.follow(scrollView: documentScrollView)
        // Dragging a text box or image moves it; dragging anywhere else scrolls.
        if let scrollPan = documentScrollView?.panGestureRecognizer { objectEditor.takePriority(over: scrollPan) }
        applyMode(chrome.mode)
        updatePageState()
    }

    // MARK: Rotation

    /// PDFView refits its pages on rotation while the ink canvases and selection layer follow a
    /// beat later, which looks glitchy. Cover the pages with a snapshot during the turn, then refit,
    /// return to the same spot on the same page, and fade back in.
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        guard view.window != nil else { return }
        let anchor = readingPosition()
        let cover = pdfView.snapshotView(afterScreenUpdates: false)
        if let cover {
            cover.frame = pdfView.convert(pdfView.bounds, to: view)
            view.insertSubview(cover, aboveSubview: pdfView.superview ?? pdfView)
        }
        pdfView.alpha = 0
        coordinator.animate(alongsideTransition: { _ in
            cover?.alpha = 0
        }, completion: { [weak self] _ in
            guard let self else { return }
            cover?.removeFromSuperview()
            pdfView.autoScales = true // fit the page width to the new orientation
            pdfView.layoutDocumentView()
            if let anchor { pdfView.go(to: PDFDestination(page: anchor.page, at: anchor.point)) }
            objectEditor.refresh()
            UIView.animate(withDuration: 0.2) { self.pdfView.alpha = 1 }
        })
    }

    /// The page and the point on it at the top-left of the screen.
    private func readingPosition() -> (page: PDFPage, point: CGPoint)? {
        let corner = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.minY + 1)
        guard let page = pdfView.page(for: corner, nearest: true) else { return nil }
        let visible = pdfView.convert(pdfView.bounds, to: page)
        let box = page.bounds(for: pdfView.displayBox)
        // PDF space has y going up, so the top of the screen is the rect's maxY.
        return (page, CGPoint(x: box.minX, y: min(visible.maxY, box.maxY)))
    }

    // MARK: Modes and tools

    private var currentTool: PKTool {
        toolPicker.selectedToolItem.tool ?? PKInkingTool(.pen, color: .black, width: 3)
    }

    /// The palette is open exactly while drawing, and nothing (a sheet, picker, alert or popover)
    /// is shown over the notebook. Call again after anything that may have taken first responder.
    private func syncPalette(for mode: InteractionMode? = nil) {
        let covered = coveringControllers.allObjects.contains { !$0.isBeingDismissed }
        let visible = (mode ?? chrome.mode) == .draw && !isClosing && !covered
        // Registered for the page canvases too: touching a canvas can make it first responder, and
        // the palette must stay up (or down) whichever responder is current.
        toolPicker.setVisible(visible, forFirstResponder: self)
        for canvas in canvases.values { toolPicker.setVisible(visible, forFirstResponder: canvas) }
        if visible, !isFirstResponder, !canvases.values.contains(where: \.isFirstResponder) {
            becomeFirstResponder()
        } else if !visible {
            // The palette only updates when the first responder changes, so step aside: otherwise
            // it can stay on screen over a sheet even after being told to hide.
            if isFirstResponder { resignFirstResponder() }
            canvases.values.first(where: \.isFirstResponder)?.resignFirstResponder()
        }
    }

    /// The palette floats above the whole app, so it would sit on top of anything the notebook
    /// presents (the photo picker, share sheet, alerts...). Hide it for as long as that's up.
    override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        // Counted from the request, not from when it appears: some screens (the photo picker)
        // load first and only show up a moment later.
        coveringControllers.add(controller)
        super.present(controller, animated: animated, completion: completion)
        syncPalette()
        // Bring the palette back once the presented screen has left, however it was closed
        // (a button, a swipe down, tapping outside a popover).
        PresentationEndWatcher.attach(to: controller) { [weak self, weak controller] in
            guard let self else { return }
            if let controller { coveringControllers.remove(controller) }
            syncPalette()
        }
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

    private func applyMode(_ mode: InteractionMode) {
        // Called before `chrome.mode` changes, so it still holds the mode being left. Closing the
        // pen drawer ends a drawing session: save now rather than on the next autosave.
        if chrome.mode == .draw, mode != .draw { saveNow() }
        for canvas in canvases.values { canvas.isUserInteractionEnabled = mode == .draw }
        // Drawing and pointing: one finger acts, two scroll. Scroll mode: one finger scrolls.
        documentScrollView?.panGestureRecognizer.minimumNumberOfTouches = mode == .scroll ? 1 : 2
        objectEditor.isActive = mode == .scroll
        laser?.isActive = mode == .laser
        syncPalette(for: mode)
    }

    private func saveNow() {
        guard document.hasUnsavedChanges else { return }
        document.autosave { [weak self] success in
            if !success { self?.log.error("Saving after drawing failed") }
        }
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
            insertTextBox: { [weak self] in
                guard let self else { return }
                chrome.mode = .scroll
                objectEditor.insertTextBox()
            },
            insertPhoto: { [weak self] in self?.pickPhoto() },
            insertImageFile: { [weak self] in self?.pickImageFile() },
            addPage: { [weak self] source in self?.addPage(source) },
            duplicatePage: { [weak self] in
                guard let self, let page = pdfView.currentPage else { return }
                duplicate(page)
            },
            toggleBookmark: { [weak self] in
                guard let self, let page = pdfView.currentPage else { return }
                toggleBookmark(page)
            },
            saveTemplate: { [weak self] in
                guard let self, let page = pdfView.currentPage else { return }
                saveAsTemplate(page)
            },
            deleteTemplate: { [weak self] template in self?.confirmDeleteTemplate(template) },
            deletePage: { [weak self] in
                guard let self, let page = pdfView.currentPage else { return }
                confirmDelete(page)
            },
            toggleSidebar: { [weak self] in self?.toggleSidebar() },
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

    private func promptText(title: String, message: String? = nil, initial: String, action: String,
                            completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = initial
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
            field.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.syncPalette()
        })
        alert.addAction(UIAlertAction(title: action, style: .default) { [weak self, weak alert] _ in
            self?.syncPalette()
            let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { completion(text) }
        })
        present(alert, animated: true)
    }

    private func promptRename() {
        promptText(title: "Rename notebook", initial: chrome.title, action: "Rename") { [weak self] name in
            guard let self, name != chrome.title else { return }
            performRename(to: name)
        }
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
            // The print options are a popover that doesn't go through `present`.
            toolPicker.setVisible(false, forFirstResponder: self)
            for canvas in canvases.values { toolPicker.setVisible(false, forFirstResponder: canvas) }
            printer.present(from: titleAnchor, in: view, animated: true) { [weak self] _, _, _ in
                self?.syncPalette()
            }
        }
    }

    private func showAlert(_ title: String, message: String?) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: Images

    private func pickPhoto() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func pickImageFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func insert(_ image: UIImage) {
        chrome.mode = .scroll
        objectEditor.insertImage(image)
        syncPalette()
    }

    // MARK: Pages

    private var currentPageIndex: Int {
        guard let page = pdfView.currentPage, let index = document.index(of: page) else {
            return max(document.pdf.pageCount - 1, 0)
        }
        return index
    }

    private func addPage(_ source: PageSource) {
        let size = pdfView.currentPage?.bounds(for: .cropBox).size ?? PageTemplate.a4
        guard let page = source.makePage(size: size) else { return }
        document.insert(page, at: currentPageIndex + 1)
        pdfView.go(to: page)
    }

    private func duplicate(_ page: PDFPage) {
        if let copy = document.duplicate(page) { pdfView.go(to: copy) }
    }

    private func toggleBookmark(_ page: PDFPage) {
        if let existing = document.bookmark(for: page) {
            document.removeBookmark(existing)
        } else {
            let number = (document.index(of: page) ?? 0) + 1
            promptText(title: "Bookmark page \(number)", initial: "Page \(number)", action: "Add") { [weak self] label in
                self?.document.addBookmark(for: page, label: label)
            }
        }
    }

    private func saveAsTemplate(_ page: PDFPage) {
        promptText(title: "Save as template",
                   message: "The page, including its handwriting, becomes a template for new pages and notebooks.",
                   initial: "My Template", action: "Save") { [weak self] name in
            guard let self else { return }
            do {
                try TemplateLibrary.shared.save(document.flattenedTemplateData(for: page), named: name)
                chrome.customTemplates = TemplateLibrary.shared.all()
            } catch {
                showAlert("Couldn't save the template", message: error.localizedDescription)
            }
        }
    }

    private func confirmDeleteTemplate(_ template: CustomTemplate) {
        let alert = UIAlertController(title: "Delete “\(template.name)”?",
                                      message: "Pages already made from it aren't affected.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            try? TemplateLibrary.shared.delete(template)
            self?.chrome.customTemplates = TemplateLibrary.shared.all()
        })
        present(alert, animated: true)
    }

    private func confirmDelete(_ page: PDFPage) {
        guard document.pdf.pageCount > 1 else {
            showAlert("Can't delete the only page", message: nil)
            return
        }
        let number = (document.index(of: page) ?? 0) + 1
        let alert = UIAlertController(title: "Delete page \(number)?", message: "You can undo this.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.document.remove(page)
        })
        present(alert, animated: true)
    }

    /// The long-press menu for a page in the sidebar.
    private func pageMenu(for page: PDFPage) -> UIMenu {
        let bookmarked = document.bookmark(for: page) != nil
        return UIMenu(children: [
            UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                self?.duplicate(page)
            },
            UIAction(title: bookmarked ? "Remove Bookmark" : "Bookmark",
                     image: UIImage(systemName: bookmarked ? "bookmark.slash" : "bookmark")) { [weak self] _ in
                self?.toggleBookmark(page)
            },
            UIAction(title: "Save as Template…", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                self?.saveAsTemplate(page)
            },
            UIAction(title: "Delete…", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.confirmDelete(page)
            },
        ])
    }

    private func toggleSidebar() {
        chrome.isSidebarVisible.toggle()
        let show = chrome.isSidebarVisible
        // Settle the current layout first, so the panel animates from the left edge rather than
        // from wherever its zero-sized frame last was.
        view.layoutIfNeeded()
        if show { sidebar.reloadPages() }
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.sidebar.isHidden = !show
            self.sidebar.alpha = show ? 1 : 0
            self.view.layoutIfNeeded()
        }
    }

    private func pagesDidChange() {
        pdfView.layoutDocumentView()
        sidebar.reloadPages()
        updatePageState()
    }

    private func updatePageState() {
        let page = pdfView.currentPage
        chrome.isCurrentPageBookmarked = page.flatMap { document.bookmark(for: $0) } != nil
        sidebar.currentPage = page
    }

    // MARK: Closing

    func close(completion: (() -> Void)? = nil) {
        guard !isClosing else { return }
        isClosing = true
        objectEditor.endEditing()
        syncPalette() // isClosing hides it
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
    // The palette is only on screen in draw mode, so a tool change never needs to switch modes.
    // (Restoring the saved tool fires this on open too, which used to start notebooks in draw mode.)
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
        canvas.isUserInteractionEnabled = chrome.mode == .draw
        canvas.delegate = self // after loading the drawing, so opening doesn't mark the file edited
        toolPicker.addObserver(canvas) // follows the palette's tool and ruler
        toolPicker.setVisible(chrome.mode == .draw, forFirstResponder: canvas)
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
        sidebar.invalidateThumbnail(for: page)
    }
}

// MARK: - Image pickers

extension NotebookViewController: PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
            syncPalette()
            return
        }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }
            DispatchQueue.main.async { self?.insert(image) }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let image = UIImage(contentsOfFile: url.path) else {
            syncPalette()
            return
        }
        insert(image)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        syncPalette()
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

/// An invisible view placed inside a presented screen that reports when that screen leaves the
/// window, i.e. when it has been dismissed by any route.
private final class PresentationEndWatcher: UIView {
    private var onEnd: (() -> Void)?
    private var wasOnScreen = false

    static func attach(to controller: UIViewController, onEnd: @escaping () -> Void) {
        let watcher = PresentationEndWatcher(frame: .zero)
        watcher.onEnd = onEnd
        watcher.isHidden = true
        watcher.isUserInteractionEnabled = false
        watcher.isAccessibilityElement = false
        controller.view.addSubview(watcher)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { wasOnScreen = true; return }
        guard wasOnScreen, let onEnd else { return }
        self.onEnd = nil
        // Let UIKit finish clearing `presentedViewController` first.
        DispatchQueue.main.async { onEnd() }
        removeFromSuperview()
    }
}

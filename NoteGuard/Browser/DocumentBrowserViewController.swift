import UIKit
import UniformTypeIdentifiers

/// The app's home screen: the system Files browser, limited to PDFs.
/// Documents are opened and saved *in place*, wherever they live (iCloud Drive, On My iPad, Dropbox…).
final class DocumentBrowserViewController: UIDocumentBrowserViewController, UIDocumentBrowserViewControllerDelegate {
    private var didOfferZoneSetup = false

    init() {
        super.init(forOpening: [.pdf])
        delegate = self
        allowsDocumentCreation = true
        allowsPickingMultipleItems = false
        additionalTrailingNavigationBarButtonItems = [
            {
                let item = UIBarButtonItem(image: UIImage(systemName: "shield"), primaryAction: nil,
                                           menu: ZoneEditorPresenter.makeMenu(presentingFrom: self))
                item.accessibilityLabel = "Touch shield"
                return item
            }(),
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // First launch on this device: ask once whether any of the screen needs masking. Only a
        // "yes" opens the editor; after that it lives in the shield menu.
        let store = DeadZoneStore.shared
        if !didOfferZoneSetup, !store.hasShownSetup, store.shapes.isEmpty {
            didOfferZoneSetup = true
            store.hasShownSetup = true
            ZoneEditorPresenter.askOnFirstLaunch(from: self)
        }
    }

    // MARK: Opening

    func openDocument(at url: URL) {
        if let presented = presentedViewController {
            if let open = presented as? NotebookViewController {
                open.close { [weak self] in self?.openDocument(at: url) }
            } else if presented.isBeingDismissed {
                // e.g. the template chooser is still animating away.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.openDocument(at: url) }
            } else {
                presented.dismiss(animated: true) { [weak self] in self?.openDocument(at: url) }
            }
            return
        }

        let accessing = url.startAccessingSecurityScopedResource()
        let document = NoteDocument(fileURL: url)
        Task { [weak self] in
            let success = await document.open()
            guard let self else { return }
            guard success else {
                if accessing { url.stopAccessingSecurityScopedResource() }
                showError("Couldn't open “\(url.lastPathComponent)”. It may not be a valid PDF.")
                return
            }
            let notebook = NotebookViewController(
                document: document,
                rename: { [weak self] url, name, completion in self?.renameDocument(at: url, to: name, completion: completion) },
                onClosed: { if accessing { url.stopAccessingSecurityScopedResource() } }
            )
            present(notebook, animated: true)
        }
    }

    /// Renames through the browser so it works for files in any location the browser can reach.
    /// The open document is a file presenter, so it follows the file to its new name.
    private func renameDocument(at url: URL, to name: String, completion: @escaping (Result<URL, Error>) -> Void) {
        renameDocument(at: url, proposedName: name) { finalURL, error in
            DispatchQueue.main.async {
                if let finalURL {
                    completion(.success(finalURL))
                } else {
                    completion(.failure(error ?? CocoaError(.fileWriteUnknown)))
                }
            }
        }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Something went wrong", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: UIDocumentBrowserViewControllerDelegate

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt documentURLs: [URL]) {
        if let url = documentURLs.first { openDocument(at: url) }
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController,
                         didRequestDocumentCreationWithHandler importHandler: @escaping (URL?, UIDocumentBrowserViewController.ImportMode) -> Void) {
        let chooser = UIAlertController(title: "New notebook", message: "Choose a page style. You can add pages of any style later.", preferredStyle: .alert)
        let sources = PageTemplate.allCases.map(PageSource.builtIn) + TemplateLibrary.shared.all().map(PageSource.custom)
        for source in sources {
            chooser.addAction(UIAlertAction(title: source.title, style: .default) { _ in
                do {
                    importHandler(try source.makeNotebookFile(), .move)
                } catch {
                    importHandler(nil, .none)
                }
            })
        }
        chooser.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in importHandler(nil, .none) })
        present(chooser, animated: true)
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didImportDocumentAt sourceURL: URL, toDestinationURL destinationURL: URL) {
        openDocument(at: destinationURL)
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, failedToImportDocumentAt documentURL: URL, error: Error?) {
        showError("Couldn't create the notebook. \(error?.localizedDescription ?? "")")
    }
}

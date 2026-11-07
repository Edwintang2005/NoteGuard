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
            UIBarButtonItem(title: "Shield", image: UIImage(systemName: "checkmark.shield"),
                            primaryAction: nil, menu: ZoneEditorPresenter.makeMenu(presentingFrom: self)),
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // First launch: map the crack before anything else.
        if !didOfferZoneSetup, DeadZoneStore.shared.shapes.isEmpty {
            didOfferZoneSetup = true
            ZoneEditorPresenter.present(from: self)
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
            let notebook = NotebookViewController(document: document) {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            present(notebook, animated: true)
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
        for template in PageTemplate.allCases {
            chooser.addAction(UIAlertAction(title: template.title, style: .default) { _ in
                do {
                    importHandler(try template.makeNotebookFile(), .move)
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

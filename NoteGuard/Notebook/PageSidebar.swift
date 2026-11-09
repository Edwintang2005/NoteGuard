import UIKit
import PDFKit
import PencilKit

/// Side panel with two tabs:
/// - **Pages**: thumbnails that include handwriting. Tap to jump, drag to reorder, long-press for
///   Duplicate / Bookmark / Save as Template / Delete.
/// - **Bookmarks**: the PDF outline (yours plus any the PDF came with). Tap to jump, swipe to remove.
final class PageSidebar: UIView {
    var onSelect: ((PDFPage) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var menuProvider: ((PDFPage) -> UIMenu)?
    var onRemoveBookmark: ((PDFOutline) -> Void)?

    var currentPage: PDFPage? {
        didSet {
            guard currentPage !== oldValue else { return }
            updateHighlight()
        }
    }

    private let document: NoteDocument
    private let tabs = UISegmentedControl(items: ["Pages", "Bookmarks"])
    private let pages: UICollectionView
    private let bookmarkList = UITableView(frame: .zero, style: .plain)
    private var bookmarks: [NoteDocument.Bookmark] = []

    private var thumbnails: [ObjectIdentifier: UIImage] = [:]
    private var pendingInvalidations = Set<ObjectIdentifier>()
    private var invalidationTimer: Timer?

    static let width: CGFloat = 170
    private let thumbnailWidth: CGFloat = 120

    init(document: NoteDocument) {
        self.document = document
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 14
        layout.sectionInset = UIEdgeInsets(top: 12, left: 0, bottom: 24, right: 0)
        pages = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)

        backgroundColor = .systemBackground
        clipsToBounds = true // while it slides in, nothing spills over the page
        let divider = UIView()
        divider.backgroundColor = .separator

        tabs.selectedSegmentIndex = 0
        tabs.addTarget(self, action: #selector(tabChanged), for: .valueChanged)

        pages.backgroundColor = .clear
        pages.register(PageCell.self, forCellWithReuseIdentifier: PageCell.reuseID)
        pages.dataSource = self
        pages.delegate = self
        pages.dragDelegate = self
        pages.dropDelegate = self
        pages.dragInteractionEnabled = true

        bookmarkList.dataSource = self
        bookmarkList.delegate = self
        bookmarkList.isHidden = true
        bookmarkList.backgroundColor = .clear

        for view in [divider, tabs, pages, bookmarkList] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 0.5),
            tabs.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pages.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
            pages.leadingAnchor.constraint(equalTo: leadingAnchor),
            pages.trailingAnchor.constraint(equalTo: trailingAnchor),
            pages.bottomAnchor.constraint(equalTo: bottomAnchor),
            bookmarkList.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
            bookmarkList.leadingAnchor.constraint(equalTo: leadingAnchor),
            bookmarkList.trailingAnchor.constraint(equalTo: trailingAnchor),
            bookmarkList.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        reloadBookmarks()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Updates

    func reloadPages() {
        pages.reloadData()
        updateHighlight()
    }

    func reloadBookmarks() {
        bookmarks = document.bookmarks
        bookmarkList.reloadData()
    }

    /// Marks a page's thumbnail stale. Redraws are batched so fast writing doesn't thrash.
    func invalidateThumbnail(for page: PDFPage) {
        pendingInvalidations.insert(ObjectIdentifier(page))
        guard invalidationTimer == nil else { return }
        let timer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushInvalidations() }
        }
        RunLoop.main.add(timer, forMode: .common)
        invalidationTimer = timer
    }

    private func flushInvalidations() {
        invalidationTimer = nil
        guard !isHidden else { return } // thumbnails rebuild lazily when shown
        var paths: [IndexPath] = []
        for key in pendingInvalidations {
            thumbnails[key] = nil
            if let index = (0..<document.pdf.pageCount).first(where: { document.pdf.page(at: $0).map(ObjectIdentifier.init) == key }) {
                paths.append(IndexPath(item: index, section: 0))
            }
        }
        pendingInvalidations.removeAll()
        let visible = Set(pages.indexPathsForVisibleItems)
        let toReload = paths.filter(visible.contains)
        if !toReload.isEmpty { pages.reloadItems(at: toReload) }
    }

    override var isHidden: Bool {
        didSet {
            guard !isHidden, oldValue else { return }
            for key in pendingInvalidations { thumbnails[key] = nil }
            pendingInvalidations.removeAll()
            reloadPages()
        }
    }

    private func updateHighlight() {
        for cell in pages.visibleCells {
            guard let cell = cell as? PageCell, let path = pages.indexPath(for: cell) else { continue }
            cell.isCurrent = document.pdf.page(at: path.item) === currentPage
        }
        if let currentPage, let index = document.index(of: currentPage), !isHidden {
            let path = IndexPath(item: index, section: 0)
            if !pages.indexPathsForVisibleItems.contains(path) {
                pages.scrollToItem(at: path, at: .centeredVertically, animated: true)
            }
        }
    }

    @objc private func tabChanged() {
        let showingPages = tabs.selectedSegmentIndex == 0
        pages.isHidden = !showingPages
        bookmarkList.isHidden = showingPages
        if !showingPages { reloadBookmarks() }
    }

    // MARK: Thumbnails

    private func thumbnail(for page: PDFPage) -> UIImage {
        let key = ObjectIdentifier(page)
        if let cached = thumbnails[key] { return cached }
        let image = Self.renderThumbnail(page: page, drawing: document.drawings[key], width: thumbnailWidth,
                                         screenScale: traitCollection.displayScale)
        thumbnails[key] = image
        return image
    }

    /// The page (with its text boxes and images) plus its handwriting, at `width` points wide.
    static func renderThumbnail(page: PDFPage, drawing: PKDrawing?, width: CGFloat, screenScale: CGFloat) -> UIImage {
        let crop = page.bounds(for: .cropBox)
        let scale = width / max(crop.width, 1)
        let size = CGSize(width: width, height: (crop.height * scale).rounded())
        let base = page.thumbnail(of: CGSize(width: size.width * screenScale, height: size.height * screenScale), for: .cropBox)
        var ink: UIImage?
        if let drawing, !drawing.strokes.isEmpty {
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                ink = drawing.image(from: CGRect(origin: .zero, size: crop.size), scale: scale * screenScale)
            }
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = screenScale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            base.draw(in: CGRect(origin: .zero, size: size))
            ink?.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Pages tab

extension PageSidebar: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        document.pdf.pageCount
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PageCell.reuseID, for: indexPath) as! PageCell
        if let page = document.pdf.page(at: indexPath.item) {
            cell.configure(image: thumbnail(for: page), number: indexPath.item + 1,
                           bookmarked: document.bookmark(for: page) != nil)
            cell.isCurrent = page === currentPage
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let crop = document.pdf.page(at: indexPath.item)?.bounds(for: .cropBox) ?? CGRect(origin: .zero, size: PageTemplate.a4)
        let height = thumbnailWidth * crop.height / max(crop.width, 1)
        return CGSize(width: Self.width - 20, height: height + PageCell.labelHeight)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if let page = document.pdf.page(at: indexPath.item) { onSelect?(page) }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let path = indexPaths.first, let page = document.pdf.page(at: path.item), let menuProvider else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in menuProvider(page) })
    }
}

extension PageSidebar: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = indexPath.item
        return [item]
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                        withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        session.localDragSession != nil
            ? UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
            : UICollectionViewDropProposal(operation: .forbidden)
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let item = coordinator.items.first, let source = item.sourceIndexPath else { return }
        let last = max(document.pdf.pageCount - 1, 0)
        let destination = min(coordinator.destinationIndexPath?.item ?? last, last)
        guard destination != source.item else { return }
        onMove?(source.item, destination) // the document reports back and the list reloads
        coordinator.drop(item.dragItem, toItemAt: IndexPath(item: destination, section: 0))
    }
}

// MARK: - Bookmarks tab

extension PageSidebar: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(bookmarks.count, 1)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "bookmark") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "bookmark")
        var content = cell.defaultContentConfiguration()
        if bookmarks.isEmpty {
            content.text = "No bookmarks"
            content.secondaryText = "Use Pages → Bookmark This Page"
            content.textProperties.color = .secondaryLabel
            cell.selectionStyle = .none
        } else {
            let bookmark = bookmarks[indexPath.row]
            content.text = bookmark.label
            content.textProperties.numberOfLines = 2
            content.secondaryText = "Page \((document.index(of: bookmark.page) ?? 0) + 1)"
            content.image = UIImage(systemName: bookmark.depth == 0 ? "bookmark.fill" : "chevron.right")
            content.imageProperties.tintColor = .systemOrange
            content.directionalLayoutMargins.leading = 8 + CGFloat(bookmark.depth) * 14
            cell.selectionStyle = .default
        }
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !bookmarks.isEmpty else { return }
        onSelect?(bookmarks[indexPath.row].page)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !bookmarks.isEmpty else { return nil }
        let outline = bookmarks[indexPath.row].outline
        let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
            self?.onRemoveBookmark?(outline)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }
}

// MARK: - Cell

private final class PageCell: UICollectionViewCell {
    static let reuseID = "page"
    static let labelHeight: CGFloat = 22

    private let imageView = UIImageView()
    private let label = UILabel()
    private let bookmark = UIImageView(image: UIImage(systemName: "bookmark.fill"))

    var isCurrent = false {
        didSet {
            imageView.layer.borderColor = (isCurrent ? UIColor.systemBlue : UIColor.separator).cgColor
            imageView.layer.borderWidth = isCurrent ? 2.5 : 0.5
            label.textColor = isCurrent ? .systemBlue : .secondaryLabel
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.layer.cornerRadius = 4
        imageView.clipsToBounds = true
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textAlignment = .center
        bookmark.tintColor = .systemOrange
        for view in [imageView, label, bookmark] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 120),
            imageView.bottomAnchor.constraint(equalTo: label.topAnchor),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            label.heightAnchor.constraint(equalToConstant: Self.labelHeight),
            bookmark.topAnchor.constraint(equalTo: imageView.topAnchor, constant: -2),
            bookmark.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -6),
        ])
        isCurrent = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(image: UIImage, number: Int, bookmarked: Bool) {
        imageView.image = image
        label.text = "\(number)"
        bookmark.isHidden = !bookmarked
    }
}

import SwiftUI

struct NotebookActions {
    var close: () -> Void
    var undo: () -> Void
    var redo: () -> Void
    var rename: () -> Void
    var share: () -> Void
    var print: () -> Void
    var insertTextBox: () -> Void
    var insertPhoto: () -> Void
    var insertImageFile: () -> Void
    var addPage: (PageSource) -> Void
    var duplicatePage: () -> Void
    var toggleBookmark: () -> Void
    var saveTemplate: () -> Void
    var deleteTemplate: (CustomTemplate) -> Void
    var deletePage: () -> Void
    var toggleSidebar: () -> Void
    var editZones: () -> Void
}

/// Document bar: title menu, interaction modes (scroll, draw, laser), insert, undo/redo, pages,
/// sidebar and the shield. The pen opens the system tool palette, which you can move anywhere.
struct NotebookToolbar: View {
    @ObservedObject var chrome: NotebookChrome
    @ObservedObject var store: DeadZoneStore
    let actions: NotebookActions

    var body: some View {
        bar
            .frame(maxWidth: .infinity) // centred in the full-width host
    }

    private var bar: some View {
        HStack(spacing: 16) {
            Button(action: actions.close) {
                Image(systemName: "chevron.backward")
            }
            .accessibilityLabel("Save and close")

            Menu {
                Button("Rename…", systemImage: "pencil", action: actions.rename)
                Button("Share…", systemImage: "square.and.arrow.up", action: actions.share)
                Button("Print…", systemImage: "printer", action: actions.print)
            } label: {
                HStack(spacing: 4) {
                    Text(chrome.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.subheadline)
                }
            }
            .layoutPriority(1)
            .accessibilityLabel("Document menu, \(chrome.title)")

            Divider().frame(height: 24)

            modeButton(.scroll, symbol: "hand.raised", label: "Scroll, and move text boxes and images")
            modeButton(.draw, symbol: "pencil.tip.crop.circle", label: "Draw and annotate")
            laserButton

            Menu {
                Button("Text Box", systemImage: "character.textbox", action: actions.insertTextBox)
                Button("Photo…", systemImage: "photo", action: actions.insertPhoto)
                Button("Image from Files…", systemImage: "folder", action: actions.insertImageFile)
                Divider()
                Menu("Page After This One", systemImage: "doc.badge.plus") {
                    ForEach(PageTemplate.allCases) { template in
                        Button(template.title, systemImage: template.symbol) { actions.addPage(.builtIn(template)) }
                    }
                    if !chrome.customTemplates.isEmpty {
                        Section("My Templates") {
                            ForEach(chrome.customTemplates) { template in
                                Button(template.name, systemImage: "doc.richtext") { actions.addPage(.custom(template)) }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "plus.circle")
            }
            .accessibilityLabel("Insert")

            Button(action: actions.undo) { Image(systemName: "arrow.uturn.backward") }
                .accessibilityLabel("Undo")
            Button(action: actions.redo) { Image(systemName: "arrow.uturn.forward") }
                .accessibilityLabel("Redo")

            pagesMenu

            Button(action: actions.toggleSidebar) {
                Image(systemName: "sidebar.leading")
                    .symbolVariant(chrome.isSidebarVisible ? .fill : .none)
            }
            .accessibilityLabel("Pages and bookmarks")

            ShieldMenu(store: store, onEditZones: actions.editZones)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }

    /// Tap: laser on or off. Long-press: choose fading lines or a plain dot.
    private var laserButton: some View {
        let active = chrome.mode == .laser
        return Menu {
            Picker("Laser Style", selection: $chrome.laserStyle) {
                ForEach(LaserStyle.allCases) { style in
                    Label(style.title, systemImage: style.symbol).tag(style)
                }
            }
        } label: {
            Image(systemName: chrome.laserStyle.symbol)
                .symbolVariant(active ? .fill : .none)
                .padding(6)
                .background(active ? Color.accentColor.opacity(0.18) : .clear, in: .circle)
        } primaryAction: {
            chrome.mode = active ? .scroll : .laser
        }
        .accessibilityLabel("Laser pointer, \(chrome.laserStyle.title). Long-press to change.")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// Tapping the active mode again (pen or laser) goes back to scrolling, which closes the palette.
    private func modeButton(_ mode: InteractionMode, symbol: String, label: String) -> some View {
        Button {
            chrome.mode = chrome.mode == mode ? .scroll : mode
        } label: {
            Image(systemName: symbol)
                .symbolVariant(chrome.mode == mode ? .fill : .none)
                .padding(6)
                .background(chrome.mode == mode ? Color.accentColor.opacity(0.18) : .clear, in: .circle)
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(chrome.mode == mode ? .isSelected : [])
    }

    private var pagesMenu: some View {
        Menu {
            Button("Duplicate This Page", systemImage: "plus.square.on.square", action: actions.duplicatePage)
            Button(chrome.isCurrentPageBookmarked ? "Remove Bookmark" : "Bookmark This Page",
                   systemImage: chrome.isCurrentPageBookmarked ? "bookmark.slash" : "bookmark",
                   action: actions.toggleBookmark)
            Button("Save Page as Template…", systemImage: "square.and.arrow.down", action: actions.saveTemplate)
            if !chrome.customTemplates.isEmpty {
                Menu("Delete a Template", systemImage: "trash") {
                    ForEach(chrome.customTemplates) { template in
                        Button(template.name, role: .destructive) { actions.deleteTemplate(template) }
                    }
                }
            }
            Divider()
            Button("Delete This Page…", systemImage: "trash", role: .destructive, action: actions.deletePage)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .accessibilityLabel("Pages")
    }
}

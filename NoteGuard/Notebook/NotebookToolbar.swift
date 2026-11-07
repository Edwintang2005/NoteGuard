import SwiftUI

struct NotebookActions {
    var close: () -> Void
    var undo: () -> Void
    var redo: () -> Void
    var rename: () -> Void
    var share: () -> Void
    var print: () -> Void
    var togglePalette: () -> Void
    var addPage: (PageTemplate) -> Void
    var deletePage: () -> Void
    var toggleThumbnails: () -> Void
    var editZones: () -> Void
}

/// Document bar: title menu, scroll/palette toggles, undo/redo, pages, thumbnails and the shield.
/// The drawing tools themselves live in the system palette, which you can move anywhere.
struct NotebookToolbar: View {
    @ObservedObject var chrome: NotebookChrome
    @ObservedObject var store: DeadZoneStore
    let actions: NotebookActions

    var body: some View {
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
            .layoutPriority(-1)
            .accessibilityLabel("Document menu, \(chrome.title)")

            Divider().frame(height: 24)

            Button {
                chrome.isScrollMode.toggle()
            } label: {
                Image(systemName: chrome.isScrollMode ? "hand.raised.fill" : "hand.raised")
            }
            .accessibilityLabel(chrome.isScrollMode ? "Scroll mode on" : "Scroll mode off")

            Button(action: actions.togglePalette) {
                Image(systemName: chrome.isPaletteVisible ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
            }
            .accessibilityLabel(chrome.isPaletteVisible ? "Hide tools" : "Show tools")

            Button(action: actions.undo) { Image(systemName: "arrow.uturn.backward") }
                .accessibilityLabel("Undo")
            Button(action: actions.redo) { Image(systemName: "arrow.uturn.forward") }
                .accessibilityLabel("Redo")

            Menu {
                Section("Add page after this one") {
                    ForEach(PageTemplate.allCases) { template in
                        Button(template.title, systemImage: template.symbol) { actions.addPage(template) }
                    }
                }
                Button("Delete this page…", systemImage: "trash", role: .destructive, action: actions.deletePage)
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .accessibilityLabel("Pages")

            Button(action: actions.toggleThumbnails) { Image(systemName: "sidebar.trailing") }
                .accessibilityLabel("Page thumbnails")

            ShieldMenu(store: store, onEditZones: actions.editZones)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}

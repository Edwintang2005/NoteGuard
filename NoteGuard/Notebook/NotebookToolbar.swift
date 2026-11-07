import SwiftUI

struct NotebookActions {
    var close: () -> Void
    var undo: () -> Void
    var redo: () -> Void
    var addPage: (PageTemplate) -> Void
    var deletePage: () -> Void
    var toggleThumbnails: () -> Void
    var editZones: () -> Void
}

struct NotebookToolbar: View {
    @ObservedObject var tools: InkToolState
    @ObservedObject var store: DeadZoneStore
    let title: String
    let actions: NotebookActions

    var body: some View {
        HStack(spacing: 14) {
            Button(action: actions.close) {
                Label("Files", systemImage: "chevron.backward")
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Save and close")

            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)

            Divider().frame(height: 24)

            Picker("Tool", selection: $tools.tool) {
                ForEach(InkToolState.Tool.allCases) { tool in
                    Image(systemName: tool.symbol).tag(tool)
                        .accessibilityLabel(tool.label)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)

            HStack(spacing: 8) {
                ForEach(InkToolState.inks.indices, id: \.self) { i in
                    Button { tools.colorIndex = i } label: {
                        Circle()
                            .fill(Color(uiColor: InkToolState.inks[i]))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(.primary, lineWidth: tools.colorIndex == i ? 2.5 : 0).padding(-4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .opacity(tools.tool.usesColor ? 1 : 0.35)
            .disabled(!tools.tool.usesColor)

            Divider().frame(height: 24)

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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}

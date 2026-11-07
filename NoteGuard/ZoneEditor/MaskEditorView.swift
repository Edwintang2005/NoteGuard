import SwiftUI

/// Full-screen editor for mapping the cracked area. The shield is paused while this is open.
struct MaskEditorView: View {
    @EnvironmentObject private var store: DeadZoneStore
    @StateObject private var editor = EditorState()
    @Environment(\.dismiss) private var dismiss
    @State private var panelAtTop = true
    /// Called by Done when presented from UIKit; falls back to SwiftUI dismissal.
    var onDone: (() -> Void)?

    var body: some View {
        ZStack(alignment: panelAtTop ? .top : .bottom) {
            MaskEditorCanvasView(store: store, editor: editor)
                .ignoresSafeArea()
            panel
                .padding()
        }
        .onAppear { store.isEditing = true }
        .onDisappear { store.isEditing = false }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Dead zones").font(.headline)

                Picker("New zone shape", selection: $editor.tool) {
                    Image(systemName: "scribble").tag(DeadZoneShape.Kind.freehand)
                        .accessibilityLabel("Freehand")
                    Image(systemName: "rectangle").tag(DeadZoneShape.Kind.rectangle)
                        .accessibilityLabel("Rectangle")
                    Image(systemName: "oval").tag(DeadZoneShape.Kind.ellipse)
                        .accessibilityLabel("Ellipse")
                }
                .pickerStyle(.segmented)
                .frame(width: 170)

                Spacer(minLength: 8)

                Button(role: .destructive) {
                    store.shapes.removeAll { $0.id == editor.selectedID }
                    editor.selectedID = nil
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(editor.selectedID == nil)

                Button("Clear all", role: .destructive) {
                    store.shapes.removeAll()
                    editor.selectedID = nil
                }
                .disabled(store.shapes.isEmpty)

                Button {
                    withAnimation(.snappy) { panelAtTop.toggle() }
                } label: {
                    Image(systemName: panelAtTop ? "arrow.down.to.line" : "arrow.up.to.line")
                }
                .accessibilityLabel(panelAtTop ? "Move panel to bottom" : "Move panel to top")

                Button("Done") {
                    if let onDone { onDone() } else { dismiss() }
                }
                    .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 12) {
                Text("Padding")
                Slider(value: $store.padding, in: 0...40, step: 1)
                Text("\(Int(store.padding)) pt")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }

            Text("Freehand: trace any outline around the crack. Rectangle or ellipse: drag across the area. Drag a zone to move it, or the corner handles of the selected zone to resize it. The shield is paused while you edit.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: 620)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

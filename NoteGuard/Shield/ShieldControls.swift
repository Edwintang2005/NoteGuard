import UIKit
import SwiftUI

/// Presents the full-screen dead-zone editor from anywhere in the app.
enum ZoneEditorPresenter {
    static func present(from presenter: UIViewController) {
        var top = presenter
        while let next = top.presentedViewController { top = next }

        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(
            MaskEditorView(onDone: { [weak host] in host?.dismiss(animated: true) })
                .environmentObject(DeadZoneStore.shared)
        )
        host.modalPresentationStyle = .fullScreen
        top.present(host, animated: true)
    }

    /// The one-time question on first launch. Most people have a working screen, so nothing about
    /// masking is set up unless they say part of theirs misbehaves.
    static func askOnFirstLaunch(from presenter: UIViewController) {
        let alert = UIAlertController(
            title: "Is part of your screen unreliable?",
            message: "If a crack or damaged area registers touches you didn't make, NoteGuard can ignore touches in that part of the screen. You can set this up later from the shield button too.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "No, My Screen Is Fine", style: .cancel))
        alert.addAction(UIAlertAction(title: "Mask Off Part of the Screen", style: .default) { [weak presenter] _ in
            if let presenter { present(from: presenter) }
        })
        presenter.present(alert, animated: true)
    }

    /// A menu for UIKit bars. With no masked areas it offers only to set one up.
    static func makeMenu(presentingFrom presenter: UIViewController) -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak presenter] completion in
                let store = DeadZoneStore.shared
                guard !store.shapes.isEmpty else {
                    completion([
                        UIAction(title: "Mask Off Part of the Screen…", image: UIImage(systemName: "square.dashed")) { _ in
                            if let presenter { present(from: presenter) }
                        },
                    ])
                    return
                }
                completion([
                    UIAction(title: "Shield on", state: store.isEnabled ? .on : .off) { _ in
                        store.isEnabled.toggle()
                    },
                    UIAction(title: "Show zones & blocked touches", state: store.showsZones ? .on : .off) { _ in
                        store.showsZones.toggle()
                    },
                    UIAction(title: "Edit dead zones…", image: UIImage(systemName: "square.dashed")) { _ in
                        if let presenter { present(from: presenter) }
                    },
                    UIAction(title: "Reset blocked counter (\(store.blockedCount))",
                             image: UIImage(systemName: "arrow.counterclockwise")) { _ in
                        store.resetBlockedCount()
                    },
                ])
            },
        ])
    }
}

/// The shield status + settings menu for SwiftUI toolbars. For people who haven't masked anything
/// it's a plain, quiet icon whose menu only offers to set masking up.
struct ShieldMenu: View {
    @ObservedObject var store: DeadZoneStore
    let onEditZones: () -> Void

    var body: some View {
        Menu {
            if store.shapes.isEmpty {
                Button("Mask Off Part of the Screen…", systemImage: "square.dashed", action: onEditZones)
            } else {
                Toggle("Shield on", isOn: $store.isEnabled)
                Toggle("Show zones & blocked touches", isOn: $store.showsZones)
                Button("Edit dead zones…", systemImage: "square.dashed", action: onEditZones)
                Button("Reset blocked counter", systemImage: "arrow.counterclockwise") { store.resetBlockedCount() }
            }
        } label: {
            if store.shapes.isEmpty {
                Image(systemName: "shield")
            } else {
                HStack(spacing: 6) {
                    Image(systemName: store.isEnabled ? "checkmark.shield.fill" : "shield.slash")
                        .foregroundStyle(store.isEnabled ? Color.green : Color.secondary)
                    Text(store.isEnabled ? "\(store.blockedCount)" : "Off")
                        .monospacedDigit()
                }
            }
        }
        .accessibilityLabel(store.shapes.isEmpty ? "Mask off part of the screen" : "Dead-zone shield")
    }

}

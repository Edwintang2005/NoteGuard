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

    /// A menu for UIKit bars: shield on/off, show zones, edit zones.
    static func makeMenu(presentingFrom presenter: UIViewController) -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak presenter] completion in
                let store = DeadZoneStore.shared
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

/// The shield status + settings menu for SwiftUI toolbars.
struct ShieldMenu: View {
    @ObservedObject var store: DeadZoneStore
    let onEditZones: () -> Void

    var body: some View {
        Menu {
            Toggle("Shield on", isOn: $store.isEnabled)
            Toggle("Show zones & blocked touches", isOn: $store.showsZones)
            Button("Edit dead zones…", systemImage: "square.dashed", action: onEditZones)
            Button("Reset blocked counter", systemImage: "arrow.counterclockwise") { store.resetBlockedCount() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isActive ? "checkmark.shield.fill" : "exclamationmark.shield")
                    .foregroundStyle(isActive ? Color.green : Color.orange)
                Text(isActive ? "\(store.blockedCount)" : (store.isEnabled ? "No zones" : "Off"))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel("Dead-zone shield")
    }

    private var isActive: Bool { store.isEnabled && !store.shapes.isEmpty }
}

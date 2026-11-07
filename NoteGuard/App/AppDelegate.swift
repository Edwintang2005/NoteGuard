import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let browser = DocumentBrowserViewController()
    /// Sits above every other window in this scene and swallows touches that start inside a dead zone.
    private var shieldWindow: ShieldWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        self.window = window

        shieldWindow = ShieldWindow(windowScene: windowScene, store: .shared)

        if let url = connectionOptions.urlContexts.first?.url { open(url) }
    }

    /// Rotation, Split View and Stage Manager resizes: refit the shield around the zones.
    func windowScene(_ windowScene: UIWindowScene, didUpdateEffectiveGeometry previousEffectiveGeometry: UIWindowScene.Geometry) {
        shieldWindow?.updateFrame()
    }

    /// "Open in NoteGuard" from the Files app or another app.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url { open(url) }
    }

    private func open(_ url: URL) {
        browser.revealDocument(at: url, importIfNeeded: true) { [weak browser] revealedURL, _ in
            guard let revealedURL else { return }
            DispatchQueue.main.async { browser?.openDocument(at: revealedURL) }
        }
    }
}

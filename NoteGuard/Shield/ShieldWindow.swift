import UIKit
import Combine

/// A transparent window that floats above the whole app.
///
/// Hit-testing is the trick: for a point inside a dead zone this window claims the touch and
/// quietly discards it; for any other point it returns `nil`, so UIKit hands the touch to the
/// app's real window underneath. Because blocked touches land in a *different window*, they
/// can't disturb a stroke, scroll or gesture that is already in progress in the app.
///
/// Only touches that *start* in a zone are blocked. A stylus stroke that begins outside and
/// drifts into a zone keeps going.
///
/// The window is sized to exactly the zones' bounding box, never the whole screen. Some system UI
/// — notably the Files browser — runs in another process, and the system won't deliver touches
/// to it through a window above it, even a pass-through one, so any margin here would be dead.
final class ShieldWindow: UIWindow {
    private let store: DeadZoneStore
    private let overlay: ShieldOverlayView
    private var cancellables = Set<AnyCancellable>()

    init(windowScene: UIWindowScene, store: DeadZoneStore) {
        self.store = store
        self.overlay = ShieldOverlayView(store: store)
        super.init(windowScene: windowScene)
        windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        backgroundColor = .clear
        clipsToBounds = false // blocked-touch flashes can spill past the zone's edge
        rootViewController = ShieldViewController(overlay: overlay)

        // objectWillChange fires before the change lands, so update on the next turn.
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateFrame() }
            .store(in: &cancellables)
        updateFrame()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Fits the window around the zones in the scene's current orientation and size.
    /// Call again whenever the scene rotates or resizes.
    func updateFrame() {
        guard let scene = windowScene,
              store.isEnabled, !store.isEditing, !store.shapes.isEmpty else {
            isHidden = true
            return
        }
        let fixed = scene.screen.fixedCoordinateSpace
        let sceneSpace = scene.effectiveGeometry.coordinateSpace
        var union = CGRect.null
        for shape in store.shapes {
            union = union.union(shape.path(from: fixed, to: sceneSpace).bounds)
        }
        let target = union.intersection(sceneSpace.bounds).integral
        guard !target.isNull, !target.isEmpty else {
            isHidden = true // zones are outside this window (e.g. a narrow Split View)
            return
        }
        if frame != target { frame = target }
        isHidden = false
        overlay.setNeedsDisplay()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let space = windowScene?.screen.fixedCoordinateSpace else { return nil }
        let fixed = convert(point, to: space)
        return store.blocks(fixedPoint: fixed, screenSize: space.bounds.size) ? overlay : nil
    }
}

private final class ShieldViewController: UIViewController {
    private let overlay: ShieldOverlayView

    init(overlay: ShieldOverlayView) {
        self.overlay = overlay
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() { view = overlay }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
    override var prefersStatusBarHidden: Bool { false }
}

/// Draws the zones (when "Show zones" is on), flashes blocked touches, and acts as the sink
/// that receives and ignores every blocked touch.
final class ShieldOverlayView: UIView {
    private let store: DeadZoneStore
    private var cancellables = Set<AnyCancellable>()

    init(store: DeadZoneStore) {
        self.store = store
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isMultipleTouchEnabled = true
        clipsToBounds = false
        isAccessibilityElement = false

        store.objectWillChange
            .sink { [weak self] _ in self?.setNeedsDisplay() }
            .store(in: &cancellables)
        store.blockedTouch
            .sink { [weak self] point in self?.flashMarker(atFixed: point) }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var fixedSpace: UICoordinateSpace? { window?.windowScene?.screen.fixedCoordinateSpace }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay() // rotation / resize
    }

    override func draw(_ rect: CGRect) {
        guard store.showsZones, store.isEnabled, !store.isEditing, let space = fixedSpace else { return }
        for shape in store.shapes {
            let body = shape.path(from: space, to: self)
            UIColor.systemRed.withAlphaComponent(0.16).setFill()
            body.fill()
            UIColor.systemRed.withAlphaComponent(0.55).setStroke()
            body.lineWidth = 1.5
            body.stroke()
        }
    }

    private func flashMarker(atFixed point: CGPoint) {
        guard store.showsZones, let space = fixedSpace else { return }
        let marker = UIView(frame: CGRect(x: 0, y: 0, width: 36, height: 36))
        marker.center = space.convert(point, to: self)
        marker.layer.cornerRadius = 18
        marker.backgroundColor = UIColor.systemRed.withAlphaComponent(0.35)
        marker.layer.borderColor = UIColor.systemRed.cgColor
        marker.layer.borderWidth = 2
        marker.isUserInteractionEnabled = false
        addSubview(marker)
        UIView.animate(withDuration: 0.7, delay: 0, options: [.curveEaseOut], animations: {
            marker.alpha = 0
            marker.transform = CGAffineTransform(scaleX: 1.8, y: 1.8)
        }, completion: { _ in marker.removeFromSuperview() })
    }

    // MARK: Touch sink — record, then ignore.

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let space = fixedSpace else { return }
        for touch in touches {
            store.recordBlocked(at: convert(touch.location(in: self), to: space))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}
}

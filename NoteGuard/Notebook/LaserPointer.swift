import UIKit

/// Laser pointer, like the one in Goodnotes: one finger or the stylus draws glowing red lines with
/// a dot at the tip, for presenting or pointing something out. The lines are temporary: once the
/// screen has been left alone for a few seconds they fade away. Nothing is saved into the
/// notebook. Two fingers still scroll and zoom.
/// What the laser leaves behind.
enum LaserStyle: String, CaseIterable, Identifiable {
    /// Glowing lines that fade a few seconds after the last touch.
    case lines
    /// Just a red dot that follows the finger and disappears on lift.
    case dot

    var id: String { rawValue }
    var title: String { self == .lines ? "Fading Lines" : "Dot Only" }
    var symbol: String { self == .lines ? "laser.burst" : "smallcircle.filled.circle" }

    private static let key = "laser.style"
    static var saved: LaserStyle {
        get { UserDefaults.standard.string(forKey: key).flatMap(LaserStyle.init) ?? .lines }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

final class LaserPointer: NSObject, UIGestureRecognizerDelegate {
    private let overlay = LaserOverlayView()

    var style: LaserStyle {
        get { overlay.style }
        set { overlay.style = newValue }
    }
    private let press = UILongPressGestureRecognizer()

    var isActive = false {
        didSet {
            press.isEnabled = isActive
            if !isActive { overlay.clear() }
        }
    }

    /// `target` receives the touches; the lines are drawn in an overlay covering it, added to
    /// `container` just above `sibling`.
    init(target: UIView, container: UIView, above sibling: UIView) {
        super.init()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.insertSubview(overlay, aboveSubview: sibling)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: target.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: target.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: target.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: target.bottomAnchor),
        ])

        // A zero-delay long press reports a single touch from down to up, wherever it moves.
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.numberOfTouchesRequired = 1
        press.cancelsTouchesInView = false
        press.delegate = self
        press.isEnabled = false
        press.addTarget(self, action: #selector(handlePress(_:)))
        target.addGestureRecognizer(press)
    }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: overlay)
        switch gesture.state {
        case .began:
            overlay.begin(at: point)
        case .changed:
            // A second finger means scrolling, not pointing.
            if gesture.numberOfTouches > 1 { overlay.end(); return }
            overlay.move(to: point)
        default:
            overlay.end()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true // the two-finger scroll keeps working
    }
}

/// The temporary lines and the dot. Lines stay while you keep using the laser and fade out
/// together once nothing has touched the screen for `idleDelay`.
private final class LaserOverlayView: UIView {
    private let lines = CAShapeLayer()
    private let dot = CAShapeLayer()
    private var path = CGMutablePath()
    var style: LaserStyle = .lines {
        didSet { if style != oldValue { clear() } }
    }
    private var isDrawing = false
    private var fadeTimer: Timer?
    /// Bumped whenever a touch starts, so a fade that was interrupted doesn't clear new lines.
    private var generation = 0

    /// How long the lines stay after the last touch lifts.
    private let idleDelay: TimeInterval = 3
    private let fadeDuration: TimeInterval = 0.6
    private let dotRadius: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true

        let red = UIColor.systemRed.cgColor
        lines.fillColor = nil
        lines.strokeColor = red
        lines.lineWidth = 4
        lines.lineCap = .round
        lines.lineJoin = .round
        lines.shadowColor = red
        lines.shadowRadius = 6
        lines.shadowOpacity = 0.9
        lines.shadowOffset = .zero
        layer.addSublayer(lines)

        dot.fillColor = red
        dot.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        dot.lineWidth = 2
        dot.shadowColor = red
        dot.shadowRadius = 10
        dot.shadowOpacity = 1
        dot.shadowOffset = .zero
        dot.path = CGPath(ellipseIn: CGRect(x: -dotRadius, y: -dotRadius, width: dotRadius * 2, height: dotRadius * 2),
                          transform: nil)
        dot.opacity = 0
        layer.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        lines.frame = bounds
    }

    func begin(at point: CGPoint) {
        // Touching again keeps the lines up (and rescues them mid-fade).
        fadeTimer?.invalidate()
        generation += 1
        lines.removeAnimation(forKey: "fade")
        lines.opacity = 1
        isDrawing = true
        if style == .lines {
            path.move(to: point)
            path.addLine(to: point) // a tap leaves a dot-sized mark
        }
        update(dotAt: point)
    }

    func move(to point: CGPoint) {
        guard isDrawing else { return begin(at: point) }
        if style == .lines { path.addLine(to: point) }
        update(dotAt: point)
    }

    func end() {
        guard isDrawing else { return }
        isDrawing = false
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        dot.opacity = 0
        CATransaction.commit()
        if style == .lines { scheduleFade() }
    }

    /// Removes everything at once (leaving laser mode).
    func clear() {
        fadeTimer?.invalidate()
        generation += 1
        isDrawing = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lines.removeAnimation(forKey: "fade")
        lines.path = nil
        dot.opacity = 0
        CATransaction.commit()
        path = CGMutablePath()
    }

    private func update(dotAt point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lines.path = style == .lines ? path.copy() : nil
        dot.position = point
        dot.opacity = 1
        CATransaction.commit()
    }

    private func scheduleFade() {
        fadeTimer?.invalidate()
        let timer = Timer(timeInterval: idleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func fadeOut() {
        let fadingGeneration = generation
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, generation == fadingGeneration else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            lines.removeAnimation(forKey: "fade")
            lines.path = nil
            CATransaction.commit()
            path = CGMutablePath()
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = fadeDuration
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        lines.add(fade, forKey: "fade")
        CATransaction.commit()
    }
}

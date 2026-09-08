import SwiftUI
import UIKit

struct PanValue {
    let location: CGPoint
    let translation: CGSize
    let velocity: CGSize
}

/// A UIKit pan that only begins for a stroke along one axis. Strokes on the
/// other axis fail early, so whatever scroll view lives underneath is never
/// contested. SwiftUI's DragGesture cannot make that promise.
struct DirectionalPan: UIGestureRecognizerRepresentable {
    enum Axis { case horizontal, downward }

    let axis: Axis
    let enabled: Bool
    let space: NamedCoordinateSpace
    let began: (PanValue) -> Void
    let moved: (PanValue) -> Void
    let ended: (PanValue) -> Void

    func makeUIGestureRecognizer(context: Context) -> AxisPanGestureRecognizer {
        let pan = AxisPanGestureRecognizer()
        pan.axis = axis
        pan.maximumNumberOfTouches = 1
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: AxisPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = enabled
        recognizer.axis = axis
    }

    func handleUIGestureRecognizerAction(_ recognizer: AxisPanGestureRecognizer, context: Context) {
        let t = recognizer.translation(in: recognizer.view)
        let v = recognizer.velocity(in: recognizer.view)
        let value = PanValue(
            location: context.converter.location(in: space),
            translation: CGSize(width: t.x, height: t.y),
            velocity: CGSize(width: v.x, height: v.y)
        )
        switch recognizer.state {
        case .began: began(value)
        case .changed: moved(value)
        case .ended, .cancelled, .failed: ended(value)
        default: break
        }
    }
}

/// Watches its own touches and fails itself the moment the stroke is
/// clearly on the wrong axis. UIKit only asks a delegate "may I begin?"
/// once per touch, far too early to judge; this judges continuously.
final class AxisPanGestureRecognizer: UIPanGestureRecognizer {
    var axis: DirectionalPan.Axis = .horizontal
    private var start: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        start = touches.first?.location(in: view)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // Judge before the pan's own logic runs: a quick flick can cross the
        // begin threshold on its very first move, and once begun it is ours
        // whether we wanted it or not.
        if state == .possible, let start, let point = touches.first?.location(in: view) {
            let dx = point.x - start.x
            let dy = point.y - start.y
            if hypot(dx, dy) >= 6 {
                let sideways = abs(dx) >= abs(dy) * 1.2
                let wrongAxis: Bool
                switch axis {
                case .horizontal: wrongAxis = !sideways
                case .downward:   wrongAxis = sideways || dy <= 0
                }
                if wrongAxis {
                    state = .failed
                    return
                }
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        super.reset()
        start = nil
    }
}

import SwiftUI

/// Drag across tiles to select them; drag across selected tiles to
/// deselect. The first tile under the finger decides which.
@MainActor
final class SwipeSelect {
    private var mode: Bool?               // true = selecting, false = deselecting
    private var visited: Set<String> = []
    private var lastPoint: CGPoint?

    func begin(at point: CGPoint, tiles: TileRegistry, selection: inout Selection) {
        if let hit = tiles.tile(at: point) {
            mode = !selection.contains(hit)
        } else {
            mode = true
        }
        visited = []
        lastPoint = point
        apply(point, tiles: tiles, selection: &selection)
    }

    func move(to point: CGPoint, tiles: TileRegistry, selection: inout Selection) {
        guard mode != nil else { return }
        // Sample the path since the last update so fast swipes skip nothing.
        let from = lastPoint ?? point
        let distance = hypot(point.x - from.x, point.y - from.y)
        let steps = max(Int(distance / 16), 1)
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let sample = CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t)
            apply(sample, tiles: tiles, selection: &selection)
        }
        lastPoint = point
    }

    func end() {
        mode = nil
        visited = []
        lastPoint = nil
    }

    private func apply(_ point: CGPoint, tiles: TileRegistry, selection: inout Selection) {
        guard let mode, let id = tiles.tile(at: point), !visited.contains(id) else { return }
        visited.insert(id)
        if mode { selection.insert(id) } else { selection.remove(id) }
    }
}

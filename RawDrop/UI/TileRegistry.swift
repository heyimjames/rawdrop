import SwiftUI

/// Where each realised tile is, answered on demand. Tiles register a closure
/// when they appear and remove it when they go. Nothing here is view state,
/// so asking never triggers a render, and layout never writes state.
@MainActor
final class TileRegistry {
    private var providers: [String: () -> TileFrame] = [:]

    func register(_ id: String, _ provider: @escaping () -> TileFrame) {
        providers[id] = provider
    }

    func unregister(_ id: String) {
        providers[id] = nil
    }

    func frame(for id: String) -> TileFrame? {
        providers[id]?()
    }

    var count: Int { providers.count }

    /// A few registered frames, for debugging coordinate spaces.
    func sampleFrames() -> String {
        providers.prefix(3).map { "\($0.key.suffix(6)):\($0.value().grid.integral)" }.joined(separator: " ")
    }

    /// The realised tile under a point in grid space.
    func tile(at point: CGPoint) -> String? {
        providers.first { $0.value().grid.contains(point) }?.key
    }
}

struct TileFrame: Equatable {
    let grid: CGRect
    let global: CGRect
}

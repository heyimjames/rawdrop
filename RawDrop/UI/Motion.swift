import SwiftUI

/// The whole motion vocabulary. Seven curves, each with one job. If a new
/// animation does not fit one of these, the answer is usually "don't".
enum Motion {
    /// Weighted objects arriving or returning: the send bar, the viewer,
    /// a photo snapping back after a half-hearted pull.
    static let settle = Animation.spring(response: 0.42, dampingFraction: 0.84)

    /// A photo travelling between grid and viewer. Quicker and better damped
    /// than `settle`: it is carrying an image, so it must not wobble.
    static let fly = Animation.spring(response: 0.34, dampingFraction: 0.9)

    /// The RAW card sliding out from behind the JPG. The one overshoot.
    static let reveal = Animation.spring(response: 0.55, dampingFraction: 0.68)

    /// The card springing home after being dragged. It is a toy; it may bounce.
    static let toy = Animation.spring(response: 0.45, dampingFraction: 0.62)

    /// Yes/no state: rings, ticks, a tile lifting when selected.
    static let state = Animation.snappy(duration: 0.22)

    /// Mode changes and label crossfades. Nothing travels.
    static let mode = Animation.smooth(duration: 0.22)

    /// Pure opacity: thumbnails arriving, captions, the landing stagger.
    static let fade = Animation.easeOut(duration: 0.3)

    /// The extraction fill. It tracks a real number, so it moves linearly.
    static let progress = Animation.linear(duration: 0.18)

    /// Reduce Motion stand-in for anything that would otherwise travel.
    static let reduced = Animation.easeOut(duration: 0.2)
}

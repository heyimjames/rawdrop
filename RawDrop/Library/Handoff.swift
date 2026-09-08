import Foundation

/// Facts about the far end of the hand-off.
enum Handoff {
    /// Lightroom's share extension stops appearing in the share sheet above
    /// some number of files. Sends are chunked to stay under it.
    /// Lightroom accepts up to 50 per share (confirmed 2026-09-07).
    static let maxPhotosPerShare = 50

    /// Over this many selected, the send button turns into "keep the first 50".
    static var selectionLimit: Int { maxPhotosPerShare }
}

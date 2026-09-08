import SwiftUI

/// A copy of a photo travelling between its grid tile and its place in the
/// viewer. Frame, crop and corner radius all follow one progress value, so
/// the whole journey is one interpolation: 0 = on the tile, 1 = in place.
struct FlyingPhoto: View {
    let image: UIImage?
    let from: CGRect        // tile, in the host's coordinate space
    let to: CGRect          // fitted photo rect, same space
    let progress: CGFloat

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(white: 0.09)
                }
            }
            .modifier(Fly(progress: progress, from: from, to: to))
    }
}

/// Animatable frame-and-arc. The centre lifts along a half sine so the
/// photo is tossed rather than slid, and the corner radius runs 0 ↔ 16.
private struct Fly: ViewModifier, Animatable {
    var progress: CGFloat
    let from: CGRect
    let to: CGRect

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = progress
        let c = max(0, min(1, p))
        let w = from.width + (to.width - from.width) * p
        let h = from.height + (to.height - from.height) * p
        let travel = hypot(to.midX - from.midX, to.midY - from.midY)
        let lift = min(48, travel * 0.08)
        let cx = from.midX + (to.midX - from.midX) * p
        let cy = from.midY + (to.midY - from.midY) * p - sin(c * .pi) * lift
        let radius = 16 * c

        content
            .frame(width: max(w, 1), height: max(h, 1))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .position(x: cx, y: cy)
    }
}

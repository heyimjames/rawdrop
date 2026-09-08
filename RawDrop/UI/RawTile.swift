import SwiftUI
import Photos

struct RawTile: View {
    let photo: RawPhoto
    let info: RawInfo?
    let isSelecting: Bool
    let isSelected: Bool
    let isSent: Bool
    let isExtracting: Bool
    /// The photo is open in the viewer. The tile goes dark so the photo
    /// reads as having been lifted out of the grid.
    let isLifted: Bool
    let tap: () -> Void
    let resolveInfo: () -> Void

    @State private var image: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: tap) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    ZStack {
                        Color(white: 0.09)
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .modifier(Sweep(active: isExtracting && !reduceMotion))
                        }
                    }
                }
                .clipped()
                .opacity(isLifted ? 0 : 1)
                .overlay(alignment: .bottomLeading) { formatBadge }
                .overlay(alignment: .bottomTrailing) { sentMark }
                .overlay(alignment: .topTrailing) { selectionMark }
                .overlay {
                    // Selected photos lift, the way they do in Photos. The ring
                    // is the indicator; this is just the photo acknowledging it.
                    Color.white.opacity(isSelected ? 0.16 : 0)
                }
                .overlay {
                    // Reduce Motion gets a still amber wash instead of the sweep.
                    if isExtracting && reduceMotion {
                        Color.accentColor.opacity(0.28)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isSelecting ? "Double tap to select." : "Double tap to open.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(Motion.state, value: isSelected)
        .animation(Motion.mode, value: isSelecting)
        .animation(Motion.mode, value: isExtracting)
        .animation(Motion.fade, value: image == nil)
        .task(id: photo.id) {
            resolveInfo()
            for await frame in Thumbnails.shared.stream(for: photo.asset, targetSize: CGSize(width: 420, height: 420)) {
                image = frame
            }
        }
    }

    // MARK: Overlays

    @ViewBuilder
    private var formatBadge: some View {
        if let info {
            Text(info.format)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2.5)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(6)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var sentMark: some View {
        if isSent {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 16, height: 16)
                .background(.white.opacity(0.85), in: Circle())
                .padding(6)
                .accessibilityHidden(true)
        }
    }

    /// Empty ring in select mode, filled when chosen. Nothing in browse mode.
    private var selectionMark: some View {
        ZStack {
            Circle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                .background(Circle().fill(.black.opacity(0.2)))
                .opacity(isSelected ? 0 : 1)
            Circle()
                .fill(Color.accentColor)
                .opacity(isSelected ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.black)
                .opacity(isSelected ? 1 : 0)
        }
        .frame(width: 22, height: 22)
        .padding(7)
        .scaleEffect(isSelecting ? 1 : 0.6)
        .opacity(isSelecting ? 1 : 0)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let info { parts.append("\(info.format) photo, \(info.filename)") } else { parts.append("RAW photo") }
        if isSent { parts.append("already sent to Lightroom") }
        return parts.joined(separator: ", ")
    }
}


/// The one shader in the app. A band of amber light crosses the tile whose
/// RAW is being copied. Off, it costs nothing: the modifier is identity.
private struct Sweep: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation) { context in
                let time = Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000))
                content.visualEffect { view, proxy in
                    view.colorEffect(ShaderLibrary.sweep(.float2(proxy.size), .float(time)))
                }
            }
        } else {
            content
        }
    }
}

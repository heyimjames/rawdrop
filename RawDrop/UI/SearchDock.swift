import SwiftUI
import Photos

/* ─────────────────────────────────────────────────────────
 * SEARCH DOCK STORYBOARD
 *
 *  rest      a glass pill where the send bar lives: "Search RAW photos".
 *            While photos are still being read, a small ring fills at
 *            its end.
 *  tap       keyboard rises, the pill rides it up; a close button
 *            slides in beside it; suggestions stack up above, left
 *            aligned, each with the newest photo it would find, landing
 *            one after another (settle, 30ms apart). The grid dims.
 *  type      the grid behind becomes the results, live; suggestions
 *            narrow to cameras, places and subjects that start with
 *            what was typed
 *  return    keyboard drops, results stay. A long phrase goes to Apple
 *            Intelligence; the glass sparkles while it thinks
 *  select    a photo selected: the pill gives way to the send bar in the
 *            same place. Deselect everything and it comes back.
 * ───────────────────────────────────────────────────────── */

struct SearchDock: View {
    @Bindable var search: SearchModel
    let indexer: Indexer
    let placeholder: String
    let suggestions: [SearchModel.Suggestion]
    var focused: FocusState<Bool>.Binding

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if focused.wrappedValue {
                stack
                    .transition(.opacity)
            }
            HStack(spacing: 10) {
                pill
                if focused.wrappedValue || search.isActive {
                    Button {
                        search.clear()
                        focused.wrappedValue = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 50, height: 50)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("End search")
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .animation(reduceMotion ? Motion.reduced : Motion.settle, value: focused.wrappedValue)
        .animation(Motion.mode, value: search.isActive)
    }

    // MARK: Pill

    private var pill: some View {
        HStack(spacing: 10) {
            Image(systemName: search.isInterpreting ? "sparkle" : "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(search.isInterpreting ? Color.white : Color.secondary)
                .symbolEffect(.pulse, isActive: search.isInterpreting)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20)

            TextField(placeholder, text: $search.query)
                .focused(focused)
                .submitLabel(.search)
                .onSubmit {
                    search.submit()
                    focused.wrappedValue = false
                }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.body)
                .tint(.white)

            if !search.query.isEmpty {
                Button {
                    search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .transition(.opacity)
            } else if indexer.isRunning && !focused.wrappedValue {
                IndexRing(fraction: indexer.fraction)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 50)
        .contentShape(Capsule())
        .onTapGesture { focused.wrappedValue = true }
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(Motion.mode, value: search.query.isEmpty)
        .animation(Motion.mode, value: search.isInterpreting)
    }

    // MARK: Suggestions

    private var stack: some View {
        VStack(alignment: .leading, spacing: 8) {
            if indexer.remaining > 0 {
                IndexStatus(done: indexer.done, total: indexer.total, fraction: indexer.fraction)
                    .padding(.leading, 6)
                    .padding(.bottom, 2)
            }
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                SuggestionChip(suggestion: suggestion) {
                    search.apply(suggestion)
                    focused.wrappedValue = false
                }
                .modifier(Arrival(index: index, reduceMotion: reduceMotion))
            }
        }
        .animation(Motion.mode, value: suggestions.map(\.id))
    }
}

// MARK: - Chip

/// Glass capsule: the newest photo it would find, what it is, how many.
private struct SuggestionChip: View {
    let suggestion: SearchModel.Suggestion
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                icon
                Text(suggestion.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let detail = suggestion.detail {
                    Text(detail)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 5)
            .padding(.trailing, 14)
            .frame(height: 40)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(suggestion.detail.map { "\(suggestion.title), \($0) photos" } ?? suggestion.title)
    }

    @ViewBuilder
    private var icon: some View {
        switch suggestion.icon {
        case .thumbnail(let photo):
            ChipThumbnail(asset: photo.asset)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.12), in: Circle())
        }
    }
}

private struct ChipThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(white: 0.16)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
        .animation(Motion.fade, value: image == nil)
        .task(id: asset.localIdentifier) {
            for await frame in Thumbnails.shared.stream(for: asset, targetSize: CGSize(width: 90, height: 90)) {
                image = frame
            }
        }
    }
}

/// Each chip lands a beat after the one below it, so the stack reads as
/// rising out of the search field rather than appearing as a block.
private struct Arrival: ViewModifier {
    let index: Int
    let reduceMotion: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .scaleEffect(shown || reduceMotion ? 1 : 0.96, anchor: .bottomLeading)
            .onAppear {
                withAnimation((reduceMotion ? Motion.reduced : Motion.settle).delay(Double(index) * 0.03)) {
                    shown = true
                }
            }
    }
}

// MARK: - Index progress

/// How far through the library the tagger has got. A ring, not a bar: it
/// sits inside a pill and should not look like a loading screen.
struct IndexRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
        .padding(.trailing, 6)
        .animation(Motion.progress, value: fraction)
        .accessibilityLabel("Reading photos for search, \(Int(fraction * 100)) percent")
    }
}

private struct IndexStatus: View {
    let done: Int
    let total: Int
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            IndexRing(fraction: fraction)
                .padding(.trailing, -6)
            Text("Reading your photos · \(done.formatted()) of \(total.formatted())")
                .contentTransition(.numericText(value: Double(done)))
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
        .animation(Motion.mode, value: done)
    }
}

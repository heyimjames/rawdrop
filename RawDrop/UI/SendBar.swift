import SwiftUI

/* ─────────────────────────────────────────────────────────
 * SEND BAR STORYBOARD
 *
 *  rest     nothing selected → bar is off-screen below the grid
 *  select   first tap → capsule rises from the bottom edge (spring)
 *           further taps → only the count digits roll (numericText)
 *  tap      "Send 12 to Lightroom" blurs into "Extracting 1 of 12";
 *           amber fill grows left→right inside the same capsule
 *  done     capsule stays; the share sheet slides up over it
 *  batches  >50 photos → "Handing off 2 of 3", next batch extracts
 *           as soon as the previous sheet reports completion
 *  over 50  capsule warms from amber to red, label becomes the fix:
 *           "Keep the first 50". Tap → count rolls back down to 50 and
 *           the red cools back to amber. A warning tick on crossing.
 *  sent     label morphs → "Sent to Lightroom" with a check
 *  +1.4s    selection clears upstream → bar sinks back
 *
 *  Same capsule the whole time. It changes what it says, never
 *  where it is.
 * ───────────────────────────────────────────────────────── */

struct SendBar: View {
    let selectedCount: Int
    let phase: SendController.Phase
    let send: () -> Void
    let trim: () -> Void
    let cancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOver: Bool {
        if case .idle = phase { return selectedCount > Handoff.selectionLimit }
        return false
    }

    private var isVisible: Bool {
        if selectedCount > 0 { return true }
        if case .idle = phase { return false }
        return true
    }

    var body: some View {
        ZStack {
            if isVisible {
                capsule
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }
        }
        .animation(reduceMotion ? Motion.reduced : Motion.settle, value: isVisible)
    }

    // MARK: Capsule

    private var capsule: some View {
        Button(action: primaryAction) {
            label
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background { progressFill }
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(glass, in: .capsule)
        .disabled(isDisabled)
        .animation(Motion.mode, value: phaseKey)
        .sensoryFeedback(.warning, trigger: isOver) { _, now in now }
    }

    private func primaryAction() {
        switch phase {
        case .idle: isOver ? trim() : send()
        case .extracting: cancel()
        default: break
        }
    }

    private var isDisabled: Bool {
        switch phase {
        case .idle: selectedCount == 0
        case .extracting: false
        default: true
        }
    }

    private var glass: Glass {
        switch phase {
        case .idle: .regular.tint(isOver ? Palette.over : Palette.amber).interactive()
        case .extracting: .regular.interactive()
        case .sent: .regular.tint(Palette.amber)
        case .sharing, .failed: .regular
        }
    }

    /// One fill, one interpolation. It is the only thing that moves while
    /// files are copying, so the eye has a single place to rest.
    @ViewBuilder
    private var progressFill: some View {
        if case .extracting(_, _, let fraction) = phase {
            GeometryReader { geo in
                Rectangle()
                    .fill(Palette.amber.opacity(0.35))
                    .frame(width: geo.size.width * fraction)
                    .animation(Motion.progress, value: fraction)
            }
        }
    }

    // MARK: Label

    /// Distinct phases crossfade. Within a phase only the digits move.
    private var phaseKey: Int {
        switch phase {
        case .idle: isOver ? 5 : 0
        case .extracting: 1
        case .sharing: 2
        case .sent: 3
        case .failed: 4
        }
    }

    @ViewBuilder
    private var label: some View {
        Group {
            switch phase {
            case .idle where isOver:
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line")
                    Text("Keep the first \(Handoff.selectionLimit)")
                }
                .foregroundStyle(.white)

            case .idle:
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.forward.app.fill")
                    Text("Send \(selectedCount.formatted()) to Lightroom")
                        .contentTransition(.numericText(value: Double(selectedCount)))
                }
                .foregroundStyle(.black)

            case .extracting(let done, let total, _):
                HStack(spacing: 10) {
                    Text("Extracting \(min(done + 1, total).formatted()) of \(total.formatted())")
                        .contentTransition(.numericText(value: Double(done)))
                    Text("Cancel")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)

            case .sharing(let batch, let batchCount):
                Text(batchCount > 1 ? "Handing off \(batch) of \(batchCount)" : "Handing off")
                    .contentTransition(.numericText(value: Double(batch)))
                    .foregroundStyle(.white)

            case .sent(let count):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.headline.weight(.bold))
                    Text(count == 1 ? "Sent to Lightroom" : "Sent \(count.formatted()) to Lightroom")
                }
                .foregroundStyle(.black)

            case .failed(let message):
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
            }
        }
        .font(.headline)
        .id(phaseKey)
        .transition(.opacity)
        .animation(Motion.mode, value: selectedCount)
    }
}

/// The app's colours, by name rather than through the accent system. The
/// accent can be reset to system blue by UIKit appearance proxies, and
/// amber must never depend on it.
enum Palette {
    static let amber = Color("AccentColor")
    /// The one colour that is not amber, black or white: too many.
    static let over = Color(red: 1.0, green: 0.30, blue: 0.25)
}

import SwiftUI

/* ─────────────────────────────────────────────────────────
 * ABOUT SHEET STORYBOARD   (plays every time; it is the point)
 *
 *  Same cue sheet as first open (Intro.timing):
 *   150ms   JPG card rises
 *   550ms   RAW card slides out and springs to rest
 *   950ms   glint
 *  1000ms   "RawDrop"
 *  1150ms   two lines
 *  1350ms   button, then the version whispers in
 *   after   the RAW card is yours to drag
 * ───────────────────────────────────────────────────────── */

struct InfoSheet: View {
    private let site = URL(string: "https://octoberwip.com")!

    @State private var stage = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            PairGlyph(stage: stage, reduceMotion: reduceMotion)
                .padding(.bottom, 34)

            Text("RawDrop")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .padding(.bottom, 14)
                .reveal(stage >= 4, reduceMotion: reduceMotion)

            VStack(spacing: 6) {
                Text("RawDrop is an app from OCTOBER.")
                    .foregroundStyle(.primary)
                Text("A collaboration between humans & AI.")
                    .foregroundStyle(.secondary)
            }
            .font(.body)
            .multilineTextAlignment(.center)
            .reveal(stage >= 5, reduceMotion: reduceMotion)

            Spacer(minLength: 0)

            // White, not amber: amber is reserved for sending.
            Link(destination: site) {
                Text("Visit website")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            .reveal(stage >= 6, reduceMotion: reduceMotion, travel: 20)

            Text("Version \(version)")
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .padding(.bottom, 10)
                .reveal(stage >= 6, reduceMotion: reduceMotion, travel: 0)
        }
        .padding(.top, 28)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? Intro.fade : Intro.rise, value: stage)
        .presentationDetents([.fraction(0.6)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(white: 0.07))
        .presentationCornerRadius(36)
        .preferredColorScheme(.dark)
        .task {
            if reduceMotion {
                try? await Task.sleep(for: .milliseconds(80))
                stage = 6
                return
            }
            var last = 0.0
            for (index, t) in Intro.timing.enumerated() {
                try? await Task.sleep(for: .seconds(t - last))
                last = t
                stage = index + 1
            }
        }
    }
}

private extension View {
    /// Fade up into place. With Reduce Motion, just fade.
    func reveal(_ shown: Bool, reduceMotion: Bool, travel: CGFloat = 8) -> some View {
        self
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : travel)
    }
}

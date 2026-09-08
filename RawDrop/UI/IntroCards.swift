import SwiftUI

/* ─────────────────────────────────────────────────────────
 * FIRST OPEN STORYBOARD   (seen once, so it gets to be a moment)
 *
 *     0ms   black. nothing.
 *   150ms   JPG card rises into place, tilted, dim
 *   550ms   RAW card slides out from behind it and springs to
 *           rest, overshooting its tilt. The whole app in one move.
 *   950ms   a glint of light crosses the RAW card as it settles
 *  1000ms   "RawDrop" fades up
 *  1150ms   one line of copy fades up
 *  1350ms   the button rises from the bottom edge
 *   after   the RAW card is draggable; let go and it springs home
 *
 *  Reduce Motion: same order, no travel, no overshoot, no glint.
 * ───────────────────────────────────────────────────────── */

enum Intro {
    static let timing: [Double] = [0.15, 0.55, 0.95, 1.0, 1.15, 1.35]
    // stage 1: jpg  2: raw  3: glint  4: title  5: copy  6: button

    static let rise   = Motion.settle
    static let reveal = Motion.reveal
    static let fade   = Motion.fade
    static let home   = Motion.toy
}

/// Two stacked frames, JPG behind, RAW in front. The whole app in one glyph.
/// On first open the RAW card is the thing that moves; after that it is a
/// small toy you can drag while you decide to tap the button.
struct PairGlyph: View {
    let stage: Int
    let reduceMotion: Bool

    @State private var drag: CGSize = .zero
    @State private var releases = 0

    var body: some View {
        ZStack {
            card("JPG", tint: .white.opacity(0.18), fg: .white.opacity(0.5))
                .rotationEffect(.degrees(-8))
                .offset(x: -22, y: 6)
                .opacity(stage >= 1 ? 1 : 0)
                .offset(y: stage >= 1 || reduceMotion ? 0 : 18)
                .animation(Intro.rise, value: stage)

            card("RAW", tint: Palette.amber, fg: .black)
                .modifier(Glint(fire: stage >= 3 && !reduceMotion, drag: reduceMotion ? 0 : drag.width))
                .rotationEffect(.degrees(rawAngle))
                .offset(x: rawOffset.width, y: rawOffset.height)
                .opacity(stage >= 2 || (reduceMotion && stage >= 1) ? 1 : 0)
                .animation(reduceMotion ? Intro.fade : Intro.reveal, value: stage)
                .gesture(
                    DragGesture()
                        .onChanged { drag = $0.translation }
                        .onEnded { _ in
                            releases += 1
                            withAnimation(Intro.home) { drag = .zero }
                        }
                )
                .sensoryFeedback(.impact(flexibility: .soft), trigger: releases)
                .accessibilityHidden(true)
        }
        .frame(width: 140, height: 110)
    }

    /// Before its cue the RAW card sits exactly behind the JPG, same tilt.
    private var rawOffset: CGSize {
        let rest = stage >= 2 || reduceMotion ? CGSize(width: 18, height: -4) : CGSize(width: -22, height: 6)
        return CGSize(width: rest.width + drag.width, height: rest.height + drag.height)
    }

    private var rawAngle: Double {
        let rest = stage >= 2 || reduceMotion ? 6.0 : -8.0
        return rest + Double(drag.width) / 14   // leans into the direction it is pulled
    }

    private func card(_ label: String, tint: Color, fg: Color) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(tint)
            .frame(width: 84, height: 100)
            .overlay(alignment: .bottomLeading) {
                Text(label)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(fg)
                    .padding(10)
            }
    }
}

/// One pass of light across a view when it lands, then nothing. While the
/// view is being dragged, the same highlight tracks the drag instead, as if
/// the light source stayed put. Paused whenever neither is happening.
struct Glint: ViewModifier {
    let fire: Bool
    let drag: CGFloat
    @State private var start: Date?

    private let duration = 0.9

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: start == nil)) { context in
            let sweep = start.map { Float(min(context.date.timeIntervalSince($0) / duration, 1)) } ?? 0
            let dragging = abs(drag) > 0.5
            let progress: Float = start != nil ? sweep : Float(0.5 + drag / 320)
            let intensity: Float = start != nil ? 1 : (dragging ? Float(min(abs(drag) / 80, 1)) : 0)
            content.visualEffect { view, proxy in
                view.colorEffect(ShaderLibrary.glint(.float2(proxy.size), .float(progress), .float(intensity)))
            }
        }
        .onChange(of: fire) { _, now in
            guard now, start == nil else { return }
            start = .now
            Task {
                try? await Task.sleep(for: .seconds(duration + 0.1))
                start = nil   // progress 0 is off-canvas, so this is a clean stop
            }
        }
    }
}

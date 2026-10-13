import SwiftUI

/* ─────────────────────────────────────────────────────────
 * LOADING STORYBOARD
 *
 * Read top-to-bottom. Times are after the grid first draws.
 *
 *      0ms   the grid's own shape is already there: a day label and
 *            seven rows of cells, in the grey a tile shows before
 *            its photo arrives. Nothing moves, so a quick load reads
 *            as photos arriving rather than as a loading screen.
 *    700ms   still nothing to show: a soft light passes down the
 *            grid, label first, then each row 80ms after the one
 *            above. One pass every 2s.
 *   4000ms   the subtitle owns up to the wait: "Still looking. Big
 *            libraries take a moment."
 *   photos   the light stops. Every cell stays exactly where it is
 *            and becomes a tile; each photo fades in on its own cell
 *            as it decodes. Nothing slides, nothing re-lays out.
 *
 * Reduce Motion: no light. The cells wait, still; photos still fade in.
 * ───────────────────────────────────────────────────────── */

enum LoadingTiming {
    static let lightStarts: TimeInterval = 0.7   // a load quicker than this never sees motion
    static let rowDelay: TimeInterval    = 0.08  // the light reaches each row this long after the last
    static let pass: TimeInterval        = 0.9   // how long the light takes to cross one row
    static let cycle: TimeInterval       = 2.0   // one pass plus the rest before the next
    static let reassure: TimeInterval    = 4.0   // the subtitle admits the wait
}

/// The stand-in cells.
enum LoadingCells {
    static let rows      = 7       // a screenful on the largest phone, with some to spare
    static let rest      = 0.09    // white level; RawTile's empty cell, so the hand-over is invisible
    static let lit       = 0.13    // white level at the top of the light
}

/// The stand-in day label.
enum LoadingLabel {
    static let width: CGFloat  = 128    // about "Monday 12 October"
    static let height: CGFloat = 11     // a little under the cap height
    static let lift            = 0.04   // drawn this much lighter than a cell
}

/// How lit a row is at a given moment. Row 0 is the day label.
private func loadingLevel(row: Int, at now: Date, since: Date) -> Double {
    let t = now.timeIntervalSince(since) - LoadingTiming.lightStarts - Double(row) * LoadingTiming.rowDelay
    guard t > 0 else { return LoadingCells.rest }
    let inCycle = t.truncatingRemainder(dividingBy: LoadingTiming.cycle)
    guard inCycle < LoadingTiming.pass else { return LoadingCells.rest }
    let swell = sin(.pi * inCycle / LoadingTiming.pass)          // 0 → 1 → 0, eased at both ends
    return LoadingCells.rest + (LoadingCells.lit - LoadingCells.rest) * swell * swell
}

/// One empty cell, sized exactly as a RawTile.
struct LoadingCell: View {
    let row: Int
    let since: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                    Color(white: reduceMotion ? LoadingCells.rest : loadingLevel(row: row, at: context.date, since: since))
                }
            }
            .accessibilityHidden(true)
    }
}

/// The day label's stand-in, laid out exactly as a DayHeader so the first
/// row of cells sits where the first row of photos will.
struct LoadingHeader: View {
    let since: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack {
            Text(verbatim: "Monday 12 October")
                .font(.subheadline.weight(.semibold))
                .hidden()                                        // keeps DayHeader's line height
                .overlay(alignment: .leading) {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                        let level = reduceMotion ? LoadingCells.rest : loadingLevel(row: 0, at: context.date, since: since)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color(white: level + LoadingLabel.lift))
                            .frame(width: LoadingLabel.width, height: LoadingLabel.height)
                    }
                }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .accessibilityHidden(true)
    }
}

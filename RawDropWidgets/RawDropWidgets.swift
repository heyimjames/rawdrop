import WidgetKit
import SwiftUI

/* ─────────────────────────────────────────────────────────
 * WIDGET GRID
 *
 *  8px grid, 24px padding. Two groups per widget:
 *    top     the label ("RAW", amber) — what this number is
 *    bottom  the hero number + one line of context
 *  Medium adds the four newest waiting photos on the right.
 *  Tap anywhere → app opens with the waiting photos selected.
 *
 *  States: waiting (the normal one) · all sent · nothing yet
 * ───────────────────────────────────────────────────────── */

@main
struct RawDropWidgets: WidgetBundle {
    var body: some Widget {
        WaitingWidget()
    }
}

// MARK: - Timeline

struct WaitingEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct WaitingProvider: TimelineProvider {
    func placeholder(in context: Context) -> WaitingEntry {
        WaitingEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (WaitingEntry) -> Void) {
        completion(WaitingEntry(date: .now, snapshot: WidgetSnapshot.load() ?? .placeholder))
    }

    /// One entry, no schedule. The app reloads the timeline whenever the
    /// library or the sent list changes; nothing else can change the number.
    func getTimeline(in context: Context, completion: @escaping (Timeline<WaitingEntry>) -> Void) {
        let entry = WaitingEntry(date: .now, snapshot: WidgetSnapshot.load() ?? .empty)
        completion(Timeline(entries: [entry], policy: .never))
    }
}

// MARK: - Widget

struct WaitingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.jamesfrewin.RawDrop.waiting", provider: WaitingProvider()) { entry in
            WaitingEntryView(entry: entry)
        }
        .configurationDisplayName("RAW waiting")
        .description("How many RAW photos are waiting to go to Lightroom.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
        .contentMarginsDisabled()
    }
}


private struct WaitingEntryView: View {
    let entry: WaitingEntry
    @Environment(\.widgetFamily) private var family
    var body: some View { WaitingView(snapshot: entry.snapshot, family: family) }
}

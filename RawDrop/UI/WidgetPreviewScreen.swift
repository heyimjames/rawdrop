#if DEBUG
import SwiftUI
import WidgetKit

/// Debug only: the widget views at real sizes, reachable with `-preview-widgets`.
struct WidgetPreviewScreen: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ForEach([snapshot, sentState, WidgetSnapshot.empty], id: \.updated) { snap in
                    HStack(alignment: .top, spacing: 16) {
                        WaitingView(snapshot: snap, family: .systemSmall)
                            .frame(width: 158, height: 158)
                            .background(.black, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        WaitingView(snapshot: snap, family: .systemMedium)
                            .frame(width: 338, height: 158)
                            .background(.black, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }
                    .scaleEffect(0.78, anchor: .topLeading)
                    .frame(width: 420, height: 130, alignment: .topLeading)
                }
                HStack(spacing: 16) {
                    WaitingView(snapshot: snapshot, family: .accessoryCircular)
                        .frame(width: 76, height: 76)
                    WaitingView(snapshot: snapshot, family: .accessoryRectangular)
                        .frame(width: 172, height: 76)
                    WaitingView(snapshot: snapshot, family: .accessoryInline)
                }
                .foregroundStyle(.white)
            }
            .padding(24)
        }
        .background(Color(white: 0.35))
    }

    private var sentState: WidgetSnapshot {
        var s = WidgetSnapshot.empty
        s.totalCount = 1284; s.lastSentCount = 48; s.lastSentDay = "Thursday"; s.updated = .now.addingTimeInterval(1)
        return s
    }
}
#endif

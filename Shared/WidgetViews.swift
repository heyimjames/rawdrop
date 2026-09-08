import WidgetKit
import SwiftUI

// MARK: - Views

private enum Grid {
    static let unit: CGFloat = 8
    static let padding: CGFloat = 24
}

private let amber = Color(red: 1.0, green: 0.78, blue: 0.18)

struct WaitingView: View {
    let snapshot: WidgetSnapshot
    let family: WidgetFamily

    var body: some View {
        Group {
            switch family {
            case .systemSmall: HomeSmall(snapshot: snapshot)
            case .systemMedium: HomeMedium(snapshot: snapshot)
            case .accessoryCircular: LockCircular(snapshot: snapshot)
            case .accessoryRectangular: LockRectangular(snapshot: snapshot)
            case .accessoryInline: LockInline(snapshot: snapshot)
            default: HomeSmall(snapshot: snapshot)
            }
        }
        .widgetURL(WidgetSnapshot.deepLink)
    }
}

/// The shared bottom group: hero number and its one line of context.
private struct Hero: View {
    let snapshot: WidgetSnapshot
    var heroSize: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.unit / 2) {
            if snapshot.totalCount == 0 {
                Text("No RAW yet")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                Text("Import from your camera")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            } else if snapshot.waitingCount == 0 {
                HStack(spacing: Grid.unit) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                    Text("All sent")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                if let count = snapshot.lastSentCount, let day = snapshot.lastSentDay {
                    Text("\(count.formatted()) on \(day)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            } else {
                Text(snapshot.waitingCount.formatted())
                    .font(.system(size: heroSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .contentTransition(.numericText(value: Double(snapshot.waitingCount)))
                    .widgetAccentable()
                Text(snapshot.waitingCount == 1 ? "waiting for Lightroom" : "waiting for Lightroom")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

private struct RawLabel: View {
    var body: some View {
        Text("RAW")
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(amber)
            .widgetAccentable()
    }
}

private struct HomeSmall: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RawLabel()
            Spacer(minLength: Grid.unit)
            Hero(snapshot: snapshot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Grid.padding)
        .containerBackground(.black, for: .widget)
    }
}

private struct HomeMedium: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: Grid.unit * 2) {
            VStack(alignment: .leading, spacing: 0) {
                RawLabel()
                Spacer(minLength: Grid.unit)
                Hero(snapshot: snapshot, heroSize: 52)
                if snapshot.waitingCount > 0, let day = snapshot.latestDay {
                    Text("\(snapshot.latestDayCount.formatted()) from \(day)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .padding(.top, Grid.unit / 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if !snapshot.thumbnails.isEmpty {
                WidgetThumbnails(snapshot: snapshot)
            }
        }
        .padding(Grid.padding)
        .containerBackground(.black, for: .widget)
    }
}

/// Four newest waiting photos in a 2×2, so the shoot is recognisable.
private struct WidgetThumbnails: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        let names = Array(snapshot.thumbnails.prefix(4))
        let columns = [GridItem(.flexible(), spacing: Grid.unit), GridItem(.flexible(), spacing: Grid.unit)]
        LazyVGrid(columns: columns, spacing: Grid.unit) {
            ForEach(names, id: \.self) { name in
                Color(white: 0.12)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let url = snapshot.thumbnailURL(name), let image = UIImage(contentsOfFile: url.path) {
                            Image(uiImage: image).resizable().scaledToFill()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Grid.unit, style: .continuous))
            }
        }
        .frame(width: 118)
    }
}

// MARK: Lock Screen

private struct LockCircular: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                if snapshot.waitingCount == 0 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                } else {
                    Text(snapshot.waitingCount.formatted())
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
                Text("RAW")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
            }
            .padding(6)
        }
        .containerBackground(.clear, for: .widget)
    }
}

private struct LockRectangular: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: Grid.unit) {
            Image(systemName: snapshot.waitingCount == 0 ? "checkmark.circle" : "camera.aperture")
                .font(.system(size: 22, weight: .regular))
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.waitingCount == 0 ? "All RAW sent" : "\(snapshot.waitingCount.formatted()) RAW waiting")
                    .font(.headline)
                    .lineLimit(1)
                if snapshot.waitingCount > 0, let day = snapshot.latestDay {
                    Text("\(snapshot.latestDayCount.formatted()) from \(day)")
                        .font(.caption)
                        .lineLimit(1)
                } else if let count = snapshot.lastSentCount, let day = snapshot.lastSentDay {
                    Text("\(count.formatted()) on \(day)")
                        .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.clear, for: .widget)
    }
}

private struct LockInline: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        if snapshot.waitingCount == 0 {
            Text("All RAW sent")
        } else {
            Text("\(snapshot.waitingCount.formatted()) RAW waiting")
        }
    }
}

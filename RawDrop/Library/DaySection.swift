import Foundation

/// Photos grouped by the day they were shot. A shoot is a day.
struct DaySection: Identifiable {
    let id: Date          // start of day
    let title: String
    let photos: [RawPhoto]
    /// Where most of the day's located photos were taken: "New York City".
    var place: String?

    static func group(_ photos: [RawPhoto], places: [Date: String] = [:],
                      calendar: Calendar = .current) -> [DaySection] {
        var order: [Date] = []
        var buckets: [Date: [RawPhoto]] = [:]

        for photo in photos {
            let day = calendar.startOfDay(for: photo.creationDate ?? .distantPast)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(photo)
        }

        let thisYear = calendar.component(.year, from: .now)
        return order.map { day in
            let year = calendar.component(.year, from: day)
            let style: Date.FormatStyle = year == thisYear
                ? .dateTime.weekday(.wide).day().month(.wide)
                : .dateTime.weekday(.abbreviated).day().month(.wide).year()
            return DaySection(id: day, title: day.formatted(style), photos: buckets[day] ?? [], place: places[day])
        }
    }

    /// The place name for each day, from a handful of its photos. Uses the
    /// big city when there is one, so a day in Williamsburg reads "New York City".
    static func places(for photos: [RawPhoto], calendar: Calendar = .current) -> [Date: String] {
        var sampled: [Date: [String]] = [:]
        for photo in photos {
            guard let location = photo.asset.location else { continue }
            let day = calendar.startOfDay(for: photo.creationDate ?? .distantPast)
            guard sampled[day, default: []].count < 6 else { continue }
            if let place = PlaceIndex.shared.place(for: location) {
                sampled[day, default: []].append(place.metro ?? place.name)
            }
        }
        return sampled.compactMapValues { names in
            Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +).max { $0.value < $1.value }?.key
        }
    }
}

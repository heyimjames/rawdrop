import Foundation

/// Photos grouped by the day they were shot. A shoot is a day.
struct DaySection: Identifiable {
    let id: Date          // start of day
    let title: String
    let photos: [RawPhoto]

    static func group(_ photos: [RawPhoto], calendar: Calendar = .current) -> [DaySection] {
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
            return DaySection(id: day, title: day.formatted(style), photos: buckets[day] ?? [])
        }
    }
}

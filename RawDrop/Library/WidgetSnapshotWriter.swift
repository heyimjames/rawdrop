import Photos
import UIKit
import WidgetKit

/// Keeps the widget's snapshot current. Called after the library loads and
/// after every completed send; cheap enough to run every time.
enum WidgetSnapshotWriter {

    static func update(allPhotos: [RawPhoto], sentIDs: Set<String>, lastSend: (count: Int, date: Date)?) {
        let waiting = allPhotos.filter { !sentIDs.contains($0.id) }   // newest first already
        let calendar = Calendar.current

        var snapshot = WidgetSnapshot.empty
        snapshot.totalCount = allPhotos.count
        snapshot.waitingCount = waiting.count
        snapshot.updated = .now

        if let newest = waiting.first, let date = newest.creationDate {
            let day = calendar.startOfDay(for: date)
            snapshot.latestDay = dayTitle(day)
            snapshot.latestDayCount = waiting.prefix(2000).filter {
                $0.creationDate.map { calendar.startOfDay(for: $0) == day } ?? false
            }.count
        }
        if let lastSend {
            snapshot.lastSentCount = lastSend.count
            snapshot.lastSentDay = dayTitle(calendar.startOfDay(for: lastSend.date), short: true)
        }

        let forThumbs = Array(waiting.prefix(4))
        Task.detached(priority: .utility) {
            var snapshot = snapshot
            snapshot.thumbnails = await writeThumbnails(for: forThumbs)
            try? snapshot.save()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private static func dayTitle(_ day: Date, short: Bool = false) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let thisYear = calendar.component(.year, from: .now) == calendar.component(.year, from: day)
        if short {
            return day.formatted(thisYear ? .dateTime.weekday(.wide) : .dateTime.day().month(.abbreviated).year())
        }
        return day.formatted(thisYear ? .dateTime.weekday(.wide).day().month(.wide)
                                      : .dateTime.weekday(.abbreviated).day().month(.wide).year())
    }

    /// 320px JPEGs, small enough that the widget loads four in a blink.
    private static func writeThumbnails(for photos: [RawPhoto]) async -> [String] {
        guard let dir = WidgetSnapshot.containerURL else { return [] }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var names: [String] = []
        for (index, photo) in photos.enumerated() {
            guard let image = await thumbnail(for: photo.asset),
                  let data = image.jpegData(compressionQuality: 0.8) else { continue }
            let name = "thumb-\(index).jpg"
            if (try? data.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil {
                names.append(name)
            }
        }
        return names
    }

    private static func thumbnail(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 320, height: 320), contentMode: .aspectFill, options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}

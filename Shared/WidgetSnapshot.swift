import Foundation

/// What the widget knows. Written by the app, read by the widget extension,
/// through the shared App Group container. The widget never touches PhotoKit.
struct WidgetSnapshot: Codable, Equatable {
    static let appGroup = "group.com.jamesfrewin.RawDrop"
    static let deepLink = URL(string: "rawdrop://select-new")!

    var totalCount: Int
    var waitingCount: Int
    /// Day of the newest waiting photo, e.g. "Thursday 4 September".
    var latestDay: String?
    /// How many waiting photos were shot that day.
    var latestDayCount: Int
    /// Filenames (in the container) of thumbnails for the newest waiting photos.
    var thumbnails: [String]
    /// Last completed send, for the all-sent state.
    var lastSentCount: Int?
    var lastSentDay: String?
    var updated: Date

    static let placeholder = WidgetSnapshot(
        totalCount: 1_284, waitingCount: 128, latestDay: "Thursday 4 September",
        latestDayCount: 48, thumbnails: [], lastSentCount: nil, lastSentDay: nil, updated: .now
    )

    static let empty = WidgetSnapshot(
        totalCount: 0, waitingCount: 0, latestDay: nil, latestDayCount: 0,
        thumbnails: [], lastSentCount: nil, lastSentDay: nil, updated: .now
    )

    // MARK: Storage

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("widget", isDirectory: true)
    }

    static func load() -> WidgetSnapshot? {
        guard let url = containerURL?.appendingPathComponent("snapshot.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() throws {
        guard let dir = Self.containerURL else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: dir.appendingPathComponent("snapshot.json"), options: .atomic)
    }

    func thumbnailURL(_ name: String) -> URL? {
        Self.containerURL?.appendingPathComponent(name)
    }
}

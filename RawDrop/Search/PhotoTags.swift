import Foundation

/// Everything RawDrop has worked out about one photo that it could not get
/// from Photos for free. Date, favourite and sent are read live instead.
struct PhotoTags: Codable, Sendable, Equatable {
    /// Bumped when the tagger learns something new, so old entries are redone.
    static let currentVersion = 1

    var version = PhotoTags.currentVersion
    var filename: String?
    var make: String?            // "FUJIFILM"
    var model: String?           // "X100VI"
    var lens: String?            // "XF23mmF2 R WR"
    var focal: Int?              // 23
    var aperture: Double?        // 2.0
    var iso: Int?                // 3200
    var place: Place?
    /// What Vision sees, most confident first: ["food", "dessert", "table"].
    var subjects: [String] = []
    /// Words Vision read in the frame: shop signs, labels, menus.
    var words: [String] = []
    var people = 0
    /// False when Photos had no local image to look at, usually because the
    /// original lives in iCloud. Metadata is still indexed; content is not.
    var sawImage = false

    /// "FUJIFILM X100VI" reads as "Fujifilm X100VI".
    var camera: String? {
        guard let model else { return make.map(Self.tidy) }
        guard let make, !model.lowercased().hasPrefix(make.lowercased()) else { return model }
        return "\(Self.tidy(make)) \(model)"
    }

    private static func tidy(_ make: String) -> String {
        let known = ["FUJIFILM": "Fujifilm", "NIKON CORPORATION": "Nikon", "NIKON": "Nikon",
                     "SONY": "Sony", "Canon": "Canon", "OLYMPUS CORPORATION": "Olympus",
                     "OM Digital Solutions": "OM System", "LEICA CAMERA AG": "Leica", "LEICA": "Leica",
                     "RICOH IMAGING COMPANY, LTD.": "Ricoh", "PENTAX": "Pentax", "Panasonic": "Panasonic",
                     "Hasselblad": "Hasselblad", "Apple": "Apple"]
        return known[make] ?? make.capitalized
    }
}

/// The tags for every photo seen so far, kept in one file in Application
/// Support. Read and written from the indexer's background tasks and read
/// from search, so it guards itself.
final class TagStore: @unchecked Sendable {
    static let shared = TagStore()

    private var tags: [String: PhotoTags] = [:]
    private let lock = NSLock()
    private var dirty = 0
    private var saving = false
    private var lastSave = Date.now

    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawDrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tags.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let stored = try? JSONDecoder().decode([String: PhotoTags].self, from: data) {
            tags = stored
        }
    }

    func tags(for id: String) -> PhotoTags? {
        lock.lock(); defer { lock.unlock() }
        return tags[id]
    }

    /// Up to date for this version of the tagger.
    func isCurrent(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tags[id]?.version == PhotoTags.currentVersion
    }

    func snapshot() -> [String: PhotoTags] {
        lock.lock(); defer { lock.unlock() }
        return tags
    }

    /// Rewriting the whole file costs more as the library grows, so it
    /// happens every few hundred photos or half a minute, not every photo.
    func set(_ value: PhotoTags, for id: String) {
        lock.lock()
        tags[id] = value
        dirty += 1
        let flush = dirty >= 250 || Date.now.timeIntervalSince(lastSave) > 30
        lock.unlock()
        if flush { save() }
    }

    /// Writes off the calling thread. Overlapping saves collapse into one.
    func save() {
        lock.lock()
        guard dirty > 0, !saving else { lock.unlock(); return }
        saving = true
        dirty = 0
        lastSave = .now
        let copy = tags
        lock.unlock()

        Task.detached(priority: .utility) { [self] in
            if let data = try? JSONEncoder().encode(copy) {
                try? data.write(to: Self.url, options: .atomic)
            }
            let again = lock.withLock {
                saving = false
                return dirty > 0
            }
            if again { save() }
        }
    }
}

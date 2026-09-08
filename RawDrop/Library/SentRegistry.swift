import Foundation
import Observation

/// Remembers which photos have already been handed to Lightroom so the grid
/// can show it. Only ever written after the share sheet reports completion.
///
/// Lives in its own file rather than UserDefaults: a large library can mean
/// tens of thousands of identifiers, and UserDefaults rewrites everything
/// it holds on every change.
@MainActor
@Observable
final class SentRegistry {
    private(set) var ids: Set<String>
    private(set) var lastSend: (count: Int, date: Date)?

    private struct Stored: Codable {
        var ids: [String]
        var lastCount: Int?
        var lastDate: Date?
    }

    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawDrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sent.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            ids = Set(stored.ids)
            if let c = stored.lastCount, let d = stored.lastDate { lastSend = (c, d) }
        } else if let data = try? Data(contentsOf: Self.url),
                  let list = try? JSONDecoder().decode([String].self, from: data) {
            ids = Set(list)
        } else {
            // One-time carry-over from the first builds, which used UserDefaults.
            ids = Set(UserDefaults.standard.stringArray(forKey: "sentPhotoIDs") ?? [])
            if !ids.isEmpty { save() }
        }
    }

    func markSent(_ newIDs: some Sequence<String>) {
        let added = Set(newIDs)
        ids.formUnion(added)
        lastSend = (added.count, .now)
        save()
    }

    private func save() {
        let stored = Stored(ids: Array(ids), lastCount: lastSend?.count, lastDate: lastSend?.date)
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(stored) {
                try? data.write(to: Self.url, options: .atomic)
            }
        }
    }
}

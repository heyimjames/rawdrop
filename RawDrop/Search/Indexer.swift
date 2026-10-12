import Foundation
import Observation

/// Works through the library in the background, newest first, tagging each
/// photo once. Stops while the app is in the background or a send is
/// running, and slows down when the phone is warm.
@MainActor
@Observable
final class Indexer {
    private(set) var total = 0
    private(set) var done = 0
    private(set) var isRunning = false

    var remaining: Int { max(total - done, 0) }
    var fraction: Double { total == 0 ? 1 : Double(done) / Double(total) }

    /// Told when a batch of new tags is ready, at most every couple of seconds.
    @ObservationIgnored var onNewTags: (() -> Void)?

    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var lastNotice = Date.distantPast
    @ObservationIgnored private var queued: Set<String> = []

    /// Called whenever the library's RAWs change. Only photos without
    /// current tags are queued; the rest were done on an earlier visit.
    func sync(with photos: [RawPhoto]) {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            // The first touch of the store reads it from disk. Not on main.
            let todo = await Task.detached(priority: .utility) {
                photos.filter { !TagStore.shared.isCurrent($0.id) }
            }.value
            guard !Task.isCancelled else { return }
            self?.start(todo, of: photos.count)
        }
    }

    private func start(_ todo: [RawPhoto], of count: Int) {
        total = count
        done = total - todo.count
        let ids = Set(todo.map(\.id))
        // Already working through these (a reload that only removed some,
        // like a heart being tapped): carry on rather than start over.
        if worker != nil, ids.isSubset(of: queued) { return }
        queued = ids

        worker?.cancel()
        worker = nil
        guard !todo.isEmpty else {
            isRunning = false
            onNewTags?()
            return
        }
        worker = Task { [weak self] in await self?.run(todo) }
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        // Going to the background is the moment to make sure nothing is lost.
        if paused { Task.detached(priority: .utility) { TagStore.shared.save() } }
    }

    private func run(_ queue: [RawPhoto]) async {
        isRunning = true
        defer {
            if !Task.isCancelled {
                isRunning = false
                queued = []
                worker = nil
            }
        }

        let lanes = ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 2
        await withTaskGroup(of: (String, PhotoTags).self) { group in
            var next = 0
            func enqueue() {
                guard next < queue.count else { return }
                let photo = queue[next]
                next += 1
                group.addTask(priority: .utility) { (photo.id, await Tagger.tags(for: photo)) }
            }
            for _ in 0..<lanes { enqueue() }

            for await (id, tags) in group {
                if Task.isCancelled { group.cancelAll(); break }
                TagStore.shared.set(tags, for: id)
                done += 1
                noticeIfDue()

                while paused && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(400))
                }
                switch ProcessInfo.processInfo.thermalState {
                case .serious: try? await Task.sleep(for: .milliseconds(250))
                case .critical: try? await Task.sleep(for: .seconds(2))
                default: break
                }
                enqueue()
            }
        }
        TagStore.shared.save()
        if !Task.isCancelled { onNewTags?() }
    }

    private func noticeIfDue() {
        guard Date.now.timeIntervalSince(lastNotice) > 2 else { return }
        lastNotice = .now
        onNewTags?()
    }
}

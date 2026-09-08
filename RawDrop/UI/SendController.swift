import Foundation
import Observation

/// Drives the send flow: extract a batch → share it → next batch → sent.
/// One state machine, one bar. Batches exist only because Lightroom's share
/// extension has a ceiling; from the user's side it is still one tap.
@MainActor
@Observable
final class SendController {

    enum Phase: Equatable {
        case idle
        case extracting(done: Int, total: Int, fraction: Double)
        case sharing(batch: Int, batchCount: Int)
        case sent(count: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    var shareBatch: ShareBatch?

    /// The photo whose RAW is being copied right now. Drives the tile sweep.
    private(set) var currentPhotoID: String?

    /// Increments once per completed hand-off. Drives the success haptic.
    private(set) var completedBatches = 0

    private var batches: [[RawPhoto]] = []
    private var batchIndex = 0
    private var totalCount = 0
    private var sentSoFar = 0
    private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .extracting, .sharing: true
        default: false
        }
    }

    // MARK: Start

    func send(_ photos: [RawPhoto]) {
        guard !isBusy, !photos.isEmpty else { return }
        batches = stride(from: 0, to: photos.count, by: Handoff.maxPhotosPerShare).map {
            Array(photos[$0..<min($0 + Handoff.maxPhotosPerShare, photos.count)])
        }
        batchIndex = 0
        totalCount = photos.count
        sentSoFar = 0
        extractCurrentBatch()
    }

    func cancel() {
        task?.cancel()
    }

    private func extractCurrentBatch() {
        let batch = batches[batchIndex]
        let offset = batches[..<batchIndex].reduce(0) { $0 + $1.count }
        let total = totalCount
        phase = .extracting(done: offset, total: total, fraction: Double(offset) / Double(total))

        task = Task {
            do {
                let files = try await RawExporter.export(batch) { [weak self] index, fileFraction in
                    guard let self else { return }
                    let done = offset + index
                    currentPhotoID = index < batch.count ? batch[index].id : nil
                    let overall = (Double(done) + fileFraction) / Double(total)
                    phase = .extracting(done: done, total: total, fraction: min(overall, 1))
                }
                currentPhotoID = nil
                phase = .sharing(batch: batchIndex + 1, batchCount: batches.count)
                shareBatch = ShareBatch(files: files)
            } catch is CancellationError {
                reset()
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError {
                reset()
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    // MARK: Share sheet result

    /// Called when a share sheet closes. Returns the IDs that were sent in
    /// that batch, if any, and moves on to the next batch by itself.
    func shareFinished(completed: Bool) -> [String] {
        let files = shareBatch?.files ?? []
        shareBatch = nil
        scheduleCleanup(of: files)

        guard completed else {
            reset()
            return []
        }

        sentSoFar += files.count
        completedBatches += 1
        batchIndex += 1

        if batchIndex < batches.count {
            extractCurrentBatch()
        } else {
            phase = .sent(count: sentSoFar)
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                if case .sent = phase { reset() }
            }
        }
        return files.map(\.photoID)
    }

    // MARK: Housekeeping

    private func reset() {
        phase = .idle
        currentPhotoID = nil
        batches = []
        batchIndex = 0
    }

    private func fail(_ message: String) {
        currentPhotoID = nil
        phase = .failed(message)
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if case .failed = phase { reset() }
        }
    }

    /// Lightroom copies on import, so the temp copies are no longer needed.
    /// Give any in-flight extension a moment before the folder goes away.
    private func scheduleCleanup(of files: [ExportedFile]) {
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(8))
            RawExporter.remove(batchContaining: files)
        }
    }
}

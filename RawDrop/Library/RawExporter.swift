import Photos

struct ExportedFile: Identifiable {
    let photoID: String
    let url: URL
    let bytes: Int64
    var id: String { photoID }
}

/// Copies the RAW resource of each photo into a temporary batch folder,
/// keeping the camera's original filename so Lightroom sees `DSC04281.ARW`.
enum RawExporter {

    private static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RawDrop", isDirectory: true)

    static func purgeAllBatches() {
        try? FileManager.default.removeItem(at: root)
    }

    static func remove(batchContaining files: [ExportedFile]) {
        guard let first = files.first else { return }
        try? FileManager.default.removeItem(at: first.url.deletingLastPathComponent())
    }

    /// `progress(index, fraction)` reports the file currently being written and
    /// how far through it we are, in 0...1.
    static func export(
        _ photos: [RawPhoto],
        progress: @escaping @MainActor (Int, Double) -> Void
    ) async throws -> [ExportedFile] {
        let batch = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)

        var files: [ExportedFile] = []
        var usedNames = Set<String>()

        for (index, photo) in photos.enumerated() {
            try Task.checkCancellation()

            guard let resource = RawResolver.rawResource(for: photo.asset) else {
                throw ExportError.noRaw
            }

            let name = uniqueName(resource.originalFilename, index: index, used: &usedNames)
            let url = batch.appendingPathComponent(name)

            await progress(index, 0)
            do {
                try await write(resource, to: url) { fraction in
                    Task { @MainActor in progress(index, fraction) }
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }

            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            files.append(ExportedFile(photoID: photo.id, url: url, bytes: bytes))
            await progress(index + 1, 0)
        }
        return files
    }

    private static func uniqueName(_ original: String, index: Int, used: inout Set<String>) -> String {
        var name = original.isEmpty ? "RAW-\(index + 1)" : original
        if used.contains(name.lowercased()) {
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            name = ext.isEmpty ? "\(stem)-\(index + 1)" : "\(stem)-\(index + 1).\(ext)"
        }
        used.insert(name.lowercased())
        return name
    }

    /// Streams the resource into `url`. The streaming variant is the only one
    /// that hands back a request ID, which is what makes Cancel actually stop
    /// a 50 MB iCloud download instead of letting it finish in the background.
    private static func write(
        _ resource: PHAssetResource,
        to url: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true   // pull from iCloud if the original was offloaded
        options.progressHandler = progress

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let manager = PHAssetResourceManager.default()
        let request = RequestHandle()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                request.id = manager.requestData(for: resource, options: options) { chunk in
                    handle.write(chunk)
                } completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            if let id = request.id { manager.cancelDataRequest(id) }
        }
    }

    enum ExportError: LocalizedError {
        case noRaw
        var errorDescription: String? {
            switch self {
            case .noRaw: "One of the photos has no RAW file inside it."
            }
        }
    }
}

private final class RequestHandle: @unchecked Sendable {
    var id: PHAssetResourceDataRequestID?
}

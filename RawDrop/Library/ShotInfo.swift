import Photos
import ImageIO

/// What the camera wrote into the file. Read from the JPEG resource's EXIF,
/// which is the same capture as the RAW and sits in the first few hundred
/// kilobytes, so only that much is ever loaded.
struct ShotInfo: Equatable {
    var camera: String?
    var lens: String?
    var focalLength: String?
    var aperture: String?
    var shutter: String?
    var iso: String?

    // The same facts as numbers, for search.
    var make: String?
    var model: String?
    var focalValue: Int?
    var fNumber: Double?
    var isoValue: Int?

    /// "35mm · ƒ/1.8 · 1/250 · ISO 200"
    var line: String {
        [focalLength, aperture, shutter, iso].compactMap { $0 }.joined(separator: " · ")
    }

    /// `allowNetwork` false reads only what is already on the phone: the
    /// indexer must never start pulling originals down from iCloud.
    static func load(for asset: PHAsset, allowNetwork: Bool = true) async -> ShotInfo? {
        let resources = PHAssetResource.assetResources(for: asset)
        // Prefer the JPEG: its EXIF is standard. Fall back to whatever is primary.
        let resource = resources.first { $0.type == .photo && !RawResolver.isRaw($0) }
            ?? resources.first { $0.type == .photo }
            ?? resources.first
        guard let resource else { return nil }

        if let head = await readHead(of: resource, upTo: 768 * 1024, allowNetwork: allowNetwork),
           let info = parse(head) {
            return info
        }
        guard allowNetwork else { return nil }
        return parse(await fullData(for: asset))
    }

    // MARK: Reading

    /// Streams the resource and stops once `limit` bytes have arrived.
    private static func readHead(of resource: PHAssetResource, upTo limit: Int, allowNetwork: Bool) async -> Data? {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        let manager = PHAssetResourceManager.default()
        let box = HeadBox()

        return await withCheckedContinuation { continuation in
            box.id = manager.requestData(for: resource, options: options) { chunk in
                box.append(chunk)
                if box.count >= limit, let id = box.id, !box.stopped {
                    box.stopped = true
                    manager.cancelDataRequest(id)
                }
            } completionHandler: { _ in
                continuation.resume(returning: box.data.isEmpty ? nil : box.data)
            }
        }
    }

    private static func fullData(for asset: PHAsset) async -> Data? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: Parsing

    private static func parse(_ data: Data?) -> ShotInfo? {
        guard let data else { return nil }
        // Incremental source: happy with a truncated file as long as the
        // metadata segments are complete.
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, false)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        guard !tiff.isEmpty || !exif.isEmpty else { return nil }

        var info = ShotInfo()

        info.make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        info.model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model = tiff[kCGImagePropertyTIFFModel] as? String {
            let make = (tiff[kCGImagePropertyTIFFMake] as? String) ?? ""
            info.camera = model.lowercased().hasPrefix(make.lowercased()) || make.isEmpty
                ? model
                : "\(make.capitalized) \(model)"
        }
        info.lens = exif[kCGImagePropertyExifLensModel] as? String

        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            info.focalLength = "\(Int(focal.rounded()))mm"
            info.focalValue = Int(focal.rounded())
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double {
            info.aperture = "ƒ/" + (f == f.rounded() ? "\(Int(f))" : String(format: "%.1f", f))
            info.fNumber = f
        }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            info.shutter = t < 1 ? "1/\(Int((1 / t).rounded()))" : "\(t.formatted(.number.precision(.fractionLength(0...1))))s"
        }
        if let isoValues = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = isoValues.first {
            info.iso = "ISO \(iso)"
            info.isoValue = iso
        }
        return info
    }
}

private final class HeadBox: @unchecked Sendable {
    var id: PHAssetResourceDataRequestID?
    var stopped = false
    private(set) var data = Data()
    var count: Int { data.count }
    func append(_ chunk: Data) { data.append(chunk) }
}

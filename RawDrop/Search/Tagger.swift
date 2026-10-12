import Photos
import UIKit
import Vision

/// Looks at one photo and writes down what search needs to know about it.
/// Everything here runs on the phone: Vision for what is in the frame and
/// any words in it, the file's own EXIF for the camera, and the bundled
/// gazetteer for the place.
enum Tagger {

    /// Its own manager, so indexing never evicts the grid's cached thumbnails.
    private static let images = PHImageManager()

    /// Big enough for Vision to read a shop sign, small enough to stay quick.
    private static let side: CGFloat = 768

    static func tags(for photo: RawPhoto) async -> PhotoTags {
        var tags = PhotoTags()
        let asset = photo.asset

        tags.filename = RawResolver.info(for: asset)?.filename
        if let location = asset.location {
            tags.place = PlaceIndex.shared.place(for: location)
        }
        if let shot = await ShotInfo.load(for: asset, allowNetwork: false) {
            tags.make = shot.make
            tags.model = shot.model
            tags.lens = shot.lens
            tags.focal = shot.focalValue
            tags.aperture = shot.fNumber
            tags.iso = shot.isoValue
        }

        guard !Task.isCancelled, let image = await localImage(for: asset), let cgImage = image.cgImage else {
            return tags
        }
        tags.sawImage = true

        let handler = ImageRequestHandler(cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation))
        var text = RecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false

        do {
            let (labels, lines, humans) = try await handler.perform(
                ClassifyImageRequest(), text, DetectHumanRectanglesRequest()
            )
            tags.subjects = subjects(from: labels)
            tags.words = words(from: lines.compactMap { $0.topCandidates(1).first?.string })
            tags.people = humans.filter { $0.confidence > 0.5 }.count
        } catch {
            // A photo Vision cannot read keeps its metadata. Not worth more than that.
        }
        return tags
    }

    // MARK: Image

    /// Whatever Photos has on the phone, never a download.
    private static func localImage(for asset: PHAsset) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.version = .current

        if let image = await request(asset, CGSize(width: side, height: side), options) {
            return image
        }
        // In iCloud only: the small cached thumbnail is still worth classifying.
        options.deliveryMode = .fastFormat
        return await request(asset, CGSize(width: 360, height: 360), options)
    }

    private static func request(_ asset: PHAsset, _ size: CGSize, _ options: PHImageRequestOptions) async -> UIImage? {
        await withCheckedContinuation { continuation in
            images.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: Reading Vision's answers

    /// Labels Vision is sure of, plus its top few guesses when it is fairly
    /// sure. Underscores become spaces: "ice_cream" → "ice cream".
    private static func subjects(from labels: [ClassificationObservation]) -> [String] {
        let sure = labels.filter { $0.hasMinimumRecall(0.01, forPrecision: 0.85) }
        let likely = labels.sorted { $0.confidence > $1.confidence }.prefix(4).filter { $0.confidence > 0.35 }
        var seen = Set<String>()
        var out: [String] = []
        for label in sure + likely {
            let name = label.identifier.replacingOccurrences(of: "_", with: " ")
            if seen.insert(name).inserted { out.append(name) }
        }
        return Array(out.prefix(14))
    }

    /// Distinct words of three or more letters, in the order they were read.
    private static func words(from lines: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in lines {
            for word in SearchText.tokens(line) where word.count >= 3 && word.contains(where: \.isLetter) {
                if seen.insert(word).inserted { out.append(word) }
            }
        }
        return Array(out.prefix(60))
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

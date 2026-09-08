import Photos
import UniformTypeIdentifiers

/// Answers one question: which of an asset's resources is the RAW file?
///
/// A camera import of a RAW+JPEG pair lands in Photos as a single asset with
/// two resources. The JPEG is `.photo` (the primary, which is all Lightroom
/// ever sees). The RAW is usually `.alternatePhoto`. Cameras and Photos
/// settings vary, so we identify the RAW by its type rather than its slot.
enum RawResolver {

    /// Extensions Photos may report for RAW originals, used as a fallback when
    /// the UTI is not registered on the device.
    static let rawExtensions: Set<String> = [
        "arw", "srf", "sr2",            // Sony
        "cr2", "cr3", "crw",            // Canon
        "nef", "nrw",                   // Nikon
        "raf",                          // Fujifilm
        "dng", "gpr",                   // Adobe / GoPro
        "orf",                          // Olympus / OM
        "rw2", "raw",                   // Panasonic / Leica
        "pef",                          // Pentax
        "srw",                          // Samsung
        "3fr", "fff",                   // Hasselblad
        "iiq",                          // Phase One
        "erf", "x3f", "mos", "mrw", "kdc", "dcr", "rwl",
    ]

    static func rawResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)

        // Originals only. `.fullSizePhoto` is the edited render, never the RAW.
        let originals = resources.filter { $0.type == .photo || $0.type == .alternatePhoto }

        if let raw = originals.first(where: isRaw) {
            return raw
        }
        // Last resort: an alternate we could not classify is still more likely
        // to be the RAW than the JPEG primary.
        return originals.first { $0.type == .alternatePhoto }
    }

    static func info(for asset: PHAsset) -> RawInfo? {
        rawResource(for: asset).map { RawInfo(filename: $0.originalFilename) }
    }

    static func isRaw(_ resource: PHAssetResource) -> Bool {
        if let type = UTType(resource.uniformTypeIdentifier), type.conforms(to: .rawImage) {
            return true
        }
        let ext = (resource.originalFilename as NSString).pathExtension.lowercased()
        return rawExtensions.contains(ext)
    }
}

import Photos

/// One Photos asset that carries a RAW resource somewhere inside it.
struct RawPhoto: Identifiable, Hashable {
    let id: String
    let asset: PHAsset
    /// Normally the asset's date; overridden only by the fake-library flag.
    let creationDate: Date?
    /// As Photos had it when the library was read. RawLibrary keeps the live
    /// answer, which also covers a heart tapped a moment ago in the viewer.
    let isFavorite: Bool

    init(asset: PHAsset) {
        self.id = asset.localIdentifier
        self.asset = asset
        self.creationDate = asset.creationDate
        self.isFavorite = asset.isFavorite
    }

    #if DEBUG
    init(asset: PHAsset, fakeID: String, fakeDate: Date) {
        self.id = fakeID
        self.asset = asset
        self.creationDate = fakeDate
        self.isFavorite = asset.isFavorite
    }
    #endif

    static func == (lhs: RawPhoto, rhs: RawPhoto) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Details we only learn by opening the asset's resource list.
struct RawInfo: Hashable {
    let filename: String     // DSC04281.ARW
    let format: String       // ARW

    init(filename: String) {
        self.filename = filename
        self.format = (filename as NSString).pathExtension.uppercased()
    }
}

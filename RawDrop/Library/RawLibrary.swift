import Photos
import PhotosUI
import Observation
import UIKit

/// A user album, offered as a way to narrow the grid to one shoot.
struct AlbumRef: Identifiable, Hashable {
    let id: String
    let title: String
    let collection: PHAssetCollection
}

/// The list of RAW-bearing photos, kept live against the Photos library.
@MainActor
@Observable
final class RawLibrary: NSObject, PHPhotoLibraryChangeObserver {

    private(set) var status: PHAuthorizationStatus
    private(set) var photos: [RawPhoto] = []
    private(set) var sections: [DaySection] = []
    /// Index of each photo in newest-first order. Used for the landing stagger.
    private(set) var position: [String: Int] = [:]
    private(set) var info: [String: RawInfo] = [:]
    private(set) var isLoading = false

    /// Every RAW in the library regardless of album, newest first. The widget
    /// counts against this, not the album view.
    private(set) var allPhotos: [RawPhoto] = []
    private(set) var albums: [AlbumRef] = []
    private(set) var album: AlbumRef?

    /// Every RAW asset in the library, regardless of album.
    private var rawIDs: Set<String> = []
    private var rawResult: PHFetchResult<PHAsset>?
    private var loadTask: Task<Void, Never>?
    private var infoInFlight: Set<String> = []

    override init() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
    }

    var isAuthorized: Bool { status == .authorized || status == .limited }

    // MARK: Access

    func start() {
        guard isAuthorized else { return }
        PHPhotoLibrary.shared().register(self)
        reload()
    }

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if isAuthorized { start() }
    }

    func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }

    // MARK: Album

    func select(album: AlbumRef?) {
        guard album != self.album else { return }
        self.album = album
        reload()
    }

    // MARK: Loading

    /// Everything that touches the Photos database happens off the main
    /// thread. With tens of thousands of RAWs, even enumerating a fetch
    /// result is too slow to block a tap on.
    private func reload() {
        loadTask?.cancel()
        isLoading = photos.isEmpty
        let chosen = album

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let rawResult = Self.fetchRawAssets()
            var all: [RawPhoto] = []
            all.reserveCapacity(rawResult.count)
            rawResult.enumerateObjects { asset, _, _ in all.append(RawPhoto(asset: asset)) }
            let rawIDs = Set(all.map(\.id))

            var visible: [RawPhoto]
            if let chosen {
                var inAlbum: [RawPhoto] = []
                Self.fetchAssets(in: chosen.collection).enumerateObjects { asset, _, _ in
                    if rawIDs.contains(asset.localIdentifier) { inAlbum.append(RawPhoto(asset: asset)) }
                }
                visible = inAlbum
            } else {
                visible = all
            }

            #if DEBUG
            // `-fake-library N` repeats the real assets to N photos so large
            // library performance can be checked on a simulator.
            if let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "-fake-library"),
               let n = Int(ProcessInfo.processInfo.arguments[safe: flag + 1] ?? ""), !visible.isEmpty {
                let base = visible
                visible = (0..<n).map { i in
                    RawPhoto(asset: base[i % base.count].asset, fakeID: "fake-\(i)",
                             fakeDate: Date(timeIntervalSinceNow: -Double(i / 60) * 86_400))
                }
            }
            #endif
            let sections = DaySection.group(visible)
            let position = Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($1.id, $0) })
            let albums = Self.fetchAlbums()
            if Task.isCancelled { return }

            await self?.publish(rawResult: rawResult, rawIDs: rawIDs, all: all, photos: visible,
                                sections: sections, position: position, albums: albums)
        }
    }

    private func publish(rawResult: PHFetchResult<PHAsset>, rawIDs: Set<String>, all: [RawPhoto], photos: [RawPhoto],
                         sections: [DaySection], position: [String: Int], albums: [AlbumRef]) {
        self.rawResult = rawResult
        self.rawIDs = rawIDs
        self.allPhotos = all
        self.photos = photos
        self.sections = sections
        self.position = position
        self.albums = albums
        isLoading = false
    }

    /// Photos maintains a "RAW" smart album. It is the only fast way to find
    /// RAW-bearing assets without opening every asset's resource list.
    private nonisolated static func fetchRawAssets() -> PHFetchResult<PHAsset> {
        let albums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumRAW, options: nil
        )
        if let album = albums.firstObject {
            return fetchAssets(in: album)
        }
        return PHAsset.fetchAssets(with: imageOptions)
    }

    private nonisolated static func fetchAssets(in collection: PHAssetCollection) -> PHFetchResult<PHAsset> {
        PHAsset.fetchAssets(in: collection, options: imageOptions)
    }

    private nonisolated static var imageOptions: PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return options
    }

    private nonisolated static func fetchAlbums() -> [AlbumRef] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        var list: [AlbumRef] = []
        result.enumerateObjects { collection, _, _ in
            guard let title = collection.localizedTitle, collection.estimatedAssetCount > 0 else { return }
            list.append(AlbumRef(id: collection.localIdentifier, title: title, collection: collection))
        }
        return list
    }

    // MARK: Per-photo details, on demand

    /// Filename and format come from the resource list, a per-asset database
    /// hit. Only tiles that are actually on screen ask for it.
    func resolveInfo(for photo: RawPhoto) {
        guard info[photo.id] == nil, !infoInFlight.contains(photo.id) else { return }
        infoInFlight.insert(photo.id)
        Task.detached(priority: .utility) { [weak self] in
            let resolved = RawResolver.info(for: photo.asset)
            await self?.store(resolved, for: photo.id)
        }
    }

    private func store(_ resolved: RawInfo?, for id: String) {
        infoInFlight.remove(id)
        if let resolved { info[id] = resolved }
    }

    // MARK: PHPhotoLibraryChangeObserver

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            guard let current = rawResult,
                  changeInstance.changeDetails(for: current) != nil || album != nil else { return }
            reload()
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

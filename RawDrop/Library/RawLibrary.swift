import Photos
import PhotosUI
import Observation
import UIKit

/// A user album, offered as a way to narrow the grid to one shoot.
struct AlbumRef: Identifiable, Hashable {
    let id: String
    let title: String
    let collection: PHAssetCollection
    /// How many of its photos carry a RAW. Albums with none are not offered.
    let rawCount: Int
}

/// What the grid is showing: everything, the favourites, or one album.
enum Scope: Hashable {
    case all
    case favourites
    case album(AlbumRef)

    var id: String {
        switch self {
        case .all: "all"
        case .favourites: "favourites"
        case .album(let album): album.id
        }
    }
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
    /// Bumped every time `photos` is replaced, so watchers can compare one
    /// number instead of tens of thousands of identifiers.
    private(set) var generation = 0

    /// Every RAW in the library regardless of scope, newest first. The widget
    /// and the search index work from this, not from what is on screen.
    private(set) var allPhotos: [RawPhoto] = []
    private(set) var albums: [AlbumRef] = []
    private(set) var scope: Scope = .all
    /// RAW photos marked as a favourite in Photos. Updated the moment a heart
    /// is tapped here, before Photos reports back.
    private(set) var favouriteIDs: Set<String> = []
    /// Where each day was shot, for the whole library. Search results are
    /// regrouped by day and borrow these rather than looking them up again.
    private(set) var placeByDay: [Date: String] = [:]
    /// Every RAW format seen so far: "RAF", "DNG". The grid only labels
    /// formats when there is more than one to tell apart.
    private(set) var formats: Set<String> = []

    var mixesFormats: Bool { formats.count > 1 }

    var album: AlbumRef? {
        if case .album(let album) = scope { return album }
        return nil
    }

    /// Every RAW asset in the library, regardless of scope.
    private var rawIDs: Set<String> = []
    private var rawResult: PHFetchResult<PHAsset>?
    private var albumResult: PHFetchResult<PHAssetCollection>?
    private var loadTask: Task<Void, Never>?
    private var albumTask: Task<Void, Never>?
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
        reload(albums: true)
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

    // MARK: Scope

    func select(_ scope: Scope) {
        guard scope != self.scope else { return }
        self.scope = scope
        reload()
    }

    // MARK: Favourites

    func isFavourite(_ photo: RawPhoto) -> Bool { favouriteIDs.contains(photo.id) }

    /// Sets the heart in Photos itself, so it shows in Photos and everywhere
    /// else. The grid changes at once; Photos catching up triggers a reload.
    func setFavourite(_ photo: RawPhoto, _ favourite: Bool) {
        guard favouriteIDs.contains(photo.id) != favourite else { return }
        if favourite { favouriteIDs.insert(photo.id) } else { favouriteIDs.remove(photo.id) }
        let asset = photo.asset
        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest(for: asset).isFavorite = favourite
                }
            } catch {
                // Photos said no. Put the heart back the way Photos has it.
                if favourite { favouriteIDs.remove(photo.id) } else { favouriteIDs.insert(photo.id) }
            }
        }
    }

    // MARK: Loading

    /// Everything that touches the Photos database happens off the main
    /// thread. With tens of thousands of RAWs, even enumerating a fetch
    /// result is too slow to block a tap on.
    private func reload(albums refreshAlbums: Bool = false) {
        loadTask?.cancel()
        isLoading = photos.isEmpty
        let chosen = scope
        let previousRawIDs = rawIDs

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let rawResult = Self.fetchRawAssets()
            var all: [RawPhoto] = []
            all.reserveCapacity(rawResult.count)
            rawResult.enumerateObjects { asset, _, _ in all.append(RawPhoto(asset: asset)) }
            let rawIDs = Set(all.map(\.id))
            let favourites = Set(all.lazy.filter(\.isFavorite).map(\.id))

            var visible: [RawPhoto]
            switch chosen {
            case .all:
                visible = all
            case .favourites:
                visible = all.filter(\.isFavorite)
            case .album(let album):
                var inAlbum: [RawPhoto] = []
                Self.fetchAssets(in: album.collection).enumerateObjects { asset, _, _ in
                    if rawIDs.contains(asset.localIdentifier) { inAlbum.append(RawPhoto(asset: asset)) }
                }
                visible = inAlbum
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
            // Known places go straight in; the first load names them after
            // the grid is up, so the gazetteer never delays the first paint.
            let known = await self?.placeByDay ?? [:]
            let sections = DaySection.group(visible, places: known)
            let position = Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($1.id, $0) })
            if Task.isCancelled { return }

            await self?.publish(rawResult: rawResult, rawIDs: rawIDs, all: all, favourites: favourites,
                                photos: visible, sections: sections, position: position)

            // Filenames the search index already holds tell us the formats
            // in the library long before the tiles that show them scroll in.
            // Once a second format turns up there is nothing left to learn.
            if await self?.mixesFormats == false {
                let indexed = Set(TagStore.shared.snapshot().values.compactMap { tags -> String? in
                    guard let name = tags.filename else { return nil }
                    let ext = (name as NSString).pathExtension.uppercased()
                    return ext.isEmpty ? nil : ext
                })
                if !indexed.isEmpty { await self?.addFormats(indexed) }
            }

            let places = DaySection.places(for: chosen == .all ? visible : all)
            if Task.isCancelled { return }
            if places != known {
                await self?.publish(places: places, sections: DaySection.group(visible, places: places))
            }

            // Album counts mean opening every album, so they are only redone
            // when the set of RAWs or the albums themselves have changed.
            if refreshAlbums || rawIDs != previousRawIDs {
                await self?.refreshAlbums()
            }
        }
    }

    private func publish(rawResult: PHFetchResult<PHAsset>, rawIDs: Set<String>, all: [RawPhoto],
                         favourites: Set<String>, photos: [RawPhoto], sections: [DaySection],
                         position: [String: Int]) {
        self.rawResult = rawResult
        self.rawIDs = rawIDs
        self.allPhotos = all
        self.favouriteIDs = favourites
        self.photos = photos
        self.sections = sections
        self.position = position
        generation += 1
        isLoading = false
    }

    private func publish(places: [Date: String], sections: [DaySection]) {
        placeByDay = places
        self.sections = sections
        generation += 1
    }

    private func refreshAlbums() {
        albumTask?.cancel()
        let rawIDs = rawIDs
        albumTask = Task.detached(priority: .utility) { [weak self] in
            let (result, albums) = Self.fetchAlbums(containing: rawIDs)
            if Task.isCancelled { return }
            await self?.publish(albumResult: result, albums: albums)
        }
    }

    private func publish(albumResult: PHFetchResult<PHAssetCollection>, albums: [AlbumRef]) {
        self.albumResult = albumResult
        self.albums = albums
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

    /// Only albums with at least one RAW in them, each with its RAW count.
    /// An album of memes has no business in a RAW app's menu.
    private nonisolated static func fetchAlbums(containing rawIDs: Set<String>)
        -> (PHFetchResult<PHAssetCollection>, [AlbumRef]) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        let imagesOnly = PHFetchOptions()
        imagesOnly.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        var list: [AlbumRef] = []
        result.enumerateObjects { collection, _, stop in
            if Task.isCancelled { stop.pointee = true; return }
            guard let title = collection.localizedTitle, collection.estimatedAssetCount != 0 else { return }
            var count = 0
            PHAsset.fetchAssets(in: collection, options: imagesOnly).enumerateObjects { asset, _, _ in
                if rawIDs.contains(asset.localIdentifier) { count += 1 }
            }
            if count > 0 {
                list.append(AlbumRef(id: collection.localIdentifier, title: title, collection: collection, rawCount: count))
            }
        }
        return (result, list)
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
        guard let resolved else { return }
        info[id] = resolved
        if !resolved.format.isEmpty, !formats.contains(resolved.format) { formats.insert(resolved.format) }
    }

    private func addFormats(_ found: Set<String>) {
        guard !found.isSubset(of: formats) else { return }
        formats.formUnion(found)
    }

    // MARK: PHPhotoLibraryChangeObserver

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            guard let current = rawResult else { return }
            let rawChanged = changeInstance.changeDetails(for: current) != nil
            let albumsChanged = albumResult.map { changeInstance.changeDetails(for: $0) != nil } ?? false
            guard rawChanged || albumsChanged || album != nil else { return }
            reload(albums: albumsChanged)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

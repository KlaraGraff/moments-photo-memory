import AppKit
import CoreLocation
import Foundation
import MomentsCore
@preconcurrency import Photos

public final class PhotoKitAssetSource: NSObject, PhotosAssetSource, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let imageManager = PHCachingImageManager()
    private var changeHandlers: [UUID: @Sendable (PhotosChangeEvent) -> Void] = [:]
    private var observedFetchResult: PHFetchResult<PHAsset>?
    private var assetCache: [String: PHAsset] = [:]
    private let lock = NSLock()

    public override init() {
        super.init()
    }

    public var authorizationStatus: PhotosAuthorizationStatus {
        Self.mapAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAuthorization() async -> PhotosAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: Self.mapAuthorization(status))
            }
        }
    }

    public func fetchAlbums() async throws -> [PhotosAlbumDescriptor] {
        var albums: [PhotosAlbumDescriptor] = []
        let sources: [(PHAssetCollectionType, PHAssetCollectionSubtype)] = [
            (.album, .albumRegular),
            (.smartAlbum, .smartAlbumUserLibrary)
        ]
        for (type, subtype) in sources {
            let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: subtype, options: nil)
            collections.enumerateObjects { collection, _, _ in
                guard let title = collection.localizedTitle, !title.isEmpty else { return }
                albums.append(PhotosAlbumDescriptor(localIdentifier: collection.localIdentifier, title: title))
            }
        }
        return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func fetchAssets(selection: PhotosImportSelection) async throws -> [PhotosAssetDescriptor] {
        let assets: [PHAsset]
        switch selection {
        case .all:
            assets = Self.collect(PHAsset.fetchAssets(with: nil as PHFetchOptions?))
        case .identifiers(let identifiers):
            assets = Self.collect(PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil))
        case .dateRange(let start, let end):
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@", start as NSDate, end as NSDate)
            assets = Self.collect(PHAsset.fetchAssets(with: options))
        case .albums(let identifiers):
            var seen = Set<String>()
            var values: [PHAsset] = []
            let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: identifiers, options: nil)
            collections.enumerateObjects { collection, _, _ in
                let result = PHAsset.fetchAssets(in: collection, options: nil)
                result.enumerateObjects { asset, _, _ in
                    if seen.insert(asset.localIdentifier).inserted { values.append(asset) }
                }
            }
            assets = values
        }

        lock.lock()
        assetCache = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        lock.unlock()
        let cloudIdentifiers = Self.cloudIdentifiers(for: assets.map(\.localIdentifier))
        return assets.map { asset in
            let albumIdentifiers: [String]
            if case .albums(let selected) = selection {
                albumIdentifiers = selected
            } else {
                albumIdentifiers = []
            }
            return Self.descriptor(
                asset,
                cloudIdentifier: cloudIdentifiers[asset.localIdentifier],
                albumIdentifiers: albumIdentifiers
            )
        }
    }

    public func filterLocalIdentifiers(_ identifiers: [String], in selection: PhotosImportSelection) async throws -> [String] {
        guard !identifiers.isEmpty else { return [] }
        let wanted = Set(identifiers)
        let assets: [PHAsset]
        switch selection {
        case .all:
            assets = Self.collect(PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil))
        case .identifiers(let selected):
            let selectedIDs = wanted.intersection(Set(selected))
            assets = Self.collect(PHAsset.fetchAssets(withLocalIdentifiers: Array(selectedIDs), options: nil))
        case .dateRange(let start, let end):
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "localIdentifier IN %@ AND creationDate >= %@ AND creationDate <= %@",
                identifiers,
                start as NSDate,
                end as NSDate
            )
            assets = Self.collect(PHAsset.fetchAssets(with: options))
        case .albums(let albumIdentifiers):
            var values: [PHAsset] = []
            var seen = Set<String>()
            let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albumIdentifiers, options: nil)
            collections.enumerateObjects { collection, _, _ in
                let options = PHFetchOptions()
                options.predicate = NSPredicate(format: "localIdentifier IN %@", identifiers)
                let result = PHAsset.fetchAssets(in: collection, options: options)
                result.enumerateObjects { asset, _, _ in
                    if wanted.contains(asset.localIdentifier), seen.insert(asset.localIdentifier).inserted {
                        values.append(asset)
                    }
                }
            }
            assets = values
        }
        lock.lock()
        for asset in assets { assetCache[asset.localIdentifier] = asset }
        lock.unlock()
        let found = Set(assets.map(\.localIdentifier))
        return identifiers.filter(found.contains)
    }

    public func observeChanges(_ handler: @escaping @Sendable (PhotosChangeEvent) -> Void) -> any PhotosChangeObservation {
        let token = PhotoKitChangeObservation(source: self, handler: handler)
        lock.lock()
        changeHandlers[token.id] = handler
        if observedFetchResult == nil {
            observedFetchResult = PHAsset.fetchAssets(with: nil as PHFetchOptions?)
        }
        lock.unlock()
        PHPhotoLibrary.shared().register(self)
        return token
    }

    public func thumbnailData(
        forLocalIdentifier localIdentifier: String,
        targetSize: CGSize,
        networkAccessAllowed: Bool
    ) async throws -> Data? {
        guard let asset = cachedAsset(for: localIdentifier)
            ?? PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = networkAccessAllowed
            let size = CGSize(width: max(1, targetSize.width), height: max(1, targetSize.height))
            imageManager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else {
                    let data = image?.tiffRepresentation.flatMap {
                        NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
                    }
                    continuation.resume(returning: data)
                }
            }
        }
    }

    public func thumbnailImage(
        forLocalIdentifier localIdentifier: String,
        targetSize: CGSize,
        networkAccessAllowed: Bool
    ) async -> CGImage? {
        guard let asset = cachedAsset(for: localIdentifier)
            ?? PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else { return nil }
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            // People scanning needs the final, non-degraded pixels. The
            // callback can arrive more than once; the continuation below
            // resumes only for the final result.
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = networkAccessAllowed
            options.isSynchronous = false
            let size = CGSize(width: max(1, targetSize.width), height: max(1, targetSize.height))
            let lock = NSLock()
            var resumed = false
            imageManager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) == true
                let hasError = info?[PHImageErrorKey] != nil
                let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
                // Ignore preview callbacks and resume only for the final
                // high-quality image (or a terminal error/cancellation).
                guard !isDegraded || isCancelled || hasError || isInCloud else { return }

                lock.lock()
                guard !resumed else {
                    lock.unlock()
                    return
                }
                resumed = true
                lock.unlock()

                guard !isCancelled, !hasError, let image else {
                    continuation.resume(returning: nil)
                    return
                }
                var proposedRect = CGRect(origin: .zero, size: image.size)
                continuation.resume(returning: image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil))
            }
        }
    }

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        lock.lock()
        let handlers = Array(changeHandlers.values)
        let previous = observedFetchResult
        lock.unlock()
        guard let previous, let details = changeInstance.changeDetails(for: previous) else { return }
        let event = PhotosChangeEvent(
            insertedLocalIdentifiers: details.insertedObjects.map(\.localIdentifier),
            changedLocalIdentifiers: details.changedObjects.map(\.localIdentifier),
            deletedLocalIdentifiers: details.removedObjects.map(\.localIdentifier)
        )
        lock.lock()
        observedFetchResult = details.fetchResultAfterChanges
        lock.unlock()
        for handler in handlers {
            handler(event)
        }
    }

    fileprivate func removeHandler(_ id: UUID) {
        lock.lock()
        changeHandlers.removeValue(forKey: id)
        let isEmpty = changeHandlers.isEmpty
        if isEmpty { observedFetchResult = nil }
        lock.unlock()
        if isEmpty { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    private static func collect(_ result: PHFetchResult<PHAsset>) -> [PHAsset] {
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    private func cachedAsset(for localIdentifier: String) -> PHAsset? {
        lock.lock()
        defer { lock.unlock() }
        return assetCache[localIdentifier]
    }

    private static func descriptor(
        _ asset: PHAsset,
        cloudIdentifier: String?,
        albumIdentifiers: [String]
    ) -> PhotosAssetDescriptor {
        var subtypes: PhotosMediaSubtypes = []
        if asset.mediaSubtypes.contains(.photoLive) { subtypes.insert(.live) }
        if asset.mediaSubtypes.contains(.photoScreenshot) { subtypes.insert(.screenshot) }
        if asset.burstIdentifier != nil { subtypes.insert(.burst) }
        let type: PhotosMediaType
        switch asset.mediaType {
        case .image: type = .image
        case .video: type = .video
        default: type = .unknown
        }
        let location = asset.location.map { GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        return PhotosAssetDescriptor(
            localIdentifier: asset.localIdentifier,
            cloudIdentifier: cloudIdentifier,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            location: location,
            mediaType: type,
            mediaSubtypes: subtypes,
            duration: type == .video ? asset.duration : nil,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isFavorite: asset.isFavorite,
            albumIdentifiers: albumIdentifiers
        )
    }

    private static func cloudIdentifiers(for localIdentifiers: [String]) -> [String: String] {
        guard !localIdentifiers.isEmpty else { return [:] }
        let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: localIdentifiers)
        return mappings.reduce(into: [:]) { result, entry in
            if case .success(let identifier) = entry.value {
                result[entry.key] = identifier.stringValue
            }
        }
    }

    private static func mapAuthorization(_ status: PHAuthorizationStatus) -> PhotosAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .limited: return .limited
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }
}

private final class PhotoKitChangeObservation: PhotosChangeObservation {
    let id = UUID()
    weak var source: PhotoKitAssetSource?
    let handler: @Sendable (PhotosChangeEvent) -> Void

    init(source: PhotoKitAssetSource, handler: @escaping @Sendable (PhotosChangeEvent) -> Void) {
        self.source = source
        self.handler = handler
    }

    func invalidate() {
        source?.removeHandler(id)
    }
}

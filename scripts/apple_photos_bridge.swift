// Read-only PhotoKit foundation. No Photos access occurs in --self-test.
// Native host integration still requires NSPhotoLibraryUsageDescription, a signed
// app bundle, and user permission. An unbundled CLI is not a shipping TCC host.
import Foundation
@preconcurrency import Photos
import AppKit
import CryptoKit

struct LibraryStatus: Encodable, Sendable {
    let permission: String
    let canRead: Bool
    let cloudSync: String = "unknown" // PhotoKit does not expose iCloud sync settings.
}
struct Geo: Codable, Sendable { let latitude: Double; let longitude: Double; let accuracy: Double }
struct ImportedAsset: Codable, Sendable {
    let id: String
    let localIdentifier: String
    let date: String?
    let dateBasis: String
    let captureLocalDate: String?
    let creationDate: String?
    let modificationDate: String?
    let originalTimeZone: String? // PhotoKit creationDate alone cannot recover this.
    let favorite: Bool
    let width: Int
    let height: Int
    let location: Geo?
    let duration: Double
    let mediaType: String
    let cloudStatus: String
}
struct Album: Codable, Sendable { let localIdentifier: String; let title: String?; let estimatedCount: Int? }
struct Manifest: Encodable, Sendable {
    let schemaVersion = 1
    let source = "apple-photos"
    var sessionIdentifier: String? = nil
    let assets: [ImportedAsset]
    let offset: Int
    let nextOffset: Int?
    let total: Int
}
struct Query: Sendable, Equatable {
    var offset = 0
    var limit = 100
    var from: Date? = nil
    var until: Date? = nil // Exclusive bound.
    var albumIdentifier: String? = nil
    func validate() throws {
        guard offset >= 0, (1...500).contains(limit), from == nil || until == nil || from! < until! else { throw BridgeError.invalidQuery }
    }
}
enum BridgeError: Error { case invalidQuery, permissionRequired, missingAsset, invalidArguments, noSession, sessionExpired, queryChanged, crossProcessPaginationUnsupported }
func stableID(_ identifier: String) -> String {
    "APL" + SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
}
func timestamp(_ date: Date?) -> String? {
    date.map { value in
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }
}
func page(_ assets: [ImportedAsset], query: Query) throws -> Manifest {
    try query.validate()
    let start = min(query.offset, assets.count), end = min(start + query.limit, assets.count)
    return Manifest(assets: Array(assets[start..<end]), offset: query.offset, nextOffset: end < assets.count ? end : nil, total: assets.count)
}


// Value snapshot: later library insertion/deletion cannot alter page membership.
// Query changes invalidate the active context rather than silently refetching.
struct ImportSession {
    private var records: [ImportedAsset] = []
    private var identifier: String? = nil
    private var query: Query? = nil
    private var expiresAt = Date.distantPast
    mutating func begin(_ assets: [ImportedAsset], query: Query, now: Date = Date(), lifetime: TimeInterval = 3600) throws -> String {
        end()
        try query.validate()
        guard query.offset == 0, lifetime > 0 else { throw BridgeError.invalidQuery }
        records = assets.sorted {
            if $0.creationDate != $1.creationDate { return ($0.creationDate ?? "") < ($1.creationDate ?? "") }
            return $0.localIdentifier < $1.localIdentifier
        }
        self.query = query
        let token = UUID().uuidString
        identifier = token; expiresAt = now.addingTimeInterval(lifetime)
        return token
    }
    mutating func fetch(identifier: String, query: Query, now: Date = Date()) throws -> Manifest {
        guard let current = self.identifier, current == identifier else { throw BridgeError.noSession }
        guard now < expiresAt else { end(); throw BridgeError.sessionExpired }
        try query.validate()
        var normalized = query; normalized.offset = 0
        guard normalized == self.query else { end(); throw BridgeError.queryChanged }
        var result = try page(records, query: query)
        result.sessionIdentifier = current
        return result
    }
    mutating func contains(_ assetIdentifier: String, now: Date = Date()) -> Bool {
        guard identifier != nil, now < expiresAt else { end(); return false }
        return records.contains { $0.localIdentifier == assetIdentifier }
    }
    mutating func end() { records.removeAll(); identifier = nil; query = nil; expiresAt = .distantPast }
}

@MainActor final class ApplePhotosBridge {
    private let manager = PHImageManager.default()
    private var requests: [UUID: PHImageRequestID] = [:]
    private var session = ImportSession()
    // Safe status inspection: never requests permission.
    func status() -> LibraryStatus {
        let value = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let label: String
        switch value { case .authorized: label = "authorized"; case .limited: label = "limited"; case .denied: label = "denied"; case .restricted: label = "restricted"; case .notDetermined: label = "notdetermined"; @unknown default: label = "unknown" }
        return LibraryStatus(permission: label, canRead: value == .authorized || value == .limited)
    }
    // The native host must call this only after an explicit user action.
    func requestAuthorization() async -> LibraryStatus {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status()
    }
    private func requireRead() throws { guard status().canRead else { throw BridgeError.permissionRequired } }
    func albums() throws -> [Album] {
        try requireRead()
        var result: [Album] = []
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            collections.enumerateObjects { collection, _, _ in
                result.append(Album(localIdentifier: collection.localIdentifier, title: collection.localizedTitle, estimatedCount: collection.estimatedAssetCount == NSNotFound ? nil : collection.estimatedAssetCount))
            }
        }
        return result
    }
    func beginImport(_ query: Query) throws -> String {
        session.end()
        try query.validate(); try requireRead()
        guard query.offset == 0 else { throw BridgeError.invalidQuery }
        let options = PHFetchOptions()
        var predicates = [NSPredicate(format: "(mediaType == %d OR mediaType == %d)", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue), NSPredicate(format: "(mediaSubtypes & %d) == 0", PHAssetMediaSubtype.photoScreenshot.rawValue)]
        if let from = query.from { predicates.append(NSPredicate(format: "creationDate >= %@", from as NSDate)) }
        if let until = query.until { predicates.append(NSPredicate(format: "creationDate < %@", until as NSDate)) }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetched: PHFetchResult<PHAsset>
        if let identifier = query.albumIdentifier {
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject else { throw BridgeError.missingAsset }
            fetched = PHAsset.fetchAssets(in: album, options: options)
        } else { fetched = PHAsset.fetchAssets(with: options) }
        let records = (0..<fetched.count).map { index -> ImportedAsset in
            let asset = fetched.object(at: index)
            let created = timestamp(asset.creationDate)
            return ImportedAsset(id: stableID(asset.localIdentifier), localIdentifier: asset.localIdentifier, date: created.map { String($0.prefix(10)) }, dateBasis: "utc-derived", captureLocalDate: nil, creationDate: created, modificationDate: timestamp(asset.modificationDate), originalTimeZone: nil, favorite: asset.isFavorite, width: asset.pixelWidth, height: asset.pixelHeight, location: asset.location.map { Geo(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, accuracy: $0.horizontalAccuracy) }, duration: asset.duration, mediaType: asset.mediaType == .video ? "video" : "image", cloudStatus: "unknown")
        }
        return try session.begin(records, query: query)
    }
    func assets(sessionIdentifier: String, query: Query) throws -> Manifest {
        do { try requireRead() } catch { session.end(); throw error }
        return try session.fetch(identifier: sessionIdentifier, query: query)
    }
    func endImport() { session.end() }
    func selected(_ identifier: String) -> Bool { session.contains(identifier) }
    // JPEG data stays in memory. The host owns private storage and explicit consent.
    // Only a selected asset may opt into an iCloud download; default is local only.
    @discardableResult func preview(identifier: String, allowNetwork: Bool = false,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
        completion: @escaping @MainActor @Sendable (Data?, String) -> Void) throws -> PHImageRequestID {
        try requireRead()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { throw BridgeError.missingAsset }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        let token = UUID()
        options.progressHandler = { value, _, _, _ in Task { @MainActor in
            guard self.requests[token] != nil else { return }; progress(value)
        } }
        let request = manager.requestImage(for: asset, targetSize: CGSize(width: 640, height: 640), contentMode: .aspectFit, options: options) { image, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            let cloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
            let failed = info?[PHImageErrorKey] != nil
            // Re-render bounds explicitly: PhotoKit may supply a larger image.
            var jpeg: Data?
            if let image, image.size.width > 0, image.size.height > 0, !cancelled {
                let scale = min(1, 640 / max(image.size.width, image.size.height))
                let size = NSSize(width: max(1, floor(image.size.width * scale)), height: max(1, floor(image.size.height * scale)))
                if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                    image.draw(in: NSRect(origin: .zero, size: size))
                    NSGraphicsContext.restoreGraphicsState()
                    jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
                }
            }
            let result = jpeg
            Task { @MainActor in
                guard self.requests.removeValue(forKey: token) != nil else { return }
                completion(result, cancelled ? "cancelled" : failed ? "error" : cloud && result == nil ? "requires-download" : result == nil ? "unavailable" : "available") }
        }
        requests[token] = request
        return request
    }
    func cancel(_ request: PHImageRequestID) {
        manager.cancelImageRequest(request)
        for token in requests.filter({ $0.value == request }).keys { requests.removeValue(forKey: token) }
    }
    func cancelAll() { for request in requests.values { manager.cancelImageRequest(request) }; requests.removeAll() }
}

#if !MOMENTS_HOST
@main struct BridgeCLI {
    @MainActor static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let data: Data
            if args == ["--self-test"] {
                // Synthetic path deliberately does not instantiate ApplePhotosBridge.
                let asset = ImportedAsset(id: stableID("synthetic-only"), localIdentifier: "synthetic-only", date: "2026-01-01", dateBasis: "utc-derived", captureLocalDate: nil, creationDate: "2026-01-01T00:00:00Z", modificationDate: nil, originalTimeZone: nil, favorite: false, width: 100, height: 80, location: nil, duration: 0, mediaType: "image", cloudStatus: "unknown")
                precondition(stableID("synthetic-only") == asset.id && stableID("different") != asset.id)
                let first = try page([asset, asset], query: Query(limit: 1))
                precondition(first.nextOffset == 1 && first.total == 2)
                let beyond = try page([asset], query: Query(offset: 9))
                precondition(beyond.assets.isEmpty)
                // UTC instant crosses the calendar boundary of a +02:00 capture.
                let offsetDate = ISO8601DateFormatter().date(from: "2026-01-02T00:30:00+02:00")!
                precondition(timestamp(offsetDate) == "2026-01-01T22:30:00.000Z")
                precondition(asset.dateBasis == "utc-derived" && asset.captureLocalDate == nil)
                do { try Query(limit: 0).validate(); preconditionFailure("invalid limit accepted") } catch BridgeError.invalidQuery {}
                do { try Query(offset: -1).validate(); preconditionFailure("invalid offset accepted") } catch BridgeError.invalidQuery {}
                func synthetic(_ identifier: String) -> ImportedAsset {
                    ImportedAsset(id: stableID(identifier), localIdentifier: identifier, date: asset.date, dateBasis: "utc-derived", captureLocalDate: nil, creationDate: asset.creationDate, modificationDate: nil, originalTimeZone: nil, favorite: false, width: 100, height: 80, location: nil, duration: 0, mediaType: "image", cloudStatus: "unknown")
                }
                var input = [synthetic("c"), synthetic("a"), synthetic("b")]
                var session = ImportSession()
                let now = Date(timeIntervalSince1970: 100)
                let token = try session.begin(input, query: Query(limit: 1), now: now, lifetime: 10)
                input.removeAll { $0.localIdentifier == "b" }; input.insert(synthetic("0"), at: 0)
                var collected: [String] = []
                for offset in 0..<3 {
                    let result = try session.fetch(identifier: token, query: Query(offset: offset, limit: 1), now: now)
                    collected += result.assets.map(\.localIdentifier)
                }
                precondition(collected == ["a", "b", "c"] && Set(collected).count == 3)
                do { _ = try session.fetch(identifier: "invalid", query: Query(limit: 1), now: now); preconditionFailure() } catch BridgeError.noSession {}
                do { _ = try session.fetch(identifier: token, query: Query(limit: 1), now: now.addingTimeInterval(10)); preconditionFailure() } catch BridgeError.sessionExpired {}
                do { _ = try session.fetch(identifier: token, query: Query(limit: 1), now: now); preconditionFailure() } catch BridgeError.noSession {}
                let replacement = try session.begin(input, query: Query(limit: 1), now: now)
                do { _ = try session.fetch(identifier: replacement, query: Query(limit: 2), now: now); preconditionFailure() } catch BridgeError.queryChanged {}
                do { _ = try session.fetch(identifier: replacement, query: Query(limit: 1), now: now); preconditionFailure() } catch BridgeError.noSession {}
                data = try JSONEncoder().encode(first)
            } else if args == ["--status"] { data = try JSONEncoder().encode(ApplePhotosBridge().status()) }
            else if args == ["--request-authorization"] { data = try JSONEncoder().encode(await ApplePhotosBridge().requestAuthorization()) }
            else if args == ["--albums"] { data = try JSONEncoder().encode(try ApplePhotosBridge().albums()) }
            else if args.first == "--fetch", args.count == 3, let offset = Int(args[1]), let limit = Int(args[2]) {
                // Sessions are process-local. This CLI can inspect only the first page;
                // a native host must retain the bridge for subsequent pages.
                guard offset == 0 else { throw BridgeError.crossProcessPaginationUnsupported }
                let bridge = ApplePhotosBridge(), query = Query(offset: 0, limit: limit)
                let token = try bridge.beginImport(query)
                data = try JSONEncoder().encode(try bridge.assets(sessionIdentifier: token, query: query))
                bridge.endImport()
            }
            else { throw BridgeError.invalidArguments }
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
        } catch { FileHandle.standardError.write(Data("Bridge error: \(error)\n".utf8)); exit(1) }
    }
}

#endif

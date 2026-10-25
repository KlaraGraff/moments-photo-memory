import CoreGraphics
import Foundation
import MomentsCore

public enum PhotosAuthorizationStatus: String, Codable, Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case limited
    case authorized

    public var canRead: Bool {
        self == .authorized || self == .limited
    }
}

public enum PhotosMediaType: String, Codable, Equatable, Sendable {
    case image
    case video
    case unknown
}

public struct PhotosMediaSubtypes: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let live = Self(rawValue: 1 << 0)
    public static let screenshot = Self(rawValue: 1 << 1)
    public static let burst = Self(rawValue: 1 << 2)
}

public enum PhotosImportSelection: Equatable, Sendable {
    case all
    case albums([String])
    case dateRange(start: Date, end: Date)
    case identifiers([String])
}

public struct PhotosAlbumDescriptor: Identifiable, Equatable, Sendable {
    public let localIdentifier: String
    public let title: String

    public var id: String { localIdentifier }

    public init(localIdentifier: String, title: String) {
        self.localIdentifier = localIdentifier
        self.title = title
    }
}

public struct PhotosAssetDescriptor: Identifiable, Equatable, Sendable {
    public let localIdentifier: String
    public let cloudIdentifier: String?
    public let creationDate: Date?
    public let modificationDate: Date?
    public let location: GeoPoint?
    public let mediaType: PhotosMediaType
    public let mediaSubtypes: PhotosMediaSubtypes
    public let duration: Double?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isFavorite: Bool
    public let albumIdentifiers: [String]

    public var id: String { localIdentifier }

    public init(
        localIdentifier: String,
        cloudIdentifier: String? = nil,
        creationDate: Date?,
        modificationDate: Date? = nil,
        location: GeoPoint? = nil,
        mediaType: PhotosMediaType,
        mediaSubtypes: PhotosMediaSubtypes = [],
        duration: Double? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        isFavorite: Bool = false,
        albumIdentifiers: [String] = []
    ) {
        self.localIdentifier = localIdentifier
        self.cloudIdentifier = cloudIdentifier
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.location = location
        self.mediaType = mediaType
        self.mediaSubtypes = mediaSubtypes
        self.duration = duration
        self.pixelWidth = max(0, pixelWidth)
        self.pixelHeight = max(0, pixelHeight)
        self.isFavorite = isFavorite
        self.albumIdentifiers = albumIdentifiers
    }
}

public struct PhotosChangeEvent: Equatable, Sendable {
    public let insertedLocalIdentifiers: [String]
    public let changedLocalIdentifiers: [String]
    public let deletedLocalIdentifiers: [String]

    public init(
        insertedLocalIdentifiers: [String] = [],
        changedLocalIdentifiers: [String] = [],
        deletedLocalIdentifiers: [String] = []
    ) {
        self.insertedLocalIdentifiers = insertedLocalIdentifiers
        self.changedLocalIdentifiers = changedLocalIdentifiers
        self.deletedLocalIdentifiers = deletedLocalIdentifiers
    }

    public var newAssetCount: Int { insertedLocalIdentifiers.count }
}

public protocol PhotosChangeObservation: AnyObject {
    func invalidate()
}

public protocol PhotosAssetSource: AnyObject {
    var authorizationStatus: PhotosAuthorizationStatus { get }

    func requestAuthorization() async -> PhotosAuthorizationStatus
    func fetchAlbums() async throws -> [PhotosAlbumDescriptor]
    func fetchAssets(selection: PhotosImportSelection) async throws -> [PhotosAssetDescriptor]
    func filterLocalIdentifiers(_ identifiers: [String], in selection: PhotosImportSelection) async throws -> [String]
    func observeChanges(_ handler: @escaping @Sendable (PhotosChangeEvent) -> Void) -> any PhotosChangeObservation
    func thumbnailData(
        forLocalIdentifier localIdentifier: String,
        targetSize: CGSize,
        networkAccessAllowed: Bool
    ) async throws -> Data?
    func thumbnailImage(
        forLocalIdentifier localIdentifier: String,
        targetSize: CGSize,
        networkAccessAllowed: Bool
    ) async -> CGImage?
}

public extension PhotosAssetSource {
    func fetchAlbums() async throws -> [PhotosAlbumDescriptor] { [] }
    func filterLocalIdentifiers(_ identifiers: [String], in selection: PhotosImportSelection) async throws -> [String] {
        guard !identifiers.isEmpty else { return [] }
        let candidates = try await fetchAssets(selection: .identifiers(identifiers))
        let matches: Set<String>
        switch selection {
        case .all:
            matches = Set(candidates.map(\.localIdentifier))
        case .identifiers(let selected):
            matches = Set(candidates.map(\.localIdentifier)).intersection(Set(selected))
        case .dateRange(let start, let end):
            matches = Set(candidates.compactMap { asset in
                guard let date = asset.creationDate, date >= start, date <= end else { return nil }
                return asset.localIdentifier
            })
        case .albums(let selected):
            let selectedAlbums = Set(selected)
            matches = Set(candidates.filter { !$0.albumIdentifiers.filter(selectedAlbums.contains).isEmpty }.map(\.localIdentifier))
        }
        return identifiers.filter(matches.contains)
    }
    func thumbnailImage(
        forLocalIdentifier localIdentifier: String,
        targetSize: CGSize,
        networkAccessAllowed: Bool
    ) async -> CGImage? { nil }
}

public struct PhotosMappedAsset: Equatable, Sendable {
    public let asset: PhotosAssetDescriptor
    public let metadata: ImportedMediaMetadata
    public let isScreenshot: Bool
    public let isFavorite: Bool
    public let perceptualHash: String?

    public init(
        asset: PhotosAssetDescriptor,
        metadata: ImportedMediaMetadata,
        isScreenshot: Bool,
        isFavorite: Bool,
        perceptualHash: String? = nil
    ) {
        self.asset = asset
        self.metadata = metadata
        self.isScreenshot = isScreenshot
        self.isFavorite = isFavorite
        self.perceptualHash = perceptualHash
    }
}

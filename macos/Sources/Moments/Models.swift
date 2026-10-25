import Foundation
import SwiftData

public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case photo
    case video
    case live
}

public enum MediaSource: String, Codable, CaseIterable, Sendable {
    case demo
    case file
    case photos
}

public enum MemoryAuthor: String, Codable, CaseIterable, Sendable {
    case me
    case partner
}

public enum PlaceKind: String, Codable, CaseIterable, Sendable {
    case spot
    case area
    case city
}

@Model
public final class MediaItem {
    @Attribute(.unique) public var id: String
    public var captureDate: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var kindRaw: String
    public var width: Int
    public var height: Int
    public var isFavorite: Bool
    public var isScreenshot: Bool
    public var sourceRaw: String
    public var title: String
    public var tripKey: String?

    @Relationship(deleteRule: .cascade, inverse: \Memory.mediaItem)
    public var memories: [Memory] = []
    @Relationship(inverse: \Tag.items)
    public var tags: [Tag] = []

    public init(
        id: String = UUID().uuidString,
        captureDate: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        kind: MediaKind = .photo,
        width: Int = 0,
        height: Int = 0,
        isFavorite: Bool = false,
        isScreenshot: Bool = false,
        source: MediaSource = .file,
        title: String = "",
        tripKey: String? = nil
    ) {
        self.id = id
        self.captureDate = captureDate
        self.latitude = latitude
        self.longitude = longitude
        self.kindRaw = kind.rawValue
        self.width = width
        self.height = height
        self.isFavorite = isFavorite
        self.isScreenshot = isScreenshot
        self.sourceRaw = source.rawValue
        self.title = title
        self.tripKey = tripKey
    }

    public var kind: MediaKind {
        get { MediaKind(rawValue: kindRaw) ?? .photo }
        set { kindRaw = newValue.rawValue }
    }

    public var source: MediaSource {
        get { MediaSource(rawValue: sourceRaw) ?? .file }
        set { sourceRaw = newValue.rawValue }
    }
}

@Model
public final class Memory {
    public var text: String
    public var authorRaw: String
    public var createdAt: Date
    public var updatedAt: Date
    public var mediaItem: MediaItem?

    public init(
        text: String,
        author: MemoryAuthor = .me,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        mediaItem: MediaItem? = nil
    ) {
        self.text = text
        self.authorRaw = author.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.mediaItem = mediaItem
    }

    public var author: MemoryAuthor {
        get { MemoryAuthor(rawValue: authorRaw) ?? .me }
        set { authorRaw = newValue.rawValue }
    }
}

@Model
public final class Place {
    @Attribute(.unique) public var id: String
    public var name: String
    public var kindRaw: String
    public var latitude: Double?
    public var longitude: Double?
    public var mapLink: String?
    public var parent: Place?
    @Relationship(inverse: \Place.parent)
    public var children: [Place] = []

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: PlaceKind = .spot,
        latitude: Double? = nil,
        longitude: Double? = nil,
        mapLink: String? = nil,
        parent: Place? = nil
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.latitude = latitude
        self.longitude = longitude
        self.mapLink = mapLink
        self.parent = parent
    }

    public var kind: PlaceKind {
        get { PlaceKind(rawValue: kindRaw) ?? .spot }
        set { kindRaw = newValue.rawValue }
    }
}

@Model
public final class Trip {
    @Attribute(.unique) public var id: String
    public var name: String
    public var startDate: Date?
    public var endDate: Date?
    @Relationship public var items: [MediaItem] = []

    public init(
        id: String = UUID().uuidString,
        name: String,
        startDate: Date? = nil,
        endDate: Date? = nil,
        items: [MediaItem] = []
    ) {
        self.id = id
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.items = items
    }

    /// SwiftData does not persist to-many order, so trips are ordered by capture date.
    public var orderedItems: [MediaItem] {
        items.sorted { ($0.captureDate ?? .distantPast, $0.id) < ($1.captureDate ?? .distantPast, $1.id) }
    }
}

@Model
public final class Tag {
    @Attribute(.unique) public var name: String
    public var items: [MediaItem] = []

    public init(name: String) {
        self.name = name
    }
}

enum MomentsSchema {
    static let models: [any PersistentModel.Type] = [MediaItem.self, Memory.self, Place.self, Trip.self, Tag.self]
}

public enum MomentsPersistence {
    public static func makeContainer(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else if let url {
            configuration = ModelConfiguration(url: url)
        } else {
            configuration = ModelConfiguration(url: try defaultStoreURL())
        }
        return try ModelContainer(for: Schema(MomentsSchema.models), configurations: configuration)
    }

    /// `~/Library/Application Support/Moments/Moments.store`, never a shared `default.store`.
    public static func defaultStoreURL() throws -> URL {
        let folder = URL.applicationSupportDirectory.appending(path: "Moments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "Moments.store")
    }
}

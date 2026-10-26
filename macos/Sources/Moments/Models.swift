import Foundation
import SQLite3
import SwiftData

public enum MediaKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
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

public enum PlaceKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case spot
    case area
    case city
}

public enum MomentsAccount {
    /// A local-only binding used until CloudKit account identities are wired in.
    public static let localID = "local-me"
}

/// The model that shipped before the sharing-ready schema.
///
/// These types intentionally retain the old fields so a v1 store can be
/// inspected without opening it through the v2 model. The old store's
/// uniqueness is enforced by the v1 application code; v2 never relies on a
/// model-level uniqueness constraint.
public enum SchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static let models: [any PersistentModel.Type] = [
        MediaItem.self, Memory.self, Place.self, Trip.self, Tag.self
    ]

    @Model
    public final class MediaItem {
        public var id: String
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
        @Relationship(inverse: \Place.items)
        public var place: Place?
        public var placeOverrideName: String?
        public var placeOverrideMapLink: String?
        public var placeOverrideLatitude: Double?
        public var placeOverrideLongitude: Double?
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
            tripKey: String? = nil,
            place: Place? = nil,
            placeOverrideName: String? = nil,
            placeOverrideMapLink: String? = nil,
            placeOverrideLatitude: Double? = nil,
            placeOverrideLongitude: Double? = nil
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
            self.place = place
            self.placeOverrideName = placeOverrideName
            self.placeOverrideMapLink = placeOverrideMapLink
            self.placeOverrideLatitude = placeOverrideLatitude
            self.placeOverrideLongitude = placeOverrideLongitude
        }

        public var kind: MediaKind {
            get { MediaKind(rawValue: kindRaw) ?? .photo }
            set { kindRaw = newValue.rawValue }
        }

        public var source: MediaSource {
            get { MediaSource(rawValue: sourceRaw) ?? .file }
            set { sourceRaw = newValue.rawValue }
        }

        public var effectivePlaceName: String? {
            let override = placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return override?.isEmpty == false ? override : place?.name
        }

        public var effectiveMapLink: String? {
            let override = placeOverrideMapLink?.trimmingCharacters(in: .whitespacesAndNewlines)
            return override?.isEmpty == false ? override : place?.mapLink
        }

        public var effectiveCoordinate: (latitude: Double, longitude: Double)? {
            if let latitude = placeOverrideLatitude, let longitude = placeOverrideLongitude {
                return (latitude, longitude)
            }
            if let latitude = place?.latitude, let longitude = place?.longitude {
                return (latitude, longitude)
            }
            if let latitude, let longitude {
                return (latitude, longitude)
            }
            return nil
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
        public var id: String
        public var name: String
        public var kindRaw: String
        public var latitude: Double?
        public var longitude: Double?
        public var mapLink: String?
        public var parent: Place?
        public var items: [MediaItem] = []
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
        public var id: String
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

        public var orderedItems: [MediaItem] {
            items.sorted { ($0.captureDate ?? .distantPast, $0.id) < ($1.captureDate ?? .distantPast, $1.id) }
        }
    }

    @Model
    public final class Tag {
        public var name: String
        public var items: [MediaItem] = []

        public init(name: String) {
            self.name = name
        }
    }
}

/// The sharing-ready local cache schema.
public enum SchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)
    public static let models: [any PersistentModel.Type] = [
        SchemaV2.MediaItem.self,
        SchemaV2.Memory.self,
        SchemaV2.MemoryRevision.self,
        SchemaV2.Place.self,
        SchemaV2.PlaceOverride.self,
        SchemaV2.Trip.self,
        SchemaV2.Tag.self,
        SchemaV2.MediaTag.self,
        SchemaV2.Favorite.self
    ]

    @Model
    public final class MediaItem {
        public var id: String
        public var captureDate: Date?
        public var latitude: Double?
        public var longitude: Double?
        public var kindRaw: String
        public var width: Int
        public var height: Int
        public var isScreenshot: Bool
        public var sourceRaw: String
        public var title: String
        public var tripID: String?
        public var updatedAt: Date
        public var updatedBy: String?

        @Relationship(inverse: \Place.items)
        public var place: Place?
        @Relationship(inverse: \Trip.items)
        public var trip: Trip?
        @Relationship(deleteRule: .cascade, inverse: \Memory.mediaItem)
        public var memories: [Memory] = []
        @Relationship(inverse: \MediaTag.mediaItem)
        public var mediaTags: [MediaTag] = []
        @Relationship(inverse: \Favorite.mediaItem)
        public var favorites: [Favorite] = []
        @Relationship(inverse: \PlaceOverride.mediaItem)
        public var placeOverrides: [PlaceOverride] = []

        public init(
            id: String = UUID().uuidString,
            captureDate: Date? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil,
            kind: MediaKind = .photo,
            width: Int = 0,
            height: Int = 0,
            isScreenshot: Bool = false,
            source: MediaSource = .file,
            title: String = "",
            tripID: String? = nil,
            tripKey: String? = nil,
            place: Place? = nil,
            trip: Trip? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil
        ) {
            self.id = id
            self.captureDate = captureDate
            self.latitude = latitude
            self.longitude = longitude
            self.kindRaw = kind.rawValue
            self.width = width
            self.height = height
            self.isScreenshot = isScreenshot
            self.sourceRaw = source.rawValue
            self.title = title
            self.tripID = trip?.id ?? tripID ?? tripKey
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.place = place
            self.trip = trip
        }

        public var kind: MediaKind {
            get { MediaKind(rawValue: kindRaw) ?? .photo }
            set { kindRaw = newValue.rawValue }
        }

        public var source: MediaSource {
            get { MediaSource(rawValue: sourceRaw) ?? .file }
            set { sourceRaw = newValue.rawValue }
        }

        /// Compatibility spelling used by the current Library and Timeline code.
        public var tripKey: String? {
            get { tripID }
            set { tripID = newValue }
        }

        public var tags: [Tag] {
            mediaTags.compactMap(\.tag)
        }

        public var isFavorite: Bool {
            favorites.first(where: { $0.accountID == MomentsAccount.localID })?.isFavorite ?? false
        }

        public var localPlaceOverride: PlaceOverride? {
            placeOverrides.first(where: { $0.accountID == MomentsAccount.localID })
        }

        public var placeOverrideName: String? { localPlaceOverride?.nameOverride }
        public var placeOverrideMapLink: String? { localPlaceOverride?.mapLinkOverride }
        public var placeOverrideLatitude: Double? { localPlaceOverride?.latitude }
        public var placeOverrideLongitude: Double? { localPlaceOverride?.longitude }

        /// The place name shown by the app, preferring this person's override.
        public var effectivePlaceName: String? {
            let override = placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return override?.isEmpty == false ? override : place?.name
        }

        /// The map link shown by the app, preferring this person's override.
        public var effectiveMapLink: String? {
            let override = placeOverrideMapLink?.trimmingCharacters(in: .whitespacesAndNewlines)
            return override?.isEmpty == false ? override : place?.mapLink
        }

        /// The coordinate shown by the app, preferring an override and then the canonical place/GPS.
        public var effectiveCoordinate: (latitude: Double, longitude: Double)? {
            if let latitude = placeOverrideLatitude, let longitude = placeOverrideLongitude {
                return (latitude, longitude)
            }
            if let latitude = place?.latitude, let longitude = place?.longitude {
                return (latitude, longitude)
            }
            if let latitude, let longitude {
                return (latitude, longitude)
            }
            return nil
        }

        public func setFavorite(_ value: Bool, accountID: String = MomentsAccount.localID, context: ModelContext) {
            let existingFavorite: Favorite?
            do {
                existingFavorite = try Favorite.lookup(mediaID: id, accountID: accountID, in: context)
            } catch {
                existingFavorite = nil
            }
            if let favorite = existingFavorite {
                favorite.isFavorite = value
                favorite.changedAt = .now
            } else {
                let favorite = Favorite(mediaID: id, accountID: accountID, isFavorite: value, mediaItem: self)
                context.insert(favorite)
            }
            updatedAt = .now
            updatedBy = accountID
        }

        public func addTag(_ tag: Tag, context: ModelContext) {
            guard !mediaTags.contains(where: { $0.tagID == tag.id }) else { return }
            let join = MediaTag(id: "\(id):\(tag.id)", mediaID: id, tagID: tag.id, mediaItem: self, tag: tag)
            context.insert(join)
        }

        public func removeTag(_ tag: Tag, context: ModelContext) {
            guard let join = mediaTags.first(where: { $0.tagID == tag.id }) else { return }
            context.delete(join)
        }
    }

    @Model
    public final class Memory {
        public var id: String
        public var mediaID: String?
        public var text: String
        public var authorRaw: String
        public var authorAccountID: String?
        public var createdAt: Date
        public var updatedAt: Date
        public var revision: Int
        public var updatedBy: String?
        public var mediaItem: MediaItem?
        @Relationship(deleteRule: .cascade, inverse: \MemoryRevision.memory)
        public var revisions: [MemoryRevision] = []

        public init(
            id: String = UUID().uuidString,
            text: String,
            author: MemoryAuthor = .me,
            authorAccountID: String? = nil,
            createdAt: Date = .now,
            updatedAt: Date = .now,
            revision: Int = 1,
            updatedBy: String? = nil,
            mediaItem: MediaItem? = nil,
            mediaID: String? = nil
        ) {
            self.id = id
            self.mediaID = mediaItem?.id ?? mediaID
            self.text = text
            self.authorRaw = author.rawValue
            self.authorAccountID = authorAccountID
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.revision = revision
            self.updatedBy = updatedBy
            self.mediaItem = mediaItem
        }

        public var author: MemoryAuthor {
            get { MemoryAuthor(rawValue: authorRaw) ?? .me }
            set { authorRaw = newValue.rawValue }
        }
    }

    @Model
    public final class MemoryRevision {
        public var id: String
        public var memoryID: String?
        public var text: String
        public var editedBy: String?
        public var editedAt: Date
        public var baseRevision: Int
        public var reason: String?
        public var memory: Memory?

        public init(
            id: String = UUID().uuidString,
            memoryID: String? = nil,
            text: String,
            editedBy: String? = nil,
            editedAt: Date = .now,
            baseRevision: Int,
            reason: String? = nil,
            memory: Memory? = nil
        ) {
            self.id = id
            self.memoryID = memory?.id ?? memoryID
            self.text = text
            self.editedBy = editedBy
            self.editedAt = editedAt
            self.baseRevision = baseRevision
            self.reason = reason
            self.memory = memory
        }
    }

    @Model
    public final class Place {
        public var id: String
        public var name: String
        public var kindRaw: String
        public var latitude: Double?
        public var longitude: Double?
        public var mapLink: String?
        public var updatedAt: Date
        public var updatedBy: String?
        public var parent: Place?
        @Relationship(inverse: \Place.parent)
        public var children: [Place] = []
        public var items: [MediaItem] = []
        public var overrides: [PlaceOverride] = []

        public init(
            id: String = UUID().uuidString,
            name: String,
            kind: PlaceKind = .spot,
            latitude: Double? = nil,
            longitude: Double? = nil,
            mapLink: String? = nil,
            parent: Place? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil
        ) {
            self.id = id
            self.name = name
            self.kindRaw = kind.rawValue
            self.latitude = latitude
            self.longitude = longitude
            self.mapLink = mapLink
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.parent = parent
        }

        public var kind: PlaceKind {
            get { PlaceKind(rawValue: kindRaw) ?? .spot }
            set { kindRaw = newValue.rawValue }
        }
    }

    @Model
    public final class PlaceOverride {
        public var id: String
        public var placeID: String?
        public var mediaID: String?
        public var accountID: String
        public var nameOverride: String?
        public var mapLinkOverride: String?
        public var latitude: Double?
        public var longitude: Double?
        public var updatedAt: Date
        public var updatedBy: String?
        @Relationship(inverse: \Place.overrides)
        public var place: Place?
        public var mediaItem: MediaItem?

        public init(
            id: String? = nil,
            placeID: String? = nil,
            mediaID: String? = nil,
            accountID: String = MomentsAccount.localID,
            nameOverride: String? = nil,
            mapLinkOverride: String? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            place: Place? = nil,
            mediaItem: MediaItem? = nil
        ) {
            let ownerID = mediaItem?.id ?? mediaID ?? place?.id ?? placeID ?? UUID().uuidString
            self.id = id ?? "\(ownerID):\(accountID)"
            self.placeID = place?.id ?? placeID
            self.mediaID = mediaItem?.id ?? mediaID
            self.accountID = accountID
            self.nameOverride = nameOverride
            self.mapLinkOverride = mapLinkOverride
            self.latitude = latitude
            self.longitude = longitude
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.place = place
            self.mediaItem = mediaItem
        }

        public var coordinate: (latitude: Double, longitude: Double)? {
            guard let latitude, let longitude else { return nil }
            return (latitude, longitude)
        }
    }

    @Model
    public final class Trip {
        public var id: String
        public var name: String
        public var startDate: Date?
        public var endDate: Date?
        public var updatedAt: Date
        public var updatedBy: String?
        public var items: [MediaItem] = []

        public init(
            id: String = UUID().uuidString,
            name: String,
            startDate: Date? = nil,
            endDate: Date? = nil,
            items: [MediaItem] = [],
            updatedAt: Date = .now,
            updatedBy: String? = nil
        ) {
            self.id = id
            self.name = name
            self.startDate = startDate
            self.endDate = endDate
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.items = items
        }

        /// SwiftData does not persist to-many order, so trips are ordered by capture date.
        public var orderedItems: [MediaItem] {
            items.sorted { ($0.captureDate ?? .distantPast, $0.id) < ($1.captureDate ?? .distantPast, $1.id) }
        }
    }

    @Model
    public final class Tag {
        public var id: String
        public var normalizedName: String
        public var displayName: String
        public var updatedAt: Date
        public var updatedBy: String?
        public var mediaTags: [MediaTag] = []

        public init(id: String = UUID().uuidString, displayName: String, normalizedName: String? = nil, updatedAt: Date = .now, updatedBy: String? = nil) {
            self.id = id
            self.displayName = displayName
            self.normalizedName = normalizedName ?? Self.normalize(displayName)
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
        }

        /// Compatibility spelling for the pre-sharing UI.
        public convenience init(name: String) {
            self.init(displayName: name)
        }

        public var name: String {
            get { displayName }
            set {
                displayName = newValue
                normalizedName = Self.normalize(newValue)
                updatedAt = .now
            }
        }

        public var items: [MediaItem] {
            mediaTags.compactMap(\.mediaItem)
        }

        public static func normalize(_ name: String) -> String {
            name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
                .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }

        public static func lookup(normalizedName: String, in context: ModelContext) throws -> Tag? {
            let normalized = normalize(normalizedName)
            return try context.fetch(FetchDescriptor<Tag>())
                .first(where: { $0.normalizedName == normalized })
        }

        public static func lookupOrCreate(displayName: String, in context: ModelContext) throws -> Tag {
            if let existing = try lookup(normalizedName: displayName, in: context) {
                return existing
            }
            let tag = Tag(displayName: displayName)
            context.insert(tag)
            return tag
        }

        public static func findOrCreate(name: String, in context: ModelContext) throws -> Tag {
            try lookupOrCreate(displayName: name, in: context)
        }
    }

    @Model
    public final class MediaTag {
        public var id: String
        public var mediaID: String?
        public var tagID: String?
        public var updatedAt: Date
        public var updatedBy: String?
        public var mediaItem: MediaItem?
        @Relationship(inverse: \Tag.mediaTags)
        public var tag: Tag?

        public init(
            id: String = UUID().uuidString,
            mediaID: String? = nil,
            tagID: String? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            mediaItem: MediaItem? = nil,
            tag: Tag? = nil
        ) {
            self.id = id
            self.mediaID = mediaItem?.id ?? mediaID
            self.tagID = tag?.id ?? tagID
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.mediaItem = mediaItem
            self.tag = tag
        }
    }

    @Model
    public final class Favorite {
        public var id: String
        public var mediaID: String?
        public var accountID: String
        public var isFavorite: Bool
        public var changedAt: Date
        public var mediaItem: MediaItem?

        public init(
            id: String? = nil,
            mediaID: String? = nil,
            accountID: String = MomentsAccount.localID,
            isFavorite: Bool,
            changedAt: Date = .now,
            mediaItem: MediaItem? = nil
        ) {
            let resolvedMediaID = mediaItem?.id ?? mediaID ?? UUID().uuidString
            self.id = id ?? Self.recordID(mediaID: resolvedMediaID, accountID: accountID)
            self.mediaID = mediaItem?.id ?? mediaID
            self.accountID = accountID
            self.isFavorite = isFavorite
            self.changedAt = changedAt
            self.mediaItem = mediaItem
        }

        public static func recordID(mediaID: String, accountID: String) -> String {
            "\(mediaID):\(accountID)"
        }

        public static func lookup(mediaID: String, accountID: String, in context: ModelContext) throws -> Favorite? {
            let id = recordID(mediaID: mediaID, accountID: accountID)
            return try context.fetch(FetchDescriptor<Favorite>())
                .first(where: { $0.id == id })
        }
    }
}

/// The folder-import schema. Import metadata is optional so existing records
/// remain valid and a lightweight migration can add the fields in place.
public enum SchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 0, 0)
    public static let models: [any PersistentModel.Type] = [
        SchemaV3.MediaItem.self,
        SchemaV3.Memory.self,
        SchemaV3.MemoryRevision.self,
        SchemaV3.Place.self,
        SchemaV3.PlaceOverride.self,
        SchemaV3.Trip.self,
        SchemaV3.Tag.self,
        SchemaV3.MediaTag.self,
        SchemaV3.Favorite.self
    ]

    @Model
    public final class MediaItem {
        public var id: String
        public var captureDate: Date?
        public var latitude: Double?
        public var longitude: Double?
        public var kindRaw: String
        public var width: Int
        public var height: Int
        public var isScreenshot: Bool
        public var sourceRaw: String
        public var title: String
        public var tripID: String?
        public var updatedAt: Date
        public var updatedBy: String?
        public var originalBookmarkData: Data?
        public var originalFileName: String?
        public var originalContentHash: String?
        public var captureDateSourceRaw: String?
        public var localTimeZoneOffsetMinutes: Int?
        public var localDayKey: String?
        public var duration: Double?
        public var importReviewReasonsRaw: String?
        public var importedAt: Date?
        public var originalCaptureDateUTC: Date?
        public var captureDateHintUTC: Date?
        public var userCorrectedCaptureDateUTC: Date?
        public var timeZoneIdentifier: String?
        public var timeConfidenceRaw: String?
        public var sourceReferencesRaw: String?
        public var pairedVideoContentHash: String?
        public var pairedVideoBookmarkData: Data?
        public var reviewDecisionRaw: String?
        public var reviewOverridePlaceID: String?
        public var reviewOverrideDateUTC: Date?
        public var reviewMemoryDraft: String?

        @Relationship(inverse: \Place.items)
        public var place: Place?
        @Relationship(inverse: \Trip.items)
        public var trip: Trip?
        @Relationship(deleteRule: .cascade, inverse: \Memory.mediaItem)
        public var memories: [Memory] = []
        @Relationship(inverse: \MediaTag.mediaItem)
        public var mediaTags: [MediaTag] = []
        @Relationship(inverse: \Favorite.mediaItem)
        public var favorites: [Favorite] = []
        @Relationship(inverse: \PlaceOverride.mediaItem)
        public var placeOverrides: [PlaceOverride] = []

        public init(
            id: String = UUID().uuidString,
            captureDate: Date? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil,
            kind: MediaKind = .photo,
            width: Int = 0,
            height: Int = 0,
            isScreenshot: Bool = false,
            source: MediaSource = .file,
            title: String = "",
            tripID: String? = nil,
            tripKey: String? = nil,
            place: Place? = nil,
            trip: Trip? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            originalBookmarkData: Data? = nil,
            originalFileName: String? = nil,
            originalContentHash: String? = nil,
            captureDateSourceRaw: String? = nil,
            localTimeZoneOffsetMinutes: Int? = nil,
            localDayKey: String? = nil,
            duration: Double? = nil,
            importReviewReasonsRaw: String? = nil,
            importedAt: Date? = nil,
            originalCaptureDateUTC: Date? = nil,
            captureDateHintUTC: Date? = nil,
            userCorrectedCaptureDateUTC: Date? = nil,
            timeZoneIdentifier: String? = nil,
            timeConfidenceRaw: String? = nil,
            sourceReferencesRaw: String? = nil,
            pairedVideoContentHash: String? = nil,
            pairedVideoBookmarkData: Data? = nil,
            reviewDecisionRaw: String? = nil,
            reviewOverridePlaceID: String? = nil,
            reviewOverrideDateUTC: Date? = nil,
            reviewMemoryDraft: String? = nil
        ) {
            self.id = id
            self.captureDate = captureDate
            self.latitude = latitude
            self.longitude = longitude
            self.kindRaw = kind.rawValue
            self.width = width
            self.height = height
            self.isScreenshot = isScreenshot
            self.sourceRaw = source.rawValue
            self.title = title
            self.tripID = trip?.id ?? tripID ?? tripKey
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.originalBookmarkData = originalBookmarkData
            self.originalFileName = originalFileName
            self.originalContentHash = originalContentHash
            self.captureDateSourceRaw = captureDateSourceRaw
            self.localTimeZoneOffsetMinutes = localTimeZoneOffsetMinutes
            self.localDayKey = localDayKey
            self.duration = duration
            self.importReviewReasonsRaw = importReviewReasonsRaw
            self.importedAt = importedAt
            self.originalCaptureDateUTC = originalCaptureDateUTC
            self.captureDateHintUTC = captureDateHintUTC
            self.userCorrectedCaptureDateUTC = userCorrectedCaptureDateUTC
            self.timeZoneIdentifier = timeZoneIdentifier
            self.timeConfidenceRaw = timeConfidenceRaw
            self.sourceReferencesRaw = sourceReferencesRaw
            self.pairedVideoContentHash = pairedVideoContentHash
            self.pairedVideoBookmarkData = pairedVideoBookmarkData
            self.reviewDecisionRaw = reviewDecisionRaw
            self.reviewOverridePlaceID = reviewOverridePlaceID
            self.reviewOverrideDateUTC = reviewOverrideDateUTC
            self.reviewMemoryDraft = reviewMemoryDraft
            self.place = place
            self.trip = trip
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
        public var id: String
        public var mediaID: String?
        public var text: String
        public var authorRaw: String
        public var authorAccountID: String?
        public var createdAt: Date
        public var updatedAt: Date
        public var revision: Int
        public var updatedBy: String?
        public var mediaItem: MediaItem?
        @Relationship(deleteRule: .cascade, inverse: \MemoryRevision.memory)
        public var revisions: [MemoryRevision] = []

        public init(
            id: String = UUID().uuidString,
            text: String,
            author: MemoryAuthor = .me,
            authorAccountID: String? = nil,
            createdAt: Date = .now,
            updatedAt: Date = .now,
            revision: Int = 1,
            updatedBy: String? = nil,
            mediaItem: MediaItem? = nil,
            mediaID: String? = nil
        ) {
            self.id = id
            self.mediaID = mediaItem?.id ?? mediaID
            self.text = text
            self.authorRaw = author.rawValue
            self.authorAccountID = authorAccountID
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.revision = revision
            self.updatedBy = updatedBy
            self.mediaItem = mediaItem
        }
    }

    @Model
    public final class MemoryRevision {
        public var id: String
        public var memoryID: String?
        public var text: String
        public var editedBy: String?
        public var editedAt: Date
        public var baseRevision: Int
        public var reason: String?
        public var memory: Memory?

        public init(
            id: String = UUID().uuidString,
            memoryID: String? = nil,
            text: String,
            editedBy: String? = nil,
            editedAt: Date = .now,
            baseRevision: Int,
            reason: String? = nil,
            memory: Memory? = nil
        ) {
            self.id = id
            self.memoryID = memory?.id ?? memoryID
            self.text = text
            self.editedBy = editedBy
            self.editedAt = editedAt
            self.baseRevision = baseRevision
            self.reason = reason
            self.memory = memory
        }
    }

    @Model
    public final class Place {
        public var id: String
        public var name: String
        public var kindRaw: String
        public var latitude: Double?
        public var longitude: Double?
        public var mapLink: String?
        public var updatedAt: Date
        public var updatedBy: String?
        public var parent: Place?
        @Relationship(inverse: \Place.parent)
        public var children: [Place] = []
        public var items: [MediaItem] = []
        public var overrides: [PlaceOverride] = []

        public init(
            id: String = UUID().uuidString,
            name: String,
            kind: PlaceKind = .spot,
            latitude: Double? = nil,
            longitude: Double? = nil,
            mapLink: String? = nil,
            parent: Place? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil
        ) {
            self.id = id
            self.name = name
            self.kindRaw = kind.rawValue
            self.latitude = latitude
            self.longitude = longitude
            self.mapLink = mapLink
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.parent = parent
        }
    }

    @Model
    public final class PlaceOverride {
        public var id: String
        public var placeID: String?
        public var mediaID: String?
        public var accountID: String
        public var nameOverride: String?
        public var mapLinkOverride: String?
        public var latitude: Double?
        public var longitude: Double?
        public var updatedAt: Date
        public var updatedBy: String?
        @Relationship(inverse: \Place.overrides)
        public var place: Place?
        public var mediaItem: MediaItem?

        public init(
            id: String? = nil,
            placeID: String? = nil,
            mediaID: String? = nil,
            accountID: String = MomentsAccount.localID,
            nameOverride: String? = nil,
            mapLinkOverride: String? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            place: Place? = nil,
            mediaItem: MediaItem? = nil
        ) {
            let ownerID = mediaItem?.id ?? mediaID ?? place?.id ?? placeID ?? UUID().uuidString
            self.id = id ?? "\(ownerID):\(accountID)"
            self.placeID = place?.id ?? placeID
            self.mediaID = mediaItem?.id ?? mediaID
            self.accountID = accountID
            self.nameOverride = nameOverride
            self.mapLinkOverride = mapLinkOverride
            self.latitude = latitude
            self.longitude = longitude
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.place = place
            self.mediaItem = mediaItem
        }
    }

    @Model
    public final class Trip {
        public var id: String
        public var name: String
        public var startDate: Date?
        public var endDate: Date?
        public var updatedAt: Date
        public var updatedBy: String?
        public var overrideName: String?
        public var mergeOverrideID: String?
        public var splitOverrideDayKeys: String?
        public var suggestionStatusRaw: String?
        public var confirmedAt: Date?
        public var items: [MediaItem] = []

        public init(
            id: String = UUID().uuidString,
            name: String,
            startDate: Date? = nil,
            endDate: Date? = nil,
            items: [MediaItem] = [],
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            overrideName: String? = nil,
            mergeOverrideID: String? = nil,
            splitOverrideDayKeys: String? = nil,
            suggestionStatusRaw: String? = nil,
            confirmedAt: Date? = nil
        ) {
            self.id = id
            self.name = name
            self.startDate = startDate
            self.endDate = endDate
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.overrideName = overrideName
            self.mergeOverrideID = mergeOverrideID
            self.splitOverrideDayKeys = splitOverrideDayKeys
            self.suggestionStatusRaw = suggestionStatusRaw
            self.confirmedAt = confirmedAt
            self.items = items
        }
    }

    @Model
    public final class Tag {
        public var id: String
        public var normalizedName: String
        public var displayName: String
        public var updatedAt: Date
        public var updatedBy: String?
        public var mediaTags: [MediaTag] = []

        public init(
            id: String = UUID().uuidString,
            displayName: String,
            normalizedName: String? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.normalizedName = normalizedName ?? displayName
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
        }
    }

    @Model
    public final class MediaTag {
        public var id: String
        public var mediaID: String?
        public var tagID: String?
        public var updatedAt: Date
        public var updatedBy: String?
        public var mediaItem: MediaItem?
        @Relationship(inverse: \Tag.mediaTags)
        public var tag: Tag?

        public init(
            id: String = UUID().uuidString,
            mediaID: String? = nil,
            tagID: String? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            mediaItem: MediaItem? = nil,
            tag: Tag? = nil
        ) {
            self.id = id
            self.mediaID = mediaItem?.id ?? mediaID
            self.tagID = tag?.id ?? tagID
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.mediaItem = mediaItem
            self.tag = tag
        }
    }

    @Model
    public final class Favorite {
        public var id: String
        public var mediaID: String?
        public var accountID: String
        public var isFavorite: Bool
        public var changedAt: Date
        public var mediaItem: MediaItem?

        public init(
            id: String? = nil,
            mediaID: String? = nil,
            accountID: String = MomentsAccount.localID,
            isFavorite: Bool,
            changedAt: Date = .now,
            mediaItem: MediaItem? = nil
        ) {
            let resolvedMediaID = mediaItem?.id ?? mediaID ?? UUID().uuidString
            self.id = id ?? Self.recordID(mediaID: resolvedMediaID, accountID: accountID)
            self.mediaID = mediaItem?.id ?? mediaID
            self.accountID = accountID
            self.isFavorite = isFavorite
            self.changedAt = changedAt
            self.mediaItem = mediaItem
        }

        public static func recordID(mediaID: String, accountID: String) -> String {
            "\(mediaID):\(accountID)"
        }
    }
}

@Model
public final class MediaItem {
    public var id: String
    public var captureDate: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var kindRaw: String
    public var width: Int
    public var height: Int
    public var isScreenshot: Bool
    public var sourceRaw: String
    public var title: String
    public var tripID: String?
    public var updatedAt: Date
    public var updatedBy: String?

    // Folder import keeps originals in place. The bookmark is the only path
    // reference persisted by the app; the hash makes re-imports idempotent and
    // lets callers verify that the source was not changed by Moments.
    public var originalBookmarkData: Data?
    public var originalFileName: String?
    public var originalContentHash: String?
    public var captureDateSourceRaw: String?
    public var localTimeZoneOffsetMinutes: Int?
    public var localDayKey: String?
    public var duration: Double?
    public var importReviewReasonsRaw: String?
    public var importedAt: Date?
    public var originalCaptureDateUTC: Date?
    public var captureDateHintUTC: Date?
    public var userCorrectedCaptureDateUTC: Date?
    public var timeZoneIdentifier: String?
    public var timeConfidenceRaw: String?
    public var sourceReferencesRaw: String?
    public var pairedVideoContentHash: String?
    public var pairedVideoBookmarkData: Data?
    /// Apple Photos references. Originals stay in Photos; these values are
    /// stable identifiers only and are optional for folder/demo media.
    public var photosLocalIdentifier: String?
    public var photosCloudIdentifier: String?
    public var photosAlbumIdentifiersRaw: String?
    public var photosMediaSubtypesRaw: Int?
    public var photosAssetMissing: Bool?
    public var perceptualHash: String?
    public var reviewDecisionRaw: String?
    public var reviewOverridePlaceID: String?
    public var reviewOverrideDateUTC: Date?
    public var reviewMemoryDraft: String?

    @Relationship(inverse: \Place.items)
    public var place: Place?
    @Relationship(inverse: \Trip.items)
    public var trip: Trip?
    @Relationship(deleteRule: .cascade, inverse: \Memory.mediaItem)
    public var memories: [Memory] = []
    @Relationship(inverse: \MediaTag.mediaItem)
    public var mediaTags: [MediaTag] = []
    @Relationship(inverse: \Favorite.mediaItem)
    public var favorites: [Favorite] = []
    @Relationship(inverse: \PlaceOverride.mediaItem)
    public var placeOverrides: [PlaceOverride] = []

    public init(
        id: String = UUID().uuidString,
        captureDate: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        kind: MediaKind = .photo,
        width: Int = 0,
        height: Int = 0,
        isScreenshot: Bool = false,
        source: MediaSource = .file,
        title: String = "",
        tripID: String? = nil,
        tripKey: String? = nil,
        place: Place? = nil,
        trip: Trip? = nil,
        updatedAt: Date = .now,
        updatedBy: String? = nil,
        originalBookmarkData: Data? = nil,
        originalFileName: String? = nil,
        originalContentHash: String? = nil,
        captureDateSourceRaw: String? = nil,
        localTimeZoneOffsetMinutes: Int? = nil,
        localDayKey: String? = nil,
        duration: Double? = nil,
        importReviewReasonsRaw: String? = nil,
        importedAt: Date? = nil,
        originalCaptureDateUTC: Date? = nil,
        captureDateHintUTC: Date? = nil,
        userCorrectedCaptureDateUTC: Date? = nil,
        timeZoneIdentifier: String? = nil,
        timeConfidenceRaw: String? = nil,
        sourceReferencesRaw: String? = nil,
        pairedVideoContentHash: String? = nil,
        pairedVideoBookmarkData: Data? = nil,
        photosLocalIdentifier: String? = nil,
        photosCloudIdentifier: String? = nil,
        photosAlbumIdentifiersRaw: String? = nil,
        photosMediaSubtypesRaw: Int? = nil,
        photosAssetMissing: Bool? = nil,
        perceptualHash: String? = nil,
        reviewDecisionRaw: String? = nil,
        reviewOverridePlaceID: String? = nil,
        reviewOverrideDateUTC: Date? = nil,
        reviewMemoryDraft: String? = nil
    ) {
        self.id = id
        self.captureDate = captureDate
        self.latitude = latitude
        self.longitude = longitude
        self.kindRaw = kind.rawValue
        self.width = width
        self.height = height
        self.isScreenshot = isScreenshot
        self.sourceRaw = source.rawValue
        self.title = title
        self.tripID = trip?.id ?? tripID ?? tripKey
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.originalBookmarkData = originalBookmarkData
        self.originalFileName = originalFileName
        self.originalContentHash = originalContentHash
        self.captureDateSourceRaw = captureDateSourceRaw
        self.localTimeZoneOffsetMinutes = localTimeZoneOffsetMinutes
        self.localDayKey = localDayKey
        self.duration = duration
        self.importReviewReasonsRaw = importReviewReasonsRaw
        self.importedAt = importedAt
        self.originalCaptureDateUTC = originalCaptureDateUTC
        self.captureDateHintUTC = captureDateHintUTC
        self.userCorrectedCaptureDateUTC = userCorrectedCaptureDateUTC
        self.timeZoneIdentifier = timeZoneIdentifier
        self.timeConfidenceRaw = timeConfidenceRaw
        self.sourceReferencesRaw = sourceReferencesRaw
        self.pairedVideoContentHash = pairedVideoContentHash
        self.pairedVideoBookmarkData = pairedVideoBookmarkData
        self.photosLocalIdentifier = photosLocalIdentifier
        self.photosCloudIdentifier = photosCloudIdentifier
        self.photosAlbumIdentifiersRaw = photosAlbumIdentifiersRaw
        self.photosMediaSubtypesRaw = photosMediaSubtypesRaw
        self.photosAssetMissing = photosAssetMissing
        self.perceptualHash = perceptualHash
        self.reviewDecisionRaw = reviewDecisionRaw
        self.reviewOverridePlaceID = reviewOverridePlaceID
        self.reviewOverrideDateUTC = reviewOverrideDateUTC
        self.reviewMemoryDraft = reviewMemoryDraft
        self.place = place
        self.trip = trip
    }

    public var kind: MediaKind {
        get { MediaKind(rawValue: kindRaw) ?? .photo }
        set { kindRaw = newValue.rawValue }
    }

    public var source: MediaSource {
        get { MediaSource(rawValue: sourceRaw) ?? .file }
        set { sourceRaw = newValue.rawValue }
    }

    public var effectiveCaptureDate: Date? {
        userCorrectedCaptureDateUTC ?? captureDate
    }

    /// Compatibility spelling used by the current Library and Timeline code.
    public var tripKey: String? {
        get { tripID }
        set { tripID = newValue }
    }

    public var importDecision: ImportReviewDecision {
        get { ImportReviewDecision(rawValue: reviewDecisionRaw ?? "") ?? .pending }
        set { reviewDecisionRaw = newValue.rawValue }
    }

    public var timeConfidence: ImportTimeConfidence {
        ImportTimeConfidence(rawValue: timeConfidenceRaw ?? "") ?? (captureDate == nil ? .missing : .exact)
    }

    public var tags: [Tag] {
        mediaTags.compactMap(\.tag)
    }

    public var isFavorite: Bool {
        favorites.first(where: { $0.accountID == MomentsAccount.localID })?.isFavorite ?? false
    }

    public var localPlaceOverride: PlaceOverride? {
        placeOverrides.first(where: { $0.accountID == MomentsAccount.localID })
    }

    public var placeOverrideName: String? { localPlaceOverride?.nameOverride }
    public var placeOverrideMapLink: String? { localPlaceOverride?.mapLinkOverride }
    public var placeOverrideLatitude: Double? { localPlaceOverride?.latitude }
    public var placeOverrideLongitude: Double? { localPlaceOverride?.longitude }

    /// The place name shown by the app, preferring this person's override.
    public var effectivePlaceName: String? {
        let override = placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return override?.isEmpty == false ? override : place?.name
    }

    /// The map link shown by the app, preferring this person's override.
    public var effectiveMapLink: String? {
        let override = placeOverrideMapLink?.trimmingCharacters(in: .whitespacesAndNewlines)
        return override?.isEmpty == false ? override : place?.mapLink
    }

    /// The coordinate shown by the app, preferring an override and then the canonical place/GPS.
    public var effectiveCoordinate: (latitude: Double, longitude: Double)? {
        if let latitude = placeOverrideLatitude, let longitude = placeOverrideLongitude {
            return (latitude, longitude)
        }
        if let latitude = place?.latitude, let longitude = place?.longitude {
            return (latitude, longitude)
        }
        if let latitude, let longitude {
            return (latitude, longitude)
        }
        return nil
    }

    public func setFavorite(_ value: Bool, accountID: String = MomentsAccount.localID, context: ModelContext) {
        let existingFavorite: Favorite?
        do {
            existingFavorite = try Favorite.lookup(mediaID: id, accountID: accountID, in: context)
        } catch {
            existingFavorite = nil
        }
        if let favorite = existingFavorite {
            favorite.isFavorite = value
            favorite.changedAt = .now
        } else {
            let favorite = Favorite(mediaID: id, accountID: accountID, isFavorite: value, mediaItem: self)
            context.insert(favorite)
        }
        updatedAt = .now
        updatedBy = accountID
    }

    public func addTag(_ tag: Tag, context: ModelContext) {
        guard !mediaTags.contains(where: { $0.tagID == tag.id }) else { return }
        let join = MediaTag(id: "\(id):\(tag.id)", mediaID: id, tagID: tag.id, mediaItem: self, tag: tag)
        context.insert(join)
    }

    public func removeTag(_ tag: Tag, context: ModelContext) {
        guard let join = mediaTags.first(where: { $0.tagID == tag.id }) else { return }
        context.delete(join)
    }
}

@Model
public final class Memory {
    public var id: String
    public var mediaID: String?
    public var text: String
    public var authorRaw: String
    public var authorAccountID: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int
    public var updatedBy: String?
    public var mediaItem: MediaItem?
    @Relationship(deleteRule: .cascade, inverse: \MemoryRevision.memory)
    public var revisions: [MemoryRevision] = []

    public init(
        id: String = UUID().uuidString,
        text: String,
        author: MemoryAuthor = .me,
        authorAccountID: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        revision: Int = 1,
        updatedBy: String? = nil,
        mediaItem: MediaItem? = nil,
        mediaID: String? = nil
    ) {
        self.id = id
        self.mediaID = mediaItem?.id ?? mediaID
        self.text = text
        self.authorRaw = author.rawValue
        self.authorAccountID = authorAccountID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.updatedBy = updatedBy
        self.mediaItem = mediaItem
    }

    public var author: MemoryAuthor {
        get { MemoryAuthor(rawValue: authorRaw) ?? .me }
        set { authorRaw = newValue.rawValue }
    }
}

@Model
public final class MemoryRevision {
    public var id: String
    public var memoryID: String?
    public var text: String
    public var editedBy: String?
    public var editedAt: Date
    public var baseRevision: Int
    public var reason: String?
    public var memory: Memory?

    public init(
        id: String = UUID().uuidString,
        memoryID: String? = nil,
        text: String,
        editedBy: String? = nil,
        editedAt: Date = .now,
        baseRevision: Int,
        reason: String? = nil,
        memory: Memory? = nil
    ) {
        self.id = id
        self.memoryID = memory?.id ?? memoryID
        self.text = text
        self.editedBy = editedBy
        self.editedAt = editedAt
        self.baseRevision = baseRevision
        self.reason = reason
        self.memory = memory
    }
}

@Model
public final class Place {
    public var id: String
    public var name: String
    public var kindRaw: String
    public var latitude: Double?
    public var longitude: Double?
    public var mapLink: String?
    public var updatedAt: Date
    public var updatedBy: String?
    public var parent: Place?
    @Relationship(inverse: \Place.parent)
    public var children: [Place] = []
    public var items: [MediaItem] = []
    public var overrides: [PlaceOverride] = []

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: PlaceKind = .spot,
        latitude: Double? = nil,
        longitude: Double? = nil,
        mapLink: String? = nil,
        parent: Place? = nil,
        updatedAt: Date = .now,
        updatedBy: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.latitude = latitude
        self.longitude = longitude
        self.mapLink = mapLink
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.parent = parent
    }

    public var kind: PlaceKind {
        get { PlaceKind(rawValue: kindRaw) ?? .spot }
        set { kindRaw = newValue.rawValue }
    }
}

@Model
public final class PlaceOverride {
    public var id: String
    public var placeID: String?
    public var mediaID: String?
    public var accountID: String
    public var nameOverride: String?
    public var mapLinkOverride: String?
    public var latitude: Double?
    public var longitude: Double?
    public var updatedAt: Date
    public var updatedBy: String?
    @Relationship(inverse: \Place.overrides)
    public var place: Place?
    public var mediaItem: MediaItem?

    public init(
        id: String? = nil,
        placeID: String? = nil,
        mediaID: String? = nil,
        accountID: String = MomentsAccount.localID,
        nameOverride: String? = nil,
        mapLinkOverride: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        updatedAt: Date = .now,
        updatedBy: String? = nil,
        place: Place? = nil,
        mediaItem: MediaItem? = nil
    ) {
        let ownerID = mediaItem?.id ?? mediaID ?? place?.id ?? placeID ?? UUID().uuidString
        self.id = id ?? "\(ownerID):\(accountID)"
        self.placeID = place?.id ?? placeID
        self.mediaID = mediaItem?.id ?? mediaID
        self.accountID = accountID
        self.nameOverride = nameOverride
        self.mapLinkOverride = mapLinkOverride
        self.latitude = latitude
        self.longitude = longitude
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.place = place
        self.mediaItem = mediaItem
    }

    public var coordinate: (latitude: Double, longitude: Double)? {
        guard let latitude, let longitude else { return nil }
        return (latitude, longitude)
    }
}

@Model
public final class Trip {
    public var id: String
    public var name: String
    public var startDate: Date?
    public var endDate: Date?
    public var updatedAt: Date
    public var updatedBy: String?
    public var overrideName: String?
    public var mergeOverrideID: String?
    public var splitOverrideDayKeys: String?
    public var suggestionStatusRaw: String?
    public var confirmedAt: Date?
    public var items: [MediaItem] = []

    public init(
        id: String = UUID().uuidString,
        name: String,
        startDate: Date? = nil,
        endDate: Date? = nil,
        items: [MediaItem] = [],
        updatedAt: Date = .now,
        updatedBy: String? = nil,
        overrideName: String? = nil,
        mergeOverrideID: String? = nil,
        splitOverrideDayKeys: String? = nil,
        suggestionStatusRaw: String? = nil,
        confirmedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.overrideName = overrideName
        self.mergeOverrideID = mergeOverrideID
        self.splitOverrideDayKeys = splitOverrideDayKeys
        self.suggestionStatusRaw = suggestionStatusRaw
        self.confirmedAt = confirmedAt
        self.items = items
    }

    /// SwiftData does not persist to-many order, so trips are ordered by capture date.
    public var orderedItems: [MediaItem] {
        items.sorted { ($0.captureDate ?? .distantPast, $0.id) < ($1.captureDate ?? .distantPast, $1.id) }
    }

    public var effectiveName: String {
        let value = overrideName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : name
    }

    public var isSuggestion: Bool {
        suggestionStatusRaw == "suggestion"
    }
}

@Model
public final class Tag {
    public var id: String
    public var normalizedName: String
    public var displayName: String
    public var updatedAt: Date
    public var updatedBy: String?
    public var mediaTags: [MediaTag] = []

    public init(id: String = UUID().uuidString, displayName: String, normalizedName: String? = nil, updatedAt: Date = .now, updatedBy: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.normalizedName = normalizedName ?? Self.normalize(displayName)
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }

    /// Compatibility spelling for the pre-sharing UI.
    public convenience init(name: String) {
        self.init(displayName: name)
    }

    public var name: String {
        get { displayName }
        set {
            displayName = newValue
            normalizedName = Self.normalize(newValue)
            updatedAt = .now
        }
    }

    public var items: [MediaItem] {
        mediaTags.compactMap(\.mediaItem)
    }

    public static func normalize(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func lookup(normalizedName: String, in context: ModelContext) throws -> Tag? {
        let normalized = normalize(normalizedName)
        return try context.fetch(FetchDescriptor<Tag>())
            .first(where: { $0.normalizedName == normalized })
    }

    public static func lookupOrCreate(displayName: String, in context: ModelContext) throws -> Tag {
        if let existing = try lookup(normalizedName: displayName, in: context) {
            return existing
        }
        let tag = Tag(displayName: displayName)
        context.insert(tag)
        return tag
    }

    public static func findOrCreate(name: String, in context: ModelContext) throws -> Tag {
        try lookupOrCreate(displayName: name, in: context)
    }
}

@Model
public final class MediaTag {
    public var id: String
    public var mediaID: String?
    public var tagID: String?
    public var updatedAt: Date
    public var updatedBy: String?
    public var mediaItem: MediaItem?
    @Relationship(inverse: \Tag.mediaTags)
    public var tag: Tag?

    public init(
        id: String = UUID().uuidString,
        mediaID: String? = nil,
        tagID: String? = nil,
        updatedAt: Date = .now,
        updatedBy: String? = nil,
        mediaItem: MediaItem? = nil,
        tag: Tag? = nil
    ) {
        self.id = id
        self.mediaID = mediaItem?.id ?? mediaID
        self.tagID = tag?.id ?? tagID
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.mediaItem = mediaItem
        self.tag = tag
    }
}

@Model
public final class Favorite {
    public var id: String
    public var mediaID: String?
    public var accountID: String
    public var isFavorite: Bool
    public var changedAt: Date
    public var mediaItem: MediaItem?

    public init(
        id: String? = nil,
        mediaID: String? = nil,
        accountID: String = MomentsAccount.localID,
        isFavorite: Bool,
        changedAt: Date = .now,
        mediaItem: MediaItem? = nil
    ) {
        let resolvedMediaID = mediaItem?.id ?? mediaID ?? UUID().uuidString
        self.id = id ?? Self.recordID(mediaID: resolvedMediaID, accountID: accountID)
        self.mediaID = mediaItem?.id ?? mediaID
        self.accountID = accountID
        self.isFavorite = isFavorite
        self.changedAt = changedAt
        self.mediaItem = mediaItem
    }

    public static func recordID(mediaID: String, accountID: String) -> String {
        "\(mediaID):\(accountID)"
    }

    public static func lookup(mediaID: String, accountID: String, in context: ModelContext) throws -> Favorite? {
        let id = recordID(mediaID: mediaID, accountID: accountID)
        return try context.fetch(FetchDescriptor<Favorite>())
            .first(where: { $0.id == id })
    }
}

/// The Apple Photos schema: the V3 shape plus the Photos fields.
public enum SchemaV4: VersionedSchema {
    public static let versionIdentifier = Schema.Version(4, 0, 0)
    // V4 is frozen here as nested copies of the live model shape. Keep the
    // newest schema (V5) on the top-level classes below so relationship
    // getters never resolve to duplicate same-version entities.
    @Model
    public final class MediaItem {
        public var id: String
        public var captureDate: Date?
        public var latitude: Double?
        public var longitude: Double?
        public var kindRaw: String
        public var width: Int
        public var height: Int
        public var isScreenshot: Bool
        public var sourceRaw: String
        public var title: String
        public var tripID: String?
        public var updatedAt: Date
        public var updatedBy: String?

        // Folder import keeps originals in place. The bookmark is the only path
        // reference persisted by the app; the hash makes re-imports idempotent and
        // lets callers verify that the source was not changed by Moments.
        public var originalBookmarkData: Data?
        public var originalFileName: String?
        public var originalContentHash: String?
        public var captureDateSourceRaw: String?
        public var localTimeZoneOffsetMinutes: Int?
        public var localDayKey: String?
        public var duration: Double?
        public var importReviewReasonsRaw: String?
        public var importedAt: Date?
        public var originalCaptureDateUTC: Date?
        public var captureDateHintUTC: Date?
        public var userCorrectedCaptureDateUTC: Date?
        public var timeZoneIdentifier: String?
        public var timeConfidenceRaw: String?
        public var sourceReferencesRaw: String?
        public var pairedVideoContentHash: String?
        public var pairedVideoBookmarkData: Data?
        /// Apple Photos references. Originals stay in Photos; these values are
        /// stable identifiers only and are optional for folder/demo media.
        public var photosLocalIdentifier: String?
        public var photosCloudIdentifier: String?
        public var photosAlbumIdentifiersRaw: String?
        public var photosMediaSubtypesRaw: Int?
        public var photosAssetMissing: Bool?
        public var perceptualHash: String?
        public var reviewDecisionRaw: String?
        public var reviewOverridePlaceID: String?
        public var reviewOverrideDateUTC: Date?
        public var reviewMemoryDraft: String?

        @Relationship(inverse: \Place.items)
        public var place: Place?
        @Relationship(inverse: \Trip.items)
        public var trip: Trip?
        @Relationship(deleteRule: .cascade, inverse: \Memory.mediaItem)
        public var memories: [Memory] = []
        @Relationship(inverse: \MediaTag.mediaItem)
        public var mediaTags: [MediaTag] = []
        @Relationship(inverse: \Favorite.mediaItem)
        public var favorites: [Favorite] = []
        @Relationship(inverse: \PlaceOverride.mediaItem)
        public var placeOverrides: [PlaceOverride] = []

        public init(
            id: String = UUID().uuidString,
            captureDate: Date? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil,
            kind: MediaKind = .photo,
            width: Int = 0,
            height: Int = 0,
            isScreenshot: Bool = false,
            source: MediaSource = .file,
            title: String = "",
            tripID: String? = nil,
            tripKey: String? = nil,
            place: Place? = nil,
            trip: Trip? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            originalBookmarkData: Data? = nil,
            originalFileName: String? = nil,
            originalContentHash: String? = nil,
            captureDateSourceRaw: String? = nil,
            localTimeZoneOffsetMinutes: Int? = nil,
            localDayKey: String? = nil,
            duration: Double? = nil,
            importReviewReasonsRaw: String? = nil,
            importedAt: Date? = nil,
            originalCaptureDateUTC: Date? = nil,
            captureDateHintUTC: Date? = nil,
            userCorrectedCaptureDateUTC: Date? = nil,
            timeZoneIdentifier: String? = nil,
            timeConfidenceRaw: String? = nil,
            sourceReferencesRaw: String? = nil,
            pairedVideoContentHash: String? = nil,
            pairedVideoBookmarkData: Data? = nil,
            photosLocalIdentifier: String? = nil,
            photosCloudIdentifier: String? = nil,
            photosAlbumIdentifiersRaw: String? = nil,
            photosMediaSubtypesRaw: Int? = nil,
            photosAssetMissing: Bool? = nil,
            perceptualHash: String? = nil,
            reviewDecisionRaw: String? = nil,
            reviewOverridePlaceID: String? = nil,
            reviewOverrideDateUTC: Date? = nil,
            reviewMemoryDraft: String? = nil
        ) {
            self.id = id
            self.captureDate = captureDate
            self.latitude = latitude
            self.longitude = longitude
            self.kindRaw = kind.rawValue
            self.width = width
            self.height = height
            self.isScreenshot = isScreenshot
            self.sourceRaw = source.rawValue
            self.title = title
            self.tripID = trip?.id ?? tripID ?? tripKey
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.originalBookmarkData = originalBookmarkData
            self.originalFileName = originalFileName
            self.originalContentHash = originalContentHash
            self.captureDateSourceRaw = captureDateSourceRaw
            self.localTimeZoneOffsetMinutes = localTimeZoneOffsetMinutes
            self.localDayKey = localDayKey
            self.duration = duration
            self.importReviewReasonsRaw = importReviewReasonsRaw
            self.importedAt = importedAt
            self.originalCaptureDateUTC = originalCaptureDateUTC
            self.captureDateHintUTC = captureDateHintUTC
            self.userCorrectedCaptureDateUTC = userCorrectedCaptureDateUTC
            self.timeZoneIdentifier = timeZoneIdentifier
            self.timeConfidenceRaw = timeConfidenceRaw
            self.sourceReferencesRaw = sourceReferencesRaw
            self.pairedVideoContentHash = pairedVideoContentHash
            self.pairedVideoBookmarkData = pairedVideoBookmarkData
            self.photosLocalIdentifier = photosLocalIdentifier
            self.photosCloudIdentifier = photosCloudIdentifier
            self.photosAlbumIdentifiersRaw = photosAlbumIdentifiersRaw
            self.photosMediaSubtypesRaw = photosMediaSubtypesRaw
            self.photosAssetMissing = photosAssetMissing
            self.perceptualHash = perceptualHash
            self.reviewDecisionRaw = reviewDecisionRaw
            self.reviewOverridePlaceID = reviewOverridePlaceID
            self.reviewOverrideDateUTC = reviewOverrideDateUTC
            self.reviewMemoryDraft = reviewMemoryDraft
            self.place = place
            self.trip = trip
        }

        public var kind: MediaKind {
            get { MediaKind(rawValue: kindRaw) ?? .photo }
            set { kindRaw = newValue.rawValue }
        }

        public var source: MediaSource {
            get { MediaSource(rawValue: sourceRaw) ?? .file }
            set { sourceRaw = newValue.rawValue }
        }

        public var effectiveCaptureDate: Date? {
            userCorrectedCaptureDateUTC ?? captureDate
        }

        /// Compatibility spelling used by the current Library and Timeline code.
        public var tripKey: String? {
            get { tripID }
            set { tripID = newValue }
        }

        public var importDecision: ImportReviewDecision {
            get { ImportReviewDecision(rawValue: reviewDecisionRaw ?? "") ?? .pending }
            set { reviewDecisionRaw = newValue.rawValue }
        }

        public var timeConfidence: ImportTimeConfidence {
            ImportTimeConfidence(rawValue: timeConfidenceRaw ?? "") ?? (captureDate == nil ? .missing : .exact)
        }

        public var tags: [Tag] {
            mediaTags.compactMap(\.tag)
        }

        public var isFavorite: Bool {
            favorites.first(where: { $0.accountID == MomentsAccount.localID })?.isFavorite ?? false
        }

        public var localPlaceOverride: PlaceOverride? {
            placeOverrides.first(where: { $0.accountID == MomentsAccount.localID })
        }

        public var placeOverrideName: String? { localPlaceOverride?.nameOverride }
        public var placeOverrideMapLink: String? { localPlaceOverride?.mapLinkOverride }
        public var placeOverrideLatitude: Double? { localPlaceOverride?.latitude }
        public var placeOverrideLongitude: Double? { localPlaceOverride?.longitude }

        /// The place name shown by the app, preferring this person's override.
        public var effectivePlaceName: String? {
            let override = placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return override?.isEmpty == false ? override : place?.name
        }

        /// The map link shown by the app, preferring this person's override.
        public var effectiveMapLink: String? {
            let override = placeOverrideMapLink?.trimmingCharacters(in: .whitespacesAndNewlines)
            return override?.isEmpty == false ? override : place?.mapLink
        }

        /// The coordinate shown by the app, preferring an override and then the canonical place/GPS.
        public var effectiveCoordinate: (latitude: Double, longitude: Double)? {
            if let latitude = placeOverrideLatitude, let longitude = placeOverrideLongitude {
                return (latitude, longitude)
            }
            if let latitude = place?.latitude, let longitude = place?.longitude {
                return (latitude, longitude)
            }
            if let latitude, let longitude {
                return (latitude, longitude)
            }
            return nil
        }

        public func setFavorite(_ value: Bool, accountID: String = MomentsAccount.localID, context: ModelContext) {
            let existingFavorite: Favorite?
            do {
                existingFavorite = try Favorite.lookup(mediaID: id, accountID: accountID, in: context)
            } catch {
                existingFavorite = nil
            }
            if let favorite = existingFavorite {
                favorite.isFavorite = value
                favorite.changedAt = .now
            } else {
                let favorite = Favorite(mediaID: id, accountID: accountID, isFavorite: value, mediaItem: self)
                context.insert(favorite)
            }
            updatedAt = .now
            updatedBy = accountID
        }

        public func addTag(_ tag: Tag, context: ModelContext) {
            guard !mediaTags.contains(where: { $0.tagID == tag.id }) else { return }
            let join = MediaTag(id: "\(id):\(tag.id)", mediaID: id, tagID: tag.id, mediaItem: self, tag: tag)
            context.insert(join)
        }

        public func removeTag(_ tag: Tag, context: ModelContext) {
            guard let join = mediaTags.first(where: { $0.tagID == tag.id }) else { return }
            context.delete(join)
        }
    }

    @Model
    public final class Memory {
        public var id: String
        public var mediaID: String?
        public var text: String
        public var authorRaw: String
        public var authorAccountID: String?
        public var createdAt: Date
        public var updatedAt: Date
        public var revision: Int
        public var updatedBy: String?
        public var mediaItem: MediaItem?
        @Relationship(deleteRule: .cascade, inverse: \MemoryRevision.memory)
        public var revisions: [MemoryRevision] = []

        public init(
            id: String = UUID().uuidString,
            text: String,
            author: MemoryAuthor = .me,
            authorAccountID: String? = nil,
            createdAt: Date = .now,
            updatedAt: Date = .now,
            revision: Int = 1,
            updatedBy: String? = nil,
            mediaItem: MediaItem? = nil,
            mediaID: String? = nil
        ) {
            self.id = id
            self.mediaID = mediaItem?.id ?? mediaID
            self.text = text
            self.authorRaw = author.rawValue
            self.authorAccountID = authorAccountID
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.revision = revision
            self.updatedBy = updatedBy
            self.mediaItem = mediaItem
        }

        public var author: MemoryAuthor {
            get { MemoryAuthor(rawValue: authorRaw) ?? .me }
            set { authorRaw = newValue.rawValue }
        }
    }

    @Model
    public final class MemoryRevision {
        public var id: String
        public var memoryID: String?
        public var text: String
        public var editedBy: String?
        public var editedAt: Date
        public var baseRevision: Int
        public var reason: String?
        public var memory: Memory?

        public init(
            id: String = UUID().uuidString,
            memoryID: String? = nil,
            text: String,
            editedBy: String? = nil,
            editedAt: Date = .now,
            baseRevision: Int,
            reason: String? = nil,
            memory: Memory? = nil
        ) {
            self.id = id
            self.memoryID = memory?.id ?? memoryID
            self.text = text
            self.editedBy = editedBy
            self.editedAt = editedAt
            self.baseRevision = baseRevision
            self.reason = reason
            self.memory = memory
        }
    }

    @Model
    public final class Place {
        public var id: String
        public var name: String
        public var kindRaw: String
        public var latitude: Double?
        public var longitude: Double?
        public var mapLink: String?
        public var updatedAt: Date
        public var updatedBy: String?
        public var parent: Place?
        @Relationship(inverse: \Place.parent)
        public var children: [Place] = []
        public var items: [MediaItem] = []
        public var overrides: [PlaceOverride] = []

        public init(
            id: String = UUID().uuidString,
            name: String,
            kind: PlaceKind = .spot,
            latitude: Double? = nil,
            longitude: Double? = nil,
            mapLink: String? = nil,
            parent: Place? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil
        ) {
            self.id = id
            self.name = name
            self.kindRaw = kind.rawValue
            self.latitude = latitude
            self.longitude = longitude
            self.mapLink = mapLink
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.parent = parent
        }

        public var kind: PlaceKind {
            get { PlaceKind(rawValue: kindRaw) ?? .spot }
            set { kindRaw = newValue.rawValue }
        }
    }

    @Model
    public final class PlaceOverride {
        public var id: String
        public var placeID: String?
        public var mediaID: String?
        public var accountID: String
        public var nameOverride: String?
        public var mapLinkOverride: String?
        public var latitude: Double?
        public var longitude: Double?
        public var updatedAt: Date
        public var updatedBy: String?
        @Relationship(inverse: \Place.overrides)
        public var place: Place?
        public var mediaItem: MediaItem?

        public init(
            id: String? = nil,
            placeID: String? = nil,
            mediaID: String? = nil,
            accountID: String = MomentsAccount.localID,
            nameOverride: String? = nil,
            mapLinkOverride: String? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            place: Place? = nil,
            mediaItem: MediaItem? = nil
        ) {
            let ownerID = mediaItem?.id ?? mediaID ?? place?.id ?? placeID ?? UUID().uuidString
            self.id = id ?? "\(ownerID):\(accountID)"
            self.placeID = place?.id ?? placeID
            self.mediaID = mediaItem?.id ?? mediaID
            self.accountID = accountID
            self.nameOverride = nameOverride
            self.mapLinkOverride = mapLinkOverride
            self.latitude = latitude
            self.longitude = longitude
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.place = place
            self.mediaItem = mediaItem
        }

        public var coordinate: (latitude: Double, longitude: Double)? {
            guard let latitude, let longitude else { return nil }
            return (latitude, longitude)
        }
    }

    @Model
    public final class Trip {
        public var id: String
        public var name: String
        public var startDate: Date?
        public var endDate: Date?
        public var updatedAt: Date
        public var updatedBy: String?
        public var overrideName: String?
        public var mergeOverrideID: String?
        public var splitOverrideDayKeys: String?
        public var suggestionStatusRaw: String?
        public var confirmedAt: Date?
        public var items: [MediaItem] = []

        public init(
            id: String = UUID().uuidString,
            name: String,
            startDate: Date? = nil,
            endDate: Date? = nil,
            items: [MediaItem] = [],
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            overrideName: String? = nil,
            mergeOverrideID: String? = nil,
            splitOverrideDayKeys: String? = nil,
            suggestionStatusRaw: String? = nil,
            confirmedAt: Date? = nil
        ) {
            self.id = id
            self.name = name
            self.startDate = startDate
            self.endDate = endDate
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.overrideName = overrideName
            self.mergeOverrideID = mergeOverrideID
            self.splitOverrideDayKeys = splitOverrideDayKeys
            self.suggestionStatusRaw = suggestionStatusRaw
            self.confirmedAt = confirmedAt
            self.items = items
        }

        /// SwiftData does not persist to-many order, so trips are ordered by capture date.
        public var orderedItems: [MediaItem] {
            items.sorted { ($0.captureDate ?? .distantPast, $0.id) < ($1.captureDate ?? .distantPast, $1.id) }
        }

        public var effectiveName: String {
            let value = overrideName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value! : name
        }

        public var isSuggestion: Bool {
            suggestionStatusRaw == "suggestion"
        }
    }

    @Model
    public final class Tag {
        public var id: String
        public var normalizedName: String
        public var displayName: String
        public var updatedAt: Date
        public var updatedBy: String?
        public var mediaTags: [MediaTag] = []

        public init(id: String = UUID().uuidString, displayName: String, normalizedName: String? = nil, updatedAt: Date = .now, updatedBy: String? = nil) {
            self.id = id
            self.displayName = displayName
            self.normalizedName = normalizedName ?? Self.normalize(displayName)
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
        }

        /// Compatibility spelling for the pre-sharing UI.
        public convenience init(name: String) {
            self.init(displayName: name)
        }

        public var name: String {
            get { displayName }
            set {
                displayName = newValue
                normalizedName = Self.normalize(newValue)
                updatedAt = .now
            }
        }

        public var items: [MediaItem] {
            mediaTags.compactMap(\.mediaItem)
        }

        public static func normalize(_ name: String) -> String {
            name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
                .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }

        public static func lookup(normalizedName: String, in context: ModelContext) throws -> Tag? {
            let normalized = normalize(normalizedName)
            return try context.fetch(FetchDescriptor<Tag>())
                .first(where: { $0.normalizedName == normalized })
        }

        public static func lookupOrCreate(displayName: String, in context: ModelContext) throws -> Tag {
            if let existing = try lookup(normalizedName: displayName, in: context) {
                return existing
            }
            let tag = Tag(displayName: displayName)
            context.insert(tag)
            return tag
        }

        public static func findOrCreate(name: String, in context: ModelContext) throws -> Tag {
            try lookupOrCreate(displayName: name, in: context)
        }
    }

    @Model
    public final class MediaTag {
        public var id: String
        public var mediaID: String?
        public var tagID: String?
        public var updatedAt: Date
        public var updatedBy: String?
        public var mediaItem: MediaItem?
        @Relationship(inverse: \Tag.mediaTags)
        public var tag: Tag?

        public init(
            id: String = UUID().uuidString,
            mediaID: String? = nil,
            tagID: String? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            mediaItem: MediaItem? = nil,
            tag: Tag? = nil
        ) {
            self.id = id
            self.mediaID = mediaItem?.id ?? mediaID
            self.tagID = tag?.id ?? tagID
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.mediaItem = mediaItem
            self.tag = tag
        }
    }

    @Model
    public final class Favorite {
        public var id: String
        public var mediaID: String?
        public var accountID: String
        public var isFavorite: Bool
        public var changedAt: Date
        public var mediaItem: MediaItem?

        public init(
            id: String? = nil,
            mediaID: String? = nil,
            accountID: String = MomentsAccount.localID,
            isFavorite: Bool,
            changedAt: Date = .now,
            mediaItem: MediaItem? = nil
        ) {
            let resolvedMediaID = mediaItem?.id ?? mediaID ?? UUID().uuidString
            self.id = id ?? Self.recordID(mediaID: resolvedMediaID, accountID: accountID)
            self.mediaID = mediaItem?.id ?? mediaID
            self.accountID = accountID
            self.isFavorite = isFavorite
            self.changedAt = changedAt
            self.mediaItem = mediaItem
        }

        public static func recordID(mediaID: String, accountID: String) -> String {
            "\(mediaID):\(accountID)"
        }

        public static func lookup(mediaID: String, accountID: String, in context: ModelContext) throws -> Favorite? {
            let id = recordID(mediaID: mediaID, accountID: accountID)
            return try context.fetch(FetchDescriptor<Favorite>())
                .first(where: { $0.id == id })
        }
    }


    public static let models: [any PersistentModel.Type] = [
        SchemaV4.MediaItem.self,
        SchemaV4.Memory.self,
        SchemaV4.MemoryRevision.self,
        SchemaV4.Place.self,
        SchemaV4.PlaceOverride.self,
        SchemaV4.Trip.self,
        SchemaV4.Tag.self,
        SchemaV4.MediaTag.self,
        SchemaV4.Favorite.self
    ]
}

/// A persisted rule used by custom smart groups. The JSON payload is kept
/// independent of SwiftData relationships so it can be shared and migrated
/// without coupling groups to MediaItem.
@Model
public final class UserGroup {
    public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        /// `stack`: what someone changed about a burst of similar photos (its
        /// cover, unstacked, photos taken out), as a `StackDecision` in
        /// `rulesData`. Not a "My groups" entry; see `PhotoStackModel`.
        case manual, smart, stack
    }

    public var id: String
    public var name: String
    public var kindRaw: String
    public var rulesData: Data
    public var ownerAccountID: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: Kind = .manual,
        rules: UserGroupRuleSet = UserGroupRuleSet(),
        ownerAccountID: String = MomentsAccount.localID,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.rulesData = (try? JSONEncoder().encode(rules)) ?? Data()
        self.ownerAccountID = ownerAccountID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var kind: Kind {
        get { Kind(rawValue: kindRaw) ?? .manual }
        set { kindRaw = newValue.rawValue }
    }

    public var rules: UserGroupRuleSet {
        get { (try? JSONDecoder().decode(UserGroupRuleSet.self, from: rulesData)) ?? UserGroupRuleSet() }
        set { rulesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

@Model
public final class UserGroupItem {
    public var id: String
    public var groupID: String
    public var mediaID: String
    public var addedBy: String
    public var excluded: Bool
    public var addedAt: Date

    public init(
        id: String = UUID().uuidString,
        groupID: String,
        mediaID: String,
        addedBy: String = MomentsAccount.localID,
        excluded: Bool = false,
        addedAt: Date = .now
    ) {
        self.id = id
        self.groupID = groupID
        self.mediaID = mediaID
        self.addedBy = addedBy
        self.excluded = excluded
        self.addedAt = addedAt
    }
}

/// Frozen V5 schema. These nested copies preserve the exact V5 entity shape for migration tests and stores.
public enum SchemaV5: VersionedSchema {
    public static let versionIdentifier = Schema.Version(5, 0, 0)

    @Model
    public final class MediaItem {
        public var id: String
        public var captureDate: Date?
        public var latitude: Double?
        public var longitude: Double?
        public var kindRaw: String
        public var width: Int
        public var height: Int
        public var isScreenshot: Bool
        public var sourceRaw: String
        public var title: String
        public var tripID: String?
        public var updatedAt: Date
        public var updatedBy: String?

        // Folder import keeps originals in place. The bookmark is the only path
        // reference persisted by the app; the hash makes re-imports idempotent and
        // lets callers verify that the source was not changed by Moments.
        public var originalBookmarkData: Data?
        public var originalFileName: String?
        public var originalContentHash: String?
        public var captureDateSourceRaw: String?
        public var localTimeZoneOffsetMinutes: Int?
        public var localDayKey: String?
        public var duration: Double?
        public var importReviewReasonsRaw: String?
        public var importedAt: Date?
        public var originalCaptureDateUTC: Date?
        public var captureDateHintUTC: Date?
        public var userCorrectedCaptureDateUTC: Date?
        public var timeZoneIdentifier: String?
        public var timeConfidenceRaw: String?
        public var sourceReferencesRaw: String?
        public var pairedVideoContentHash: String?
        public var pairedVideoBookmarkData: Data?
        /// Apple Photos references. Originals stay in Photos; these values are
        /// stable identifiers only and are optional for folder/demo media.
        public var photosLocalIdentifier: String?
        public var photosCloudIdentifier: String?
        public var photosAlbumIdentifiersRaw: String?
        public var photosMediaSubtypesRaw: Int?
        public var photosAssetMissing: Bool?
        public var perceptualHash: String?
        public var reviewDecisionRaw: String?
        public var reviewOverridePlaceID: String?
        public var reviewOverrideDateUTC: Date?
        public var reviewMemoryDraft: String?

        @Relationship(inverse: \Place.items)
        public var place: Place?
        @Relationship(inverse: \Trip.items)
        public var trip: Trip?
        @Relationship(deleteRule: .cascade, inverse: \Memory.mediaItem)
        public var memories: [Memory] = []
        @Relationship(inverse: \MediaTag.mediaItem)
        public var mediaTags: [MediaTag] = []
        @Relationship(inverse: \Favorite.mediaItem)
        public var favorites: [Favorite] = []
        @Relationship(inverse: \PlaceOverride.mediaItem)
        public var placeOverrides: [PlaceOverride] = []

        public init(
            id: String = UUID().uuidString,
            captureDate: Date? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil,
            kind: MediaKind = .photo,
            width: Int = 0,
            height: Int = 0,
            isScreenshot: Bool = false,
            source: MediaSource = .file,
            title: String = "",
            tripID: String? = nil,
            tripKey: String? = nil,
            place: Place? = nil,
            trip: Trip? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            originalBookmarkData: Data? = nil,
            originalFileName: String? = nil,
            originalContentHash: String? = nil,
            captureDateSourceRaw: String? = nil,
            localTimeZoneOffsetMinutes: Int? = nil,
            localDayKey: String? = nil,
            duration: Double? = nil,
            importReviewReasonsRaw: String? = nil,
            importedAt: Date? = nil,
            originalCaptureDateUTC: Date? = nil,
            captureDateHintUTC: Date? = nil,
            userCorrectedCaptureDateUTC: Date? = nil,
            timeZoneIdentifier: String? = nil,
            timeConfidenceRaw: String? = nil,
            sourceReferencesRaw: String? = nil,
            pairedVideoContentHash: String? = nil,
            pairedVideoBookmarkData: Data? = nil,
            photosLocalIdentifier: String? = nil,
            photosCloudIdentifier: String? = nil,
            photosAlbumIdentifiersRaw: String? = nil,
            photosMediaSubtypesRaw: Int? = nil,
            photosAssetMissing: Bool? = nil,
            perceptualHash: String? = nil,
            reviewDecisionRaw: String? = nil,
            reviewOverridePlaceID: String? = nil,
            reviewOverrideDateUTC: Date? = nil,
            reviewMemoryDraft: String? = nil
        ) {
            self.id = id
            self.captureDate = captureDate
            self.latitude = latitude
            self.longitude = longitude
            self.kindRaw = kind.rawValue
            self.width = width
            self.height = height
            self.isScreenshot = isScreenshot
            self.sourceRaw = source.rawValue
            self.title = title
            self.tripID = trip?.id ?? tripID ?? tripKey
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.originalBookmarkData = originalBookmarkData
            self.originalFileName = originalFileName
            self.originalContentHash = originalContentHash
            self.captureDateSourceRaw = captureDateSourceRaw
            self.localTimeZoneOffsetMinutes = localTimeZoneOffsetMinutes
            self.localDayKey = localDayKey
            self.duration = duration
            self.importReviewReasonsRaw = importReviewReasonsRaw
            self.importedAt = importedAt
            self.originalCaptureDateUTC = originalCaptureDateUTC
            self.captureDateHintUTC = captureDateHintUTC
            self.userCorrectedCaptureDateUTC = userCorrectedCaptureDateUTC
            self.timeZoneIdentifier = timeZoneIdentifier
            self.timeConfidenceRaw = timeConfidenceRaw
            self.sourceReferencesRaw = sourceReferencesRaw
            self.pairedVideoContentHash = pairedVideoContentHash
            self.pairedVideoBookmarkData = pairedVideoBookmarkData
            self.photosLocalIdentifier = photosLocalIdentifier
            self.photosCloudIdentifier = photosCloudIdentifier
            self.photosAlbumIdentifiersRaw = photosAlbumIdentifiersRaw
            self.photosMediaSubtypesRaw = photosMediaSubtypesRaw
            self.photosAssetMissing = photosAssetMissing
            self.perceptualHash = perceptualHash
            self.reviewDecisionRaw = reviewDecisionRaw
            self.reviewOverridePlaceID = reviewOverridePlaceID
            self.reviewOverrideDateUTC = reviewOverrideDateUTC
            self.reviewMemoryDraft = reviewMemoryDraft
            self.place = place
            self.trip = trip
        }

        public var kind: MediaKind {
            get { MediaKind(rawValue: kindRaw) ?? .photo }
            set { kindRaw = newValue.rawValue }
        }

        public var source: MediaSource {
            get { MediaSource(rawValue: sourceRaw) ?? .file }
            set { sourceRaw = newValue.rawValue }
        }

        public var effectiveCaptureDate: Date? {
            userCorrectedCaptureDateUTC ?? captureDate
        }

        /// Compatibility spelling used by the current Library and Timeline code.
        public var tripKey: String? {
            get { tripID }
            set { tripID = newValue }
        }

        public var importDecision: ImportReviewDecision {
            get { ImportReviewDecision(rawValue: reviewDecisionRaw ?? "") ?? .pending }
            set { reviewDecisionRaw = newValue.rawValue }
        }

        public var timeConfidence: ImportTimeConfidence {
            ImportTimeConfidence(rawValue: timeConfidenceRaw ?? "") ?? (captureDate == nil ? .missing : .exact)
        }

        public var tags: [Tag] {
            mediaTags.compactMap(\.tag)
        }

        public var isFavorite: Bool {
            favorites.first(where: { $0.accountID == MomentsAccount.localID })?.isFavorite ?? false
        }

        public var localPlaceOverride: PlaceOverride? {
            placeOverrides.first(where: { $0.accountID == MomentsAccount.localID })
        }

        public var placeOverrideName: String? { localPlaceOverride?.nameOverride }
        public var placeOverrideMapLink: String? { localPlaceOverride?.mapLinkOverride }
        public var placeOverrideLatitude: Double? { localPlaceOverride?.latitude }
        public var placeOverrideLongitude: Double? { localPlaceOverride?.longitude }

        /// The place name shown by the app, preferring this person's override.
        public var effectivePlaceName: String? {
            let override = placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return override?.isEmpty == false ? override : place?.name
        }

        /// The map link shown by the app, preferring this person's override.
        public var effectiveMapLink: String? {
            let override = placeOverrideMapLink?.trimmingCharacters(in: .whitespacesAndNewlines)
            return override?.isEmpty == false ? override : place?.mapLink
        }

        /// The coordinate shown by the app, preferring an override and then the canonical place/GPS.
        public var effectiveCoordinate: (latitude: Double, longitude: Double)? {
            if let latitude = placeOverrideLatitude, let longitude = placeOverrideLongitude {
                return (latitude, longitude)
            }
            if let latitude = place?.latitude, let longitude = place?.longitude {
                return (latitude, longitude)
            }
            if let latitude, let longitude {
                return (latitude, longitude)
            }
            return nil
        }

        public func setFavorite(_ value: Bool, accountID: String = MomentsAccount.localID, context: ModelContext) {
            let existingFavorite: Favorite?
            do {
                existingFavorite = try Favorite.lookup(mediaID: id, accountID: accountID, in: context)
            } catch {
                existingFavorite = nil
            }
            if let favorite = existingFavorite {
                favorite.isFavorite = value
                favorite.changedAt = .now
            } else {
                let favorite = Favorite(mediaID: id, accountID: accountID, isFavorite: value, mediaItem: self)
                context.insert(favorite)
            }
            updatedAt = .now
            updatedBy = accountID
        }

        public func addTag(_ tag: Tag, context: ModelContext) {
            guard !mediaTags.contains(where: { $0.tagID == tag.id }) else { return }
            let join = MediaTag(id: "\(id):\(tag.id)", mediaID: id, tagID: tag.id, mediaItem: self, tag: tag)
            context.insert(join)
        }

        public func removeTag(_ tag: Tag, context: ModelContext) {
            guard let join = mediaTags.first(where: { $0.tagID == tag.id }) else { return }
            context.delete(join)
        }
    }

    @Model
    public final class Memory {
        public var id: String
        public var mediaID: String?
        public var text: String
        public var authorRaw: String
        public var authorAccountID: String?
        public var createdAt: Date
        public var updatedAt: Date
        public var revision: Int
        public var updatedBy: String?
        public var mediaItem: MediaItem?
        @Relationship(deleteRule: .cascade, inverse: \MemoryRevision.memory)
        public var revisions: [MemoryRevision] = []

        public init(
            id: String = UUID().uuidString,
            text: String,
            author: MemoryAuthor = .me,
            authorAccountID: String? = nil,
            createdAt: Date = .now,
            updatedAt: Date = .now,
            revision: Int = 1,
            updatedBy: String? = nil,
            mediaItem: MediaItem? = nil,
            mediaID: String? = nil
        ) {
            self.id = id
            self.mediaID = mediaItem?.id ?? mediaID
            self.text = text
            self.authorRaw = author.rawValue
            self.authorAccountID = authorAccountID
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.revision = revision
            self.updatedBy = updatedBy
            self.mediaItem = mediaItem
        }

        public var author: MemoryAuthor {
            get { MemoryAuthor(rawValue: authorRaw) ?? .me }
            set { authorRaw = newValue.rawValue }
        }
    }

    @Model
    public final class MemoryRevision {
        public var id: String
        public var memoryID: String?
        public var text: String
        public var editedBy: String?
        public var editedAt: Date
        public var baseRevision: Int
        public var reason: String?
        public var memory: Memory?

        public init(
            id: String = UUID().uuidString,
            memoryID: String? = nil,
            text: String,
            editedBy: String? = nil,
            editedAt: Date = .now,
            baseRevision: Int,
            reason: String? = nil,
            memory: Memory? = nil
        ) {
            self.id = id
            self.memoryID = memory?.id ?? memoryID
            self.text = text
            self.editedBy = editedBy
            self.editedAt = editedAt
            self.baseRevision = baseRevision
            self.reason = reason
            self.memory = memory
        }
    }

    @Model
    public final class Place {
        public var id: String
        public var name: String
        public var kindRaw: String
        public var latitude: Double?
        public var longitude: Double?
        public var mapLink: String?
        public var updatedAt: Date
        public var updatedBy: String?
        public var parent: Place?
        @Relationship(inverse: \Place.parent)
        public var children: [Place] = []
        public var items: [MediaItem] = []
        public var overrides: [PlaceOverride] = []

        public init(
            id: String = UUID().uuidString,
            name: String,
            kind: PlaceKind = .spot,
            latitude: Double? = nil,
            longitude: Double? = nil,
            mapLink: String? = nil,
            parent: Place? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil
        ) {
            self.id = id
            self.name = name
            self.kindRaw = kind.rawValue
            self.latitude = latitude
            self.longitude = longitude
            self.mapLink = mapLink
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.parent = parent
        }

        public var kind: PlaceKind {
            get { PlaceKind(rawValue: kindRaw) ?? .spot }
            set { kindRaw = newValue.rawValue }
        }
    }

    @Model
    public final class PlaceOverride {
        public var id: String
        public var placeID: String?
        public var mediaID: String?
        public var accountID: String
        public var nameOverride: String?
        public var mapLinkOverride: String?
        public var latitude: Double?
        public var longitude: Double?
        public var updatedAt: Date
        public var updatedBy: String?
        @Relationship(inverse: \Place.overrides)
        public var place: Place?
        public var mediaItem: MediaItem?

        public init(
            id: String? = nil,
            placeID: String? = nil,
            mediaID: String? = nil,
            accountID: String = MomentsAccount.localID,
            nameOverride: String? = nil,
            mapLinkOverride: String? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            place: Place? = nil,
            mediaItem: MediaItem? = nil
        ) {
            let ownerID = mediaItem?.id ?? mediaID ?? place?.id ?? placeID ?? UUID().uuidString
            self.id = id ?? "\(ownerID):\(accountID)"
            self.placeID = place?.id ?? placeID
            self.mediaID = mediaItem?.id ?? mediaID
            self.accountID = accountID
            self.nameOverride = nameOverride
            self.mapLinkOverride = mapLinkOverride
            self.latitude = latitude
            self.longitude = longitude
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.place = place
            self.mediaItem = mediaItem
        }

        public var coordinate: (latitude: Double, longitude: Double)? {
            guard let latitude, let longitude else { return nil }
            return (latitude, longitude)
        }
    }

    @Model
    public final class Trip {
        public var id: String
        public var name: String
        public var startDate: Date?
        public var endDate: Date?
        public var updatedAt: Date
        public var updatedBy: String?
        public var overrideName: String?
        public var mergeOverrideID: String?
        public var splitOverrideDayKeys: String?
        public var suggestionStatusRaw: String?
        public var confirmedAt: Date?
        public var items: [MediaItem] = []

        public init(
            id: String = UUID().uuidString,
            name: String,
            startDate: Date? = nil,
            endDate: Date? = nil,
            items: [MediaItem] = [],
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            overrideName: String? = nil,
            mergeOverrideID: String? = nil,
            splitOverrideDayKeys: String? = nil,
            suggestionStatusRaw: String? = nil,
            confirmedAt: Date? = nil
        ) {
            self.id = id
            self.name = name
            self.startDate = startDate
            self.endDate = endDate
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.overrideName = overrideName
            self.mergeOverrideID = mergeOverrideID
            self.splitOverrideDayKeys = splitOverrideDayKeys
            self.suggestionStatusRaw = suggestionStatusRaw
            self.confirmedAt = confirmedAt
            self.items = items
        }

        /// SwiftData does not persist to-many order, so trips are ordered by capture date.
        public var orderedItems: [MediaItem] {
            items.sorted { ($0.captureDate ?? .distantPast, $0.id) < ($1.captureDate ?? .distantPast, $1.id) }
        }

        public var effectiveName: String {
            let value = overrideName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value! : name
        }

        public var isSuggestion: Bool {
            suggestionStatusRaw == "suggestion"
        }
    }

    @Model
    public final class Tag {
        public var id: String
        public var normalizedName: String
        public var displayName: String
        public var updatedAt: Date
        public var updatedBy: String?
        public var mediaTags: [MediaTag] = []

        public init(id: String = UUID().uuidString, displayName: String, normalizedName: String? = nil, updatedAt: Date = .now, updatedBy: String? = nil) {
            self.id = id
            self.displayName = displayName
            self.normalizedName = normalizedName ?? Self.normalize(displayName)
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
        }

        /// Compatibility spelling for the pre-sharing UI.
        public convenience init(name: String) {
            self.init(displayName: name)
        }

        public var name: String {
            get { displayName }
            set {
                displayName = newValue
                normalizedName = Self.normalize(newValue)
                updatedAt = .now
            }
        }

        public var items: [MediaItem] {
            mediaTags.compactMap(\.mediaItem)
        }

        public static func normalize(_ name: String) -> String {
            name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
                .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }

        public static func lookup(normalizedName: String, in context: ModelContext) throws -> Tag? {
            let normalized = normalize(normalizedName)
            return try context.fetch(FetchDescriptor<Tag>())
                .first(where: { $0.normalizedName == normalized })
        }

        public static func lookupOrCreate(displayName: String, in context: ModelContext) throws -> Tag {
            if let existing = try lookup(normalizedName: displayName, in: context) {
                return existing
            }
            let tag = Tag(displayName: displayName)
            context.insert(tag)
            return tag
        }

        public static func findOrCreate(name: String, in context: ModelContext) throws -> Tag {
            try lookupOrCreate(displayName: name, in: context)
        }
    }

    @Model
    public final class MediaTag {
        public var id: String
        public var mediaID: String?
        public var tagID: String?
        public var updatedAt: Date
        public var updatedBy: String?
        public var mediaItem: MediaItem?
        @Relationship(inverse: \Tag.mediaTags)
        public var tag: Tag?

        public init(
            id: String = UUID().uuidString,
            mediaID: String? = nil,
            tagID: String? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            mediaItem: MediaItem? = nil,
            tag: Tag? = nil
        ) {
            self.id = id
            self.mediaID = mediaItem?.id ?? mediaID
            self.tagID = tag?.id ?? tagID
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.mediaItem = mediaItem
            self.tag = tag
        }
    }

    @Model
    public final class Favorite {
        public var id: String
        public var mediaID: String?
        public var accountID: String
        public var isFavorite: Bool
        public var changedAt: Date
        public var mediaItem: MediaItem?

        public init(
            id: String? = nil,
            mediaID: String? = nil,
            accountID: String = MomentsAccount.localID,
            isFavorite: Bool,
            changedAt: Date = .now,
            mediaItem: MediaItem? = nil
        ) {
            let resolvedMediaID = mediaItem?.id ?? mediaID ?? UUID().uuidString
            self.id = id ?? Self.recordID(mediaID: resolvedMediaID, accountID: accountID)
            self.mediaID = mediaItem?.id ?? mediaID
            self.accountID = accountID
            self.isFavorite = isFavorite
            self.changedAt = changedAt
            self.mediaItem = mediaItem
        }

        public static func recordID(mediaID: String, accountID: String) -> String {
            "\(mediaID):\(accountID)"
        }

        public static func lookup(mediaID: String, accountID: String, in context: ModelContext) throws -> Favorite? {
            let id = recordID(mediaID: mediaID, accountID: accountID)
            return try context.fetch(FetchDescriptor<Favorite>())
                .first(where: { $0.id == id })
        }
    }

    /// The Apple Photos schema: the V3 shape plus the Photos fields.

    @Model
    public final class UserGroup {
        public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
            case manual, smart
        }

        public var id: String
        public var name: String
        public var kindRaw: String
        public var rulesData: Data
        public var ownerAccountID: String
        public var createdAt: Date
        public var updatedAt: Date

        public init(
            id: String = UUID().uuidString,
            name: String,
            kind: Kind = .manual,
            rules: UserGroupRuleSet = UserGroupRuleSet(),
            ownerAccountID: String = MomentsAccount.localID,
            createdAt: Date = .now,
            updatedAt: Date = .now
        ) {
            self.id = id
            self.name = name
            self.kindRaw = kind.rawValue
            self.rulesData = (try? JSONEncoder().encode(rules)) ?? Data()
            self.ownerAccountID = ownerAccountID
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        public var kind: Kind {
            get { Kind(rawValue: kindRaw) ?? .manual }
            set { kindRaw = newValue.rawValue }
        }

        public var rules: UserGroupRuleSet {
            get { (try? JSONDecoder().decode(UserGroupRuleSet.self, from: rulesData)) ?? UserGroupRuleSet() }
            set { rulesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
        }
    }

    @Model
    public final class UserGroupItem {
        public var id: String
        public var groupID: String
        public var mediaID: String
        public var addedBy: String
        public var excluded: Bool
        public var addedAt: Date

        public init(
            id: String = UUID().uuidString,
            groupID: String,
            mediaID: String,
            addedBy: String = MomentsAccount.localID,
            excluded: Bool = false,
            addedAt: Date = .now
        ) {
            self.id = id
            self.groupID = groupID
            self.mediaID = mediaID
            self.addedBy = addedBy
            self.excluded = excluded
            self.addedAt = addedAt
        }
    }

    public static let models: [any PersistentModel.Type] = [
        SchemaV5.MediaItem.self,
        SchemaV5.Memory.self,
        SchemaV5.MemoryRevision.self,
        SchemaV5.Place.self,
        SchemaV5.PlaceOverride.self,
        SchemaV5.Trip.self,
        SchemaV5.Tag.self,
        SchemaV5.MediaTag.self,
        SchemaV5.Favorite.self,
        SchemaV5.UserGroup.self,
        SchemaV5.UserGroupItem.self
    ]
}


/// A locally named face group. Names and the associated observations remain in the local SwiftData store.
@Model
public final class Person {
    public var id: String
    public var name: String?
    public var hidden: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var ownerAccountID: String

    public init(
        id: String = UUID().uuidString,
        name: String? = nil,
        hidden: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        ownerAccountID: String = MomentsAccount.localID
    ) {
        self.id = id
        self.name = name
        self.hidden = hidden
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.ownerAccountID = ownerAccountID
    }
}

/// A detected and aligned face. The embedding and crop are deliberately opaque local data.
@Model
public final class FaceObservation {
    public var id: String
    public var mediaID: String
    public var rectX: Double
    public var rectY: Double
    public var rectWidth: Double
    public var rectHeight: Double
    @Attribute(.externalStorage)
    public var embedding: Data
    @Attribute(.externalStorage)
    public var cropData: Data
    public var quality: Double
    public var personID: String?
    public var clusterID: String?
    public var confirmed: Bool
    /// Comma-separated local person IDs that the user rejected for this face.
    /// The value never leaves the local SwiftData store.
    public var rejectedPersonIDs: String
    /// "user" for an explicit confirmation, "auto" for a machine suggestion.
    public var assignmentSource: String
    public var createdAt: Date
    /// Changes whenever a user-facing assignment or rejection is edited.
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        mediaID: String,
        rect: (x: Double, y: Double, w: Double, h: Double),
        embedding: Data,
        cropData: Data,
        quality: Double,
        personID: String? = nil,
        clusterID: String? = nil,
        confirmed: Bool = false,
        rejectedPersonIDs: String = "",
        assignmentSource: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.mediaID = mediaID
        self.rectX = rect.x
        self.rectY = rect.y
        self.rectWidth = rect.w
        self.rectHeight = rect.h
        self.embedding = embedding
        self.cropData = cropData
        self.quality = quality
        self.personID = personID
        self.clusterID = clusterID
        self.confirmed = confirmed
        self.rejectedPersonIDs = rejectedPersonIDs
        self.assignmentSource = assignmentSource ?? (confirmed ? "user" : "auto")
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var rejectedPersonIDSet: Set<String> {
        Set(rejectedPersonIDs.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    public func reject(personID: String) {
        var ids = rejectedPersonIDSet
        ids.insert(personID)
        rejectedPersonIDs = ids.sorted().joined(separator: ",")
        if self.personID == personID {
            self.personID = nil
            self.confirmed = false
            self.assignmentSource = "auto"
        }
        updatedAt = .now
    }

    public func canAssign(to personID: String) -> Bool {
        !rejectedPersonIDSet.contains(personID)
    }

    public var rect: (x: Double, y: Double, w: Double, h: Double) {
        get { (rectX, rectY, rectWidth, rectHeight) }
        set {
            rectX = newValue.x
            rectY = newValue.y
            rectWidth = newValue.w
            rectHeight = newValue.h
        }
    }
}

/// Marker for a media item that has completed face scanning, including a scan
/// that found zero faces. The marker keeps scans resumable without changing the
/// frozen MediaItem schema.
@Model
public final class FaceScanRecord {
    @Attribute(.unique) public var id: String
    public var scannedAt: Date
    public var version: Int

    public init(id: String, scannedAt: Date = .now, version: Int = 1) {
        self.id = id
        self.scannedAt = scannedAt
        self.version = version
    }
}

/// Frozen V6 schema: V5 plus the local People entities. Nested copies keep
/// the exact V6 shape for migration; the live entities are the top-level classes.
public enum SchemaV6: VersionedSchema {
    public static let versionIdentifier = Schema.Version(6, 0, 0)

    @Model
    public final class MediaItem {
        public var id: String
        public var captureDate: Date?
        public var latitude: Double?
        public var longitude: Double?
        public var kindRaw: String
        public var width: Int
        public var height: Int
        public var isScreenshot: Bool
        public var sourceRaw: String
        public var title: String
        public var tripID: String?
        public var updatedAt: Date
        public var updatedBy: String?

        // Folder import keeps originals in place. The bookmark is the only path
        // reference persisted by the app; the hash makes re-imports idempotent and
        // lets callers verify that the source was not changed by Moments.
        public var originalBookmarkData: Data?
        public var originalFileName: String?
        public var originalContentHash: String?
        public var captureDateSourceRaw: String?
        public var localTimeZoneOffsetMinutes: Int?
        public var localDayKey: String?
        public var duration: Double?
        public var importReviewReasonsRaw: String?
        public var importedAt: Date?
        public var originalCaptureDateUTC: Date?
        public var captureDateHintUTC: Date?
        public var userCorrectedCaptureDateUTC: Date?
        public var timeZoneIdentifier: String?
        public var timeConfidenceRaw: String?
        public var sourceReferencesRaw: String?
        public var pairedVideoContentHash: String?
        public var pairedVideoBookmarkData: Data?
        /// Apple Photos references. Originals stay in Photos; these values are
        /// stable identifiers only and are optional for folder/demo media.
        public var photosLocalIdentifier: String?
        public var photosCloudIdentifier: String?
        public var photosAlbumIdentifiersRaw: String?
        public var photosMediaSubtypesRaw: Int?
        public var photosAssetMissing: Bool?
        public var perceptualHash: String?
        public var reviewDecisionRaw: String?
        public var reviewOverridePlaceID: String?
        public var reviewOverrideDateUTC: Date?
        public var reviewMemoryDraft: String?

        @Relationship(inverse: \Place.items)
        public var place: Place?
        @Relationship(inverse: \Trip.items)
        public var trip: Trip?
        @Relationship(deleteRule: .cascade, inverse: \Memory.mediaItem)
        public var memories: [Memory] = []
        @Relationship(inverse: \MediaTag.mediaItem)
        public var mediaTags: [MediaTag] = []
        @Relationship(inverse: \Favorite.mediaItem)
        public var favorites: [Favorite] = []
        @Relationship(inverse: \PlaceOverride.mediaItem)
        public var placeOverrides: [PlaceOverride] = []

        public init(
            id: String = UUID().uuidString,
            captureDate: Date? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil,
            kind: MediaKind = .photo,
            width: Int = 0,
            height: Int = 0,
            isScreenshot: Bool = false,
            source: MediaSource = .file,
            title: String = "",
            tripID: String? = nil,
            tripKey: String? = nil,
            place: Place? = nil,
            trip: Trip? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            originalBookmarkData: Data? = nil,
            originalFileName: String? = nil,
            originalContentHash: String? = nil,
            captureDateSourceRaw: String? = nil,
            localTimeZoneOffsetMinutes: Int? = nil,
            localDayKey: String? = nil,
            duration: Double? = nil,
            importReviewReasonsRaw: String? = nil,
            importedAt: Date? = nil,
            originalCaptureDateUTC: Date? = nil,
            captureDateHintUTC: Date? = nil,
            userCorrectedCaptureDateUTC: Date? = nil,
            timeZoneIdentifier: String? = nil,
            timeConfidenceRaw: String? = nil,
            sourceReferencesRaw: String? = nil,
            pairedVideoContentHash: String? = nil,
            pairedVideoBookmarkData: Data? = nil,
            photosLocalIdentifier: String? = nil,
            photosCloudIdentifier: String? = nil,
            photosAlbumIdentifiersRaw: String? = nil,
            photosMediaSubtypesRaw: Int? = nil,
            photosAssetMissing: Bool? = nil,
            perceptualHash: String? = nil,
            reviewDecisionRaw: String? = nil,
            reviewOverridePlaceID: String? = nil,
            reviewOverrideDateUTC: Date? = nil,
            reviewMemoryDraft: String? = nil
        ) {
            self.id = id
            self.captureDate = captureDate
            self.latitude = latitude
            self.longitude = longitude
            self.kindRaw = kind.rawValue
            self.width = width
            self.height = height
            self.isScreenshot = isScreenshot
            self.sourceRaw = source.rawValue
            self.title = title
            self.tripID = trip?.id ?? tripID ?? tripKey
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.originalBookmarkData = originalBookmarkData
            self.originalFileName = originalFileName
            self.originalContentHash = originalContentHash
            self.captureDateSourceRaw = captureDateSourceRaw
            self.localTimeZoneOffsetMinutes = localTimeZoneOffsetMinutes
            self.localDayKey = localDayKey
            self.duration = duration
            self.importReviewReasonsRaw = importReviewReasonsRaw
            self.importedAt = importedAt
            self.originalCaptureDateUTC = originalCaptureDateUTC
            self.captureDateHintUTC = captureDateHintUTC
            self.userCorrectedCaptureDateUTC = userCorrectedCaptureDateUTC
            self.timeZoneIdentifier = timeZoneIdentifier
            self.timeConfidenceRaw = timeConfidenceRaw
            self.sourceReferencesRaw = sourceReferencesRaw
            self.pairedVideoContentHash = pairedVideoContentHash
            self.pairedVideoBookmarkData = pairedVideoBookmarkData
            self.photosLocalIdentifier = photosLocalIdentifier
            self.photosCloudIdentifier = photosCloudIdentifier
            self.photosAlbumIdentifiersRaw = photosAlbumIdentifiersRaw
            self.photosMediaSubtypesRaw = photosMediaSubtypesRaw
            self.photosAssetMissing = photosAssetMissing
            self.perceptualHash = perceptualHash
            self.reviewDecisionRaw = reviewDecisionRaw
            self.reviewOverridePlaceID = reviewOverridePlaceID
            self.reviewOverrideDateUTC = reviewOverrideDateUTC
            self.reviewMemoryDraft = reviewMemoryDraft
            self.place = place
            self.trip = trip
        }

        public var kind: MediaKind {
            get { MediaKind(rawValue: kindRaw) ?? .photo }
            set { kindRaw = newValue.rawValue }
        }

        public var source: MediaSource {
            get { MediaSource(rawValue: sourceRaw) ?? .file }
            set { sourceRaw = newValue.rawValue }
        }

        public var effectiveCaptureDate: Date? {
            userCorrectedCaptureDateUTC ?? captureDate
        }

        /// Compatibility spelling used by the current Library and Timeline code.
        public var tripKey: String? {
            get { tripID }
            set { tripID = newValue }
        }

        public var importDecision: ImportReviewDecision {
            get { ImportReviewDecision(rawValue: reviewDecisionRaw ?? "") ?? .pending }
            set { reviewDecisionRaw = newValue.rawValue }
        }

        public var timeConfidence: ImportTimeConfidence {
            ImportTimeConfidence(rawValue: timeConfidenceRaw ?? "") ?? (captureDate == nil ? .missing : .exact)
        }

        public var tags: [Tag] {
            mediaTags.compactMap(\.tag)
        }

        public var isFavorite: Bool {
            favorites.first(where: { $0.accountID == MomentsAccount.localID })?.isFavorite ?? false
        }

        public var localPlaceOverride: PlaceOverride? {
            placeOverrides.first(where: { $0.accountID == MomentsAccount.localID })
        }

        public var placeOverrideName: String? { localPlaceOverride?.nameOverride }
        public var placeOverrideMapLink: String? { localPlaceOverride?.mapLinkOverride }
        public var placeOverrideLatitude: Double? { localPlaceOverride?.latitude }
        public var placeOverrideLongitude: Double? { localPlaceOverride?.longitude }

        /// The place name shown by the app, preferring this person's override.
        public var effectivePlaceName: String? {
            let override = placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return override?.isEmpty == false ? override : place?.name
        }

        /// The map link shown by the app, preferring this person's override.
        public var effectiveMapLink: String? {
            let override = placeOverrideMapLink?.trimmingCharacters(in: .whitespacesAndNewlines)
            return override?.isEmpty == false ? override : place?.mapLink
        }

        /// The coordinate shown by the app, preferring an override and then the canonical place/GPS.
        public var effectiveCoordinate: (latitude: Double, longitude: Double)? {
            if let latitude = placeOverrideLatitude, let longitude = placeOverrideLongitude {
                return (latitude, longitude)
            }
            if let latitude = place?.latitude, let longitude = place?.longitude {
                return (latitude, longitude)
            }
            if let latitude, let longitude {
                return (latitude, longitude)
            }
            return nil
        }

        public func setFavorite(_ value: Bool, accountID: String = MomentsAccount.localID, context: ModelContext) {
            let existingFavorite: Favorite?
            do {
                existingFavorite = try Favorite.lookup(mediaID: id, accountID: accountID, in: context)
            } catch {
                existingFavorite = nil
            }
            if let favorite = existingFavorite {
                favorite.isFavorite = value
                favorite.changedAt = .now
            } else {
                let favorite = Favorite(mediaID: id, accountID: accountID, isFavorite: value, mediaItem: self)
                context.insert(favorite)
            }
            updatedAt = .now
            updatedBy = accountID
        }

        public func addTag(_ tag: Tag, context: ModelContext) {
            guard !mediaTags.contains(where: { $0.tagID == tag.id }) else { return }
            let join = MediaTag(id: "\(id):\(tag.id)", mediaID: id, tagID: tag.id, mediaItem: self, tag: tag)
            context.insert(join)
        }

        public func removeTag(_ tag: Tag, context: ModelContext) {
            guard let join = mediaTags.first(where: { $0.tagID == tag.id }) else { return }
            context.delete(join)
        }
    }

    @Model
    public final class Memory {
        public var id: String
        public var mediaID: String?
        public var text: String
        public var authorRaw: String
        public var authorAccountID: String?
        public var createdAt: Date
        public var updatedAt: Date
        public var revision: Int
        public var updatedBy: String?
        public var mediaItem: MediaItem?
        @Relationship(deleteRule: .cascade, inverse: \MemoryRevision.memory)
        public var revisions: [MemoryRevision] = []

        public init(
            id: String = UUID().uuidString,
            text: String,
            author: MemoryAuthor = .me,
            authorAccountID: String? = nil,
            createdAt: Date = .now,
            updatedAt: Date = .now,
            revision: Int = 1,
            updatedBy: String? = nil,
            mediaItem: MediaItem? = nil,
            mediaID: String? = nil
        ) {
            self.id = id
            self.mediaID = mediaItem?.id ?? mediaID
            self.text = text
            self.authorRaw = author.rawValue
            self.authorAccountID = authorAccountID
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.revision = revision
            self.updatedBy = updatedBy
            self.mediaItem = mediaItem
        }

        public var author: MemoryAuthor {
            get { MemoryAuthor(rawValue: authorRaw) ?? .me }
            set { authorRaw = newValue.rawValue }
        }
    }

    @Model
    public final class MemoryRevision {
        public var id: String
        public var memoryID: String?
        public var text: String
        public var editedBy: String?
        public var editedAt: Date
        public var baseRevision: Int
        public var reason: String?
        public var memory: Memory?

        public init(
            id: String = UUID().uuidString,
            memoryID: String? = nil,
            text: String,
            editedBy: String? = nil,
            editedAt: Date = .now,
            baseRevision: Int,
            reason: String? = nil,
            memory: Memory? = nil
        ) {
            self.id = id
            self.memoryID = memory?.id ?? memoryID
            self.text = text
            self.editedBy = editedBy
            self.editedAt = editedAt
            self.baseRevision = baseRevision
            self.reason = reason
            self.memory = memory
        }
    }

    @Model
    public final class Place {
        public var id: String
        public var name: String
        public var kindRaw: String
        public var latitude: Double?
        public var longitude: Double?
        public var mapLink: String?
        public var updatedAt: Date
        public var updatedBy: String?
        public var parent: Place?
        @Relationship(inverse: \Place.parent)
        public var children: [Place] = []
        public var items: [MediaItem] = []
        public var overrides: [PlaceOverride] = []

        public init(
            id: String = UUID().uuidString,
            name: String,
            kind: PlaceKind = .spot,
            latitude: Double? = nil,
            longitude: Double? = nil,
            mapLink: String? = nil,
            parent: Place? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil
        ) {
            self.id = id
            self.name = name
            self.kindRaw = kind.rawValue
            self.latitude = latitude
            self.longitude = longitude
            self.mapLink = mapLink
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.parent = parent
        }

        public var kind: PlaceKind {
            get { PlaceKind(rawValue: kindRaw) ?? .spot }
            set { kindRaw = newValue.rawValue }
        }
    }

    @Model
    public final class PlaceOverride {
        public var id: String
        public var placeID: String?
        public var mediaID: String?
        public var accountID: String
        public var nameOverride: String?
        public var mapLinkOverride: String?
        public var latitude: Double?
        public var longitude: Double?
        public var updatedAt: Date
        public var updatedBy: String?
        @Relationship(inverse: \Place.overrides)
        public var place: Place?
        public var mediaItem: MediaItem?

        public init(
            id: String? = nil,
            placeID: String? = nil,
            mediaID: String? = nil,
            accountID: String = MomentsAccount.localID,
            nameOverride: String? = nil,
            mapLinkOverride: String? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            place: Place? = nil,
            mediaItem: MediaItem? = nil
        ) {
            let ownerID = mediaItem?.id ?? mediaID ?? place?.id ?? placeID ?? UUID().uuidString
            self.id = id ?? "\(ownerID):\(accountID)"
            self.placeID = place?.id ?? placeID
            self.mediaID = mediaItem?.id ?? mediaID
            self.accountID = accountID
            self.nameOverride = nameOverride
            self.mapLinkOverride = mapLinkOverride
            self.latitude = latitude
            self.longitude = longitude
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.place = place
            self.mediaItem = mediaItem
        }

        public var coordinate: (latitude: Double, longitude: Double)? {
            guard let latitude, let longitude else { return nil }
            return (latitude, longitude)
        }
    }

    @Model
    public final class Trip {
        public var id: String
        public var name: String
        public var startDate: Date?
        public var endDate: Date?
        public var updatedAt: Date
        public var updatedBy: String?
        public var overrideName: String?
        public var mergeOverrideID: String?
        public var splitOverrideDayKeys: String?
        public var suggestionStatusRaw: String?
        public var confirmedAt: Date?
        public var items: [MediaItem] = []

        public init(
            id: String = UUID().uuidString,
            name: String,
            startDate: Date? = nil,
            endDate: Date? = nil,
            items: [MediaItem] = [],
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            overrideName: String? = nil,
            mergeOverrideID: String? = nil,
            splitOverrideDayKeys: String? = nil,
            suggestionStatusRaw: String? = nil,
            confirmedAt: Date? = nil
        ) {
            self.id = id
            self.name = name
            self.startDate = startDate
            self.endDate = endDate
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.overrideName = overrideName
            self.mergeOverrideID = mergeOverrideID
            self.splitOverrideDayKeys = splitOverrideDayKeys
            self.suggestionStatusRaw = suggestionStatusRaw
            self.confirmedAt = confirmedAt
            self.items = items
        }

        /// SwiftData does not persist to-many order, so trips are ordered by capture date.
        public var orderedItems: [MediaItem] {
            items.sorted { ($0.captureDate ?? .distantPast, $0.id) < ($1.captureDate ?? .distantPast, $1.id) }
        }

        public var effectiveName: String {
            let value = overrideName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value! : name
        }

        public var isSuggestion: Bool {
            suggestionStatusRaw == "suggestion"
        }
    }

    @Model
    public final class Tag {
        public var id: String
        public var normalizedName: String
        public var displayName: String
        public var updatedAt: Date
        public var updatedBy: String?
        public var mediaTags: [MediaTag] = []

        public init(id: String = UUID().uuidString, displayName: String, normalizedName: String? = nil, updatedAt: Date = .now, updatedBy: String? = nil) {
            self.id = id
            self.displayName = displayName
            self.normalizedName = normalizedName ?? Self.normalize(displayName)
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
        }

        /// Compatibility spelling for the pre-sharing UI.
        public convenience init(name: String) {
            self.init(displayName: name)
        }

        public var name: String {
            get { displayName }
            set {
                displayName = newValue
                normalizedName = Self.normalize(newValue)
                updatedAt = .now
            }
        }

        public var items: [MediaItem] {
            mediaTags.compactMap(\.mediaItem)
        }

        public static func normalize(_ name: String) -> String {
            name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
                .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }

        public static func lookup(normalizedName: String, in context: ModelContext) throws -> Tag? {
            let normalized = normalize(normalizedName)
            return try context.fetch(FetchDescriptor<Tag>())
                .first(where: { $0.normalizedName == normalized })
        }

        public static func lookupOrCreate(displayName: String, in context: ModelContext) throws -> Tag {
            if let existing = try lookup(normalizedName: displayName, in: context) {
                return existing
            }
            let tag = Tag(displayName: displayName)
            context.insert(tag)
            return tag
        }

        public static func findOrCreate(name: String, in context: ModelContext) throws -> Tag {
            try lookupOrCreate(displayName: name, in: context)
        }
    }

    @Model
    public final class MediaTag {
        public var id: String
        public var mediaID: String?
        public var tagID: String?
        public var updatedAt: Date
        public var updatedBy: String?
        public var mediaItem: MediaItem?
        @Relationship(inverse: \Tag.mediaTags)
        public var tag: Tag?

        public init(
            id: String = UUID().uuidString,
            mediaID: String? = nil,
            tagID: String? = nil,
            updatedAt: Date = .now,
            updatedBy: String? = nil,
            mediaItem: MediaItem? = nil,
            tag: Tag? = nil
        ) {
            self.id = id
            self.mediaID = mediaItem?.id ?? mediaID
            self.tagID = tag?.id ?? tagID
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
            self.mediaItem = mediaItem
            self.tag = tag
        }
    }

    @Model
    public final class Favorite {
        public var id: String
        public var mediaID: String?
        public var accountID: String
        public var isFavorite: Bool
        public var changedAt: Date
        public var mediaItem: MediaItem?

        public init(
            id: String? = nil,
            mediaID: String? = nil,
            accountID: String = MomentsAccount.localID,
            isFavorite: Bool,
            changedAt: Date = .now,
            mediaItem: MediaItem? = nil
        ) {
            let resolvedMediaID = mediaItem?.id ?? mediaID ?? UUID().uuidString
            self.id = id ?? Self.recordID(mediaID: resolvedMediaID, accountID: accountID)
            self.mediaID = mediaItem?.id ?? mediaID
            self.accountID = accountID
            self.isFavorite = isFavorite
            self.changedAt = changedAt
            self.mediaItem = mediaItem
        }

        public static func recordID(mediaID: String, accountID: String) -> String {
            "\(mediaID):\(accountID)"
        }

        public static func lookup(mediaID: String, accountID: String, in context: ModelContext) throws -> Favorite? {
            let id = recordID(mediaID: mediaID, accountID: accountID)
            return try context.fetch(FetchDescriptor<Favorite>())
                .first(where: { $0.id == id })
        }
    }

    /// A persisted rule used by custom smart groups. The JSON payload is kept
    /// independent of SwiftData relationships so it can be shared and migrated
    /// without coupling groups to MediaItem.
    @Model
    public final class UserGroup {
        public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
            case manual, smart
        }

        public var id: String
        public var name: String
        public var kindRaw: String
        public var rulesData: Data
        public var ownerAccountID: String
        public var createdAt: Date
        public var updatedAt: Date

        public init(
            id: String = UUID().uuidString,
            name: String,
            kind: Kind = .manual,
            rules: UserGroupRuleSet = UserGroupRuleSet(),
            ownerAccountID: String = MomentsAccount.localID,
            createdAt: Date = .now,
            updatedAt: Date = .now
        ) {
            self.id = id
            self.name = name
            self.kindRaw = kind.rawValue
            self.rulesData = (try? JSONEncoder().encode(rules)) ?? Data()
            self.ownerAccountID = ownerAccountID
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        public var kind: Kind {
            get { Kind(rawValue: kindRaw) ?? .manual }
            set { kindRaw = newValue.rawValue }
        }

        public var rules: UserGroupRuleSet {
            get { (try? JSONDecoder().decode(UserGroupRuleSet.self, from: rulesData)) ?? UserGroupRuleSet() }
            set { rulesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
        }
    }

    @Model
    public final class UserGroupItem {
        public var id: String
        public var groupID: String
        public var mediaID: String
        public var addedBy: String
        public var excluded: Bool
        public var addedAt: Date

        public init(
            id: String = UUID().uuidString,
            groupID: String,
            mediaID: String,
            addedBy: String = MomentsAccount.localID,
            excluded: Bool = false,
            addedAt: Date = .now
        ) {
            self.id = id
            self.groupID = groupID
            self.mediaID = mediaID
            self.addedBy = addedBy
            self.excluded = excluded
            self.addedAt = addedAt
        }
    }

    /// A locally named face group. Names and the associated observations remain in the local SwiftData store.
    @Model
    public final class Person {
        public var id: String
        public var name: String?
        public var hidden: Bool
        public var createdAt: Date
        public var updatedAt: Date
        public var ownerAccountID: String

        public init(
            id: String = UUID().uuidString,
            name: String? = nil,
            hidden: Bool = false,
            createdAt: Date = .now,
            updatedAt: Date = .now,
            ownerAccountID: String = MomentsAccount.localID
        ) {
            self.id = id
            self.name = name
            self.hidden = hidden
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.ownerAccountID = ownerAccountID
        }
    }

    /// A detected and aligned face. The embedding and crop are deliberately opaque local data.
    @Model
    public final class FaceObservation {
        public var id: String
        public var mediaID: String
        public var rectX: Double
        public var rectY: Double
        public var rectWidth: Double
        public var rectHeight: Double
        @Attribute(.externalStorage)
        public var embedding: Data
        @Attribute(.externalStorage)
        public var cropData: Data
        public var quality: Double
        public var personID: String?
        public var clusterID: String?
        public var confirmed: Bool
        /// Comma-separated local person IDs that the user rejected for this face.
        /// The value never leaves the local SwiftData store.
        public var rejectedPersonIDs: String
        /// "user" for an explicit confirmation, "auto" for a machine suggestion.
        public var assignmentSource: String
        public var createdAt: Date
        /// Changes whenever a user-facing assignment or rejection is edited.
        public var updatedAt: Date

        public init(
            id: String = UUID().uuidString,
            mediaID: String,
            rect: (x: Double, y: Double, w: Double, h: Double),
            embedding: Data,
            cropData: Data,
            quality: Double,
            personID: String? = nil,
            clusterID: String? = nil,
            confirmed: Bool = false,
            rejectedPersonIDs: String = "",
            assignmentSource: String? = nil,
            createdAt: Date = .now,
            updatedAt: Date = .now
        ) {
            self.id = id
            self.mediaID = mediaID
            self.rectX = rect.x
            self.rectY = rect.y
            self.rectWidth = rect.w
            self.rectHeight = rect.h
            self.embedding = embedding
            self.cropData = cropData
            self.quality = quality
            self.personID = personID
            self.clusterID = clusterID
            self.confirmed = confirmed
            self.rejectedPersonIDs = rejectedPersonIDs
            self.assignmentSource = assignmentSource ?? (confirmed ? "user" : "auto")
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        public var rejectedPersonIDSet: Set<String> {
            Set(rejectedPersonIDs.split(separator: ",").map(String.init).filter { !$0.isEmpty })
        }

        public func reject(personID: String) {
            var ids = rejectedPersonIDSet
            ids.insert(personID)
            rejectedPersonIDs = ids.sorted().joined(separator: ",")
            if self.personID == personID {
                self.personID = nil
                self.confirmed = false
                self.assignmentSource = "auto"
            }
            updatedAt = .now
        }

        public func canAssign(to personID: String) -> Bool {
            !rejectedPersonIDSet.contains(personID)
        }

        public var rect: (x: Double, y: Double, w: Double, h: Double) {
            get { (rectX, rectY, rectWidth, rectHeight) }
            set {
                rectX = newValue.x
                rectY = newValue.y
                rectWidth = newValue.w
                rectHeight = newValue.h
            }
        }
    }

    /// Marker for a media item that has completed face scanning, including a scan
    /// that found zero faces. The marker keeps scans resumable without changing the
    /// frozen MediaItem schema.
    @Model
    public final class FaceScanRecord {
        @Attribute(.unique) public var id: String
        public var scannedAt: Date
        public var version: Int

        public init(id: String, scannedAt: Date = .now, version: Int = 1) {
            self.id = id
            self.scannedAt = scannedAt
            self.version = version
        }
    }

    public static let models: [any PersistentModel.Type] = [
        SchemaV6.MediaItem.self,
        SchemaV6.Memory.self,
        SchemaV6.MemoryRevision.self,
        SchemaV6.Place.self,
        SchemaV6.PlaceOverride.self,
        SchemaV6.Trip.self,
        SchemaV6.Tag.self,
        SchemaV6.MediaTag.self,
        SchemaV6.Favorite.self,
        SchemaV6.UserGroup.self,
        SchemaV6.UserGroupItem.self,
        SchemaV6.Person.self,
        SchemaV6.FaceObservation.self,
        SchemaV6.FaceScanRecord.self
    ]
}

/// Current live schema: V6 plus the photo-note entities, which refer to media,
/// places and trips by string IDs, so this stage is lightweight.
public enum SchemaV7: VersionedSchema {
    public static let versionIdentifier = Schema.Version(7, 0, 0)
    public static let models: [any PersistentModel.Type] = [
        MediaItem.self,
        Memory.self,
        MemoryRevision.self,
        Place.self,
        PlaceOverride.self,
        Trip.self,
        Tag.self,
        MediaTag.self,
        Favorite.self,
        UserGroup.self,
        UserGroupItem.self,
        Person.self,
        FaceObservation.self,
        FaceScanRecord.self,
        PhotoNote.self,
        PlaceNote.self,
        CollectionMemory.self
    ]
}

public enum MomentsMigrationPlan: SchemaMigrationPlan {
    public static let schemas: [any VersionedSchema.Type] = [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self, SchemaV5.self, SchemaV6.self, SchemaV7.self]

    /// Legacy v1 stores are handled by the launch-time safety gate below.
    /// Each post-v2 change is additive and therefore lightweight. V5 is a
    /// frozen nested schema; V6 opens the top-level live entities and adds the
    /// local person and face-observation tables.
    public static let stages: [MigrationStage] = [
        .lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self),
        .lightweight(fromVersion: SchemaV3.self, toVersion: SchemaV4.self),
        .lightweight(fromVersion: SchemaV4.self, toVersion: SchemaV5.self),
        .lightweight(fromVersion: SchemaV5.self, toVersion: SchemaV6.self),
        .lightweight(fromVersion: SchemaV6.self, toVersion: SchemaV7.self)
    ]
}

public enum MomentsStoreError: LocalizedError, Equatable {
    case protectedLegacyStore

    public var errorDescription: String? {
        switch self {
        case .protectedLegacyStore:
            return "A legacy Moments store contains non-demo data and was left untouched."
        }
    }
}

/// What happened when the store could not be opened and was moved aside.
public struct StoreRecovery: Equatable, Sendable {
    public let backupFolder: URL
}

/// Remembers a recovery until the user has seen the alert once.
public enum StoreRecoveryNotice {
    public static let defaultsKey = "moments.store.recoveredBackupPath"

    /// Pending backup paths, one per line, so a second recovery before the
    /// alert is dismissed doesn't hide the first.
    public static func record(_ recovery: StoreRecovery, in defaults: UserDefaults = .standard) {
        let existing = defaults.string(forKey: defaultsKey).map { $0.split(separator: "\n").map(String.init) } ?? []
        defaults.set((existing + [recovery.backupFolder.path]).joined(separator: "\n"), forKey: defaultsKey)
    }
}

public enum MomentsPersistence {
    /// Opens the store. If it cannot be opened *and* SQLite reports the file
    /// itself as corrupt or not a database, moves the whole store set into
    /// `Backups/<timestamp>/` next to it (never deleting or overwriting
    /// anything), records the notice, and opens a fresh, empty store at the
    /// normal path. Busy or locked databases, readable legacy stores and
    /// readable stores from other app versions are never moved: the original
    /// error is rethrown so a later fixed release can still open them.
    public static func openWithRecovery(
        url: URL? = nil,
        now: Date = .now,
        notices: UserDefaults = .standard
    ) throws -> (container: ModelContainer, recovery: StoreRecovery?) {
        let storeURL = try url ?? defaultStoreURL()
        do {
            return (try makeContainer(url: storeURL), nil)
        } catch {
            guard FileManager.default.fileExists(atPath: storeURL.path),
                  isProvablyCorrupt(storeURL),
                  let backupFolder = try? backUpStoreSet(at: storeURL, now: now) else { throw error }
            let recovery = StoreRecovery(backupFolder: backupFolder)
            // Record before reopening, so a failure below can't hide the backup.
            StoreRecoveryNotice.record(recovery, in: notices)
            return (try makeContainer(url: storeURL), recovery)
        }
    }

    /// True only when SQLite itself says the file is not a database or is
    /// corrupt. Any other outcome (busy, locked, can't open, healthy) is false.
    static func isProvablyCorrupt(_ storeURL: URL) -> Bool {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        if openResult == SQLITE_NOTADB || openResult == SQLITE_CORRUPT { return true }
        guard openResult == SQLITE_OK else { return false }
        sqlite3_busy_timeout(database, 2_000)
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, "PRAGMA quick_check(1)", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        if prepareResult == SQLITE_NOTADB || prepareResult == SQLITE_CORRUPT { return true }
        guard prepareResult == SQLITE_OK else { return false }
        let stepResult = sqlite3_step(statement)
        if stepResult == SQLITE_NOTADB || stepResult == SQLITE_CORRUPT { return true }
        guard stepResult == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: text) != "ok"
    }

    /// Moves Moments.store, its -wal/-shm companions and its external-storage
    /// folder (`.Moments_SUPPORT`) into a new timestamped backup folder.
    static func backUpStoreSet(at storeURL: URL, now: Date) throws -> URL {
        let fileManager = FileManager.default
        let folder = storeURL.deletingLastPathComponent()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        // Finder shows ":" as "/", so use dashes in the time.
        let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        let backupRoot = folder.appending(path: "Backups", directoryHint: .isDirectory)
        var backupFolder = backupRoot.appending(path: stamp, directoryHint: .isDirectory)
        var suffix = 2
        while fileManager.fileExists(atPath: backupFolder.path) {
            backupFolder = backupRoot.appending(path: "\(stamp)-\(suffix)", directoryHint: .isDirectory)
            suffix += 1
        }
        try fileManager.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        let storeName = storeURL.lastPathComponent
        let supportName = "." + storeURL.deletingPathExtension().lastPathComponent + "_SUPPORT"
        let members = try fileManager.contentsOfDirectory(atPath: folder.path).filter { name in
            name == storeName || name.hasPrefix(storeName + "-") || name == supportName
        }
        var moved: [(from: URL, to: URL)] = []
        do {
            for name in members {
                let source = folder.appending(path: name)
                let destination = backupFolder.appending(path: name)
                try fileManager.moveItem(at: source, to: destination)
                moved.append((source, destination))
            }
        } catch {
            // Put back whatever already moved, so the store set stays together.
            for item in moved.reversed() { try? fileManager.moveItem(at: item.to, to: item.from) }
            // Remove the backup folder only if it is empty: anything that could
            // not be moved back stays in it rather than being deleted.
            if (try? fileManager.contentsOfDirectory(atPath: backupFolder.path))?.isEmpty == true {
                try? fileManager.removeItem(at: backupFolder)
            }
            throw error
        }
        return backupFolder
    }

    public static func makeContainer(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        if inMemory {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            return try ModelContainer(
                for: Schema(versionedSchema: SchemaV7.self),
                migrationPlan: MomentsMigrationPlan.self,
                configurations: configuration
            )
        }

        let storeURL = try url ?? defaultStoreURL()
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: storeURL.path) {
            switch try inspectLegacyStore(at: storeURL) {
            case .demoOnly:
                try removeStoreFiles(at: storeURL)
            case .containsNonDemo:
                throw MomentsStoreError.protectedLegacyStore
            case .notLegacy:
                break
            }
        }

        let configuration = ModelConfiguration(
            "Moments",
            schema: Schema(versionedSchema: SchemaV7.self),
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: Schema(versionedSchema: SchemaV7.self),
            migrationPlan: MomentsMigrationPlan.self,
            configurations: configuration
        )
    }

    /// Creates a v1 store for migration tests without touching the real store.
    public static func makeV1Container(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        if inMemory {
            return try ModelContainer(
                for: Schema(versionedSchema: SchemaV1.self),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration("Moments-v1", schema: Schema(versionedSchema: SchemaV1.self), url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: Schema(versionedSchema: SchemaV1.self), configurations: configuration)
    }

    /// Creates a frozen v2 store for migration tests without opening the live
    /// V3 model. Production stores are opened through ``makeContainer``.
    public static func makeV2Container(url: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(
            "Moments-v2",
            schema: Schema(versionedSchema: SchemaV2.self),
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: Schema(versionedSchema: SchemaV2.self),
            configurations: configuration
        )
    }

    /// Creates a V3 store for the V3 -> V4 migration test without opening the
    /// live schema. Production stores are opened through ``makeContainer``.
    public static func makeV3Container(url: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(
            "Moments-v3",
            schema: Schema(versionedSchema: SchemaV3.self),
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: Schema(versionedSchema: SchemaV3.self),
            configurations: configuration
        )
    }

    /// Creates a frozen V4 store for the V4 -> V5 migration test without opening
    /// the live schema. Production stores are opened through ``makeContainer``.
    public static func makeV4Container(url: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(
            "Moments-v4",
            schema: Schema(versionedSchema: SchemaV4.self),
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: Schema(versionedSchema: SchemaV4.self),
            configurations: configuration
        )
    }

    /// Creates a frozen V5 store for the V5 -> V6 migration test without opening
    /// the live top-level entities.
    public static func makeV5Container(url: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(
            "Moments-v5",
            schema: Schema(versionedSchema: SchemaV5.self),
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: Schema(versionedSchema: SchemaV5.self),
            configurations: configuration
        )
    }

    /// Creates a frozen V6 store for the V6 -> V7 migration test without opening
    /// the live schema. Production stores are opened through ``makeContainer``.
    public static func makeV6Container(url: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(
            "Moments-v6",
            schema: Schema(versionedSchema: SchemaV6.self),
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: Schema(versionedSchema: SchemaV6.self),
            configurations: configuration
        )
    }

    /// '~/Library/Application Support/Moments/Moments.store', never a shared 'default.store'.
    public static func defaultStoreURL() throws -> URL {
        let folder = URL.applicationSupportDirectory.appending(path: "Moments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "Moments.store")
    }

    private enum LegacyInspection {
        case demoOnly
        case containsNonDemo
        case notLegacy
    }

    /// Reads the SQLite file directly and read-only. Opening it through SwiftData
    /// with the v1 schema would make Core Data try to migrate a current store in
    /// place, so the probe never goes through Core Data.
    /// v1 stores have a ZMEDIAITEM table but no ZFAVORITE table (added in v2).
    private static func inspectLegacyStore(at url: URL) throws -> LegacyInspection {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            // An existing store we cannot even open is treated as precious, never migrated.
            return .containsNonDemo
        }
        defer { sqlite3_close(database) }
        // Another connection may still be checkpointing; wait briefly instead of failing.
        sqlite3_busy_timeout(database, 2_000)

        // nil = the question could not be answered (busy, corrupt, unreadable).
        func tableExists(_ name: String) -> Bool? {
            scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(name)'").map { $0 > 0 }
        }
        func scalar(_ sql: String) -> Int? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int64(statement, 0))
        }

        // Fail safe: if the probe cannot tell, treat the store as precious rather than
        // letting SwiftData migrate (and possibly rewrite) a store with real data.
        guard let hasMedia = tableExists("ZMEDIAITEM"), let hasFavorite = tableExists("ZFAVORITE") else {
            return .containsNonDemo
        }
        guard hasMedia, !hasFavorite else { return .notLegacy }
        guard let nonDemo = scalar("SELECT COUNT(*) FROM ZMEDIAITEM WHERE ZSOURCERAW IS NOT 'demo'") else {
            // Unreadable legacy store: treat as precious, never delete it.
            return .containsNonDemo
        }
        return nonDemo == 0 ? .demoOnly : .containsNonDemo
    }

    private static func removeStoreFiles(at url: URL) throws {
        let fileManager = FileManager.default
        let sidecars = [
            url,
            URL(fileURLWithPath: url.path + "-shm"),
            URL(fileURLWithPath: url.path + "-wal")
        ]
        for candidate in sidecars where fileManager.fileExists(atPath: candidate.path) {
            try fileManager.removeItem(at: candidate)
        }
    }
}


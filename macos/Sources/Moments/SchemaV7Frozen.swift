import Foundation
import SwiftData

/// Frozen V7 schema: the shape that shipped before media could be moved to
/// Recently Deleted. These nested copies keep the exact V7 entities for
/// migration and tests; the live entities are the top-level classes.
extension SchemaV7 {
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
            /// `chapter`: a stretch of time on the Chapters page (an event, a
            /// celebration, a period); its details live in `rulesData` as
            /// `ChapterInfo` and its photos in `UserGroupItem`. Not a "My groups" entry.
            /// `stack`: what someone changed about a burst of similar photos (its
            /// cover, unstacked, photos taken out), as a `StackDecision` in
            /// `rulesData`. Not a "My groups" entry either; see `PhotoStackModel`.
            case manual, smart, chapter, stack
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

    /// What a person typed on the ruled line under one photo. The original words
    /// are always kept; the AI's suggestions and what was written from them are
    /// stored next to them so nothing changes without the person's say-so and
    /// every applied change can be undone.
    @Model
    public final class PhotoNote {
        public var id: String
        public var mediaID: String
        public var authorAccountID: String
        public var text: String
        public var createdAt: Date
        public var updatedAt: Date
        public var statusRaw: String
        public var suggestionsData: Data?
        /// Which model organized the note, shown next to the suggestions.
        public var organizerLabel: String?
        /// Why organizing did not happen or failed, in the person's language.
        public var failureReason: String?
        /// A ``PhotoNoteUndoRecord`` describing every write made from this note.
        public var undoData: Data?

        public init(
            id: String = UUID().uuidString,
            mediaID: String,
            authorAccountID: String = MomentsAccount.localID,
            text: String,
            createdAt: Date = .now,
            status: PhotoNoteStatus = .organizing
        ) {
            self.id = id
            self.mediaID = mediaID
            self.authorAccountID = authorAccountID
            self.text = text
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.statusRaw = status.rawValue
        }

        public var status: PhotoNoteStatus {
            get { PhotoNoteStatus(rawValue: statusRaw) ?? .waiting }
            set { statusRaw = newValue.rawValue }
        }

        public var suggestions: [NoteSuggestion] {
            get { suggestionsData.flatMap { try? JSONDecoder().decode([NoteSuggestion].self, from: $0) } ?? [] }
            set { suggestionsData = try? JSONEncoder().encode(newValue) }
        }

        public var undoRecord: PhotoNoteUndoRecord {
            get { undoData.flatMap { try? JSONDecoder().decode(PhotoNoteUndoRecord.self, from: $0) } ?? PhotoNoteUndoRecord() }
            set { undoData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
        }
    }

    /// A description of a place, written from a note. Keyed by the normalized
    /// place name so it follows corrections made by name.
    @Model
    public final class PlaceNote {
        public var id: String
        public var placeKey: String
        public var placeName: String
        public var text: String
        public var authorAccountID: String
        public var updatedAt: Date
        public var sourceNoteID: String?

        public init(
            id: String = UUID().uuidString,
            placeName: String,
            text: String,
            authorAccountID: String = MomentsAccount.localID,
            updatedAt: Date = .now,
            sourceNoteID: String? = nil
        ) {
            self.id = id
            self.placeKey = Self.key(for: placeName)
            self.placeName = placeName
            self.text = text
            self.authorAccountID = authorAccountID
            self.updatedAt = updatedAt
            self.sourceNoteID = sourceNoteID
        }

        public static func key(for placeName: String) -> String {
            placeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    /// A memory about a whole day or a whole trip rather than one photo.
    @Model
    public final class CollectionMemory {
        public var id: String
        public var scopeRaw: String
        /// `yyyy-MM-dd` for a day, the trip ID for a trip.
        public var scopeKey: String
        public var text: String
        public var authorAccountID: String
        public var createdAt: Date
        public var updatedAt: Date
        public var sourceNoteID: String?

        public init(
            id: String = UUID().uuidString,
            scope: NoteMemoryScope,
            scopeKey: String,
            text: String,
            authorAccountID: String = MomentsAccount.localID,
            createdAt: Date = .now,
            sourceNoteID: String? = nil
        ) {
            self.id = id
            self.scopeRaw = scope.rawValue
            self.scopeKey = scopeKey
            self.text = text
            self.authorAccountID = authorAccountID
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.sourceNoteID = sourceNoteID
        }

        public var scope: NoteMemoryScope {
            NoteMemoryScope(rawValue: scopeRaw) ?? .day
        }
    }
}

import Foundation

public enum SyncFieldKind: String, Sendable, Codable, Equatable {
    case string, int, double, bool, date, data, reference, asset
}

/// How a field behaves when two versions of a record meet.
public enum SyncFieldMerge: Sendable, Equatable {
    /// Each side may change it; when both did, the later change wins.
    case latestWins
    /// Set once when the record is created (an author, a creation date).
    /// The server's value is kept.
    case immutable
    /// The record's change time: the merged record takes the later one.
    case stamp
    /// A counter that only grows (a memory's revision number).
    case maximum
}

public struct SyncFieldSpec: Sendable, Equatable {
    public let name: String
    public let kind: SyncFieldKind
    public let merge: SyncFieldMerge
    /// The record type a `.reference` field points at.
    public let target: SyncRecordType?
    /// The field holds an account ID, so it is translated between `local-me`
    /// and the iCloud user record name.
    public let isAccount: Bool
    /// The field is long text a person wrote. When both sides changed it, the
    /// losing words are kept as a ``SyncRecordType/memoryRevision``.
    public let isAuthoredText: Bool
    /// A nil account here means "this device's person" (records made before
    /// sharing existed), so it goes out as the current account.
    public let nilMeansLocal: Bool

    init(
        _ name: String,
        _ kind: SyncFieldKind,
        _ merge: SyncFieldMerge = .latestWins,
        target: SyncRecordType? = nil,
        account: Bool = false,
        text: Bool = false,
        nilMeansLocal: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.merge = merge
        self.target = target
        self.isAccount = account
        self.isAuthoredText = text
        self.nilMeansLocal = nilMeansLocal
    }
}

/// Who may change a record.
public enum SyncOwnership: Sendable, Equatable {
    /// Both people may edit (trips, photos, places, tags, chapters).
    case shared
    /// One record per person; only that person writes it (favorites,
    /// personal place names). The named field holds the account.
    case perAccount(field: String)
    /// Only the author edits it (memories and notes). The named field holds
    /// the author.
    case authored(field: String)
    /// Never changes after it is written (kept revisions, previews).
    case appendOnly
}

public struct SyncTypeSpec: Sendable {
    public let fields: [SyncFieldSpec]
    public let ownership: SyncOwnership
    public let stampField: String
    public let editorField: String?

    public func field(_ name: String) -> SyncFieldSpec? {
        fields.first { $0.name == name }
    }

    public var fieldNames: Set<String> { Set(fields.map(\.name)) }

    public var references: [SyncFieldSpec] { fields.filter { $0.kind == .reference } }

    public var accountFields: [SyncFieldSpec] { fields.filter(\.isAccount) }
}

/// Every record type that leaves the device. Anything not listed here (people,
/// faces, face scans, import sources) never syncs: face data stays on the Mac
/// that computed it.
public enum SyncRecordType: String, CaseIterable, Sendable, Codable {
    case place = "Place"
    case tag = "Tag"
    case trip = "Trip"
    case mediaItem = "MediaItem"
    case previewAsset = "PreviewAsset"
    case memory = "Memory"
    case memoryRevision = "MemoryRevision"
    case mediaTag = "MediaTag"
    case favorite = "Favorite"
    case placeOverride = "PlaceOverride"
    case userGroup = "UserGroup"
    case userGroupItem = "UserGroupItem"
    case photoNote = "PhotoNote"
    case placeNote = "PlaceNote"
    case collectionMemory = "CollectionMemory"
    case comment = "Comment"

    /// Parents go up before children so a partner never receives a child
    /// whose parent is still missing for long; deletes go the other way.
    public var uploadRank: Int {
        switch self {
        case .place, .tag, .userGroup: return 0
        case .trip: return 1
        case .mediaItem: return 2
        case .previewAsset, .memory, .mediaTag, .favorite, .placeOverride, .userGroupItem, .photoNote: return 3
        case .memoryRevision, .placeNote, .collectionMemory, .comment: return 4
        }
    }

    public var spec: SyncTypeSpec { SyncSchema.specs[self]! }
}

public enum SyncSchema {
    /// The field every record carries with its Moments ID, so an ID that is
    /// not a valid CloudKit record name still round-trips.
    public static let idField = "mid"

    static let specs: [SyncRecordType: SyncTypeSpec] = [
        .place: SyncTypeSpec(
            fields: [
                SyncFieldSpec("name", .string),
                SyncFieldSpec("kindRaw", .string),
                SyncFieldSpec("latitude", .double),
                SyncFieldSpec("longitude", .double),
                SyncFieldSpec("mapLink", .string),
                SyncFieldSpec("parentID", .reference, target: .place),
                SyncFieldSpec("updatedAt", .date, .stamp),
                SyncFieldSpec("updatedBy", .string, account: true)
            ],
            ownership: .shared, stampField: "updatedAt", editorField: "updatedBy"
        ),
        .tag: SyncTypeSpec(
            fields: [
                SyncFieldSpec("normalizedName", .string),
                SyncFieldSpec("displayName", .string),
                SyncFieldSpec("updatedAt", .date, .stamp),
                SyncFieldSpec("updatedBy", .string, account: true)
            ],
            ownership: .shared, stampField: "updatedAt", editorField: "updatedBy"
        ),
        .trip: SyncTypeSpec(
            fields: [
                SyncFieldSpec("name", .string),
                SyncFieldSpec("startDate", .date),
                SyncFieldSpec("endDate", .date),
                SyncFieldSpec("overrideName", .string),
                SyncFieldSpec("mergeOverrideID", .string),
                SyncFieldSpec("splitOverrideDayKeys", .string),
                SyncFieldSpec("suggestionStatusRaw", .string),
                SyncFieldSpec("confirmedAt", .date),
                SyncFieldSpec("updatedAt", .date, .stamp),
                SyncFieldSpec("updatedBy", .string, account: true)
            ],
            ownership: .shared, stampField: "updatedAt", editorField: "updatedBy"
        ),
        // Bookmarks, file names, Apple Photos identifiers, import review state
        // and import sources are this Mac's business and are not listed.
        .mediaItem: SyncTypeSpec(
            fields: [
                SyncFieldSpec("captureDate", .date),
                SyncFieldSpec("latitude", .double),
                SyncFieldSpec("longitude", .double),
                SyncFieldSpec("kindRaw", .string),
                SyncFieldSpec("width", .int),
                SyncFieldSpec("height", .int),
                SyncFieldSpec("isScreenshot", .bool),
                // No title: for imported photos it is the original file
                // name, which stays on this Mac.
                SyncFieldSpec("tripID", .reference, target: .trip),
                SyncFieldSpec("placeID", .reference, target: .place),
                SyncFieldSpec("originalContentHash", .string, .immutable),
                SyncFieldSpec("perceptualHash", .string),
                SyncFieldSpec("localTimeZoneOffsetMinutes", .int),
                SyncFieldSpec("localDayKey", .string),
                SyncFieldSpec("timeZoneIdentifier", .string),
                SyncFieldSpec("timeConfidenceRaw", .string),
                SyncFieldSpec("userCorrectedCaptureDateUTC", .date),
                SyncFieldSpec("duration", .double),
                SyncFieldSpec("deletedAt", .date),
                SyncFieldSpec("deletedBy", .string, account: true),
                SyncFieldSpec("ownerAccountID", .string, .immutable, account: true, nilMeansLocal: true),
                SyncFieldSpec("updatedAt", .date, .stamp),
                SyncFieldSpec("updatedBy", .string, account: true)
            ],
            ownership: .shared, stampField: "updatedAt", editorField: "updatedBy"
        ),
        .previewAsset: SyncTypeSpec(
            fields: [
                SyncFieldSpec("mediaID", .reference, .immutable, target: .mediaItem),
                SyncFieldSpec("preview", .asset),
                SyncFieldSpec("updatedAt", .date, .stamp),
                SyncFieldSpec("updatedBy", .string, account: true)
            ],
            ownership: .shared, stampField: "updatedAt", editorField: "updatedBy"
        ),
        // `authorRaw` (me / partner) is a display label each device derives
        // from `authorAccountID`; it is never synced.
        .memory: SyncTypeSpec(
            fields: [
                SyncFieldSpec("mediaID", .reference, .immutable, target: .mediaItem),
                SyncFieldSpec("text", .string, text: true),
                SyncFieldSpec("authorAccountID", .string, .immutable, account: true, nilMeansLocal: true),
                SyncFieldSpec("createdAt", .date, .immutable),
                SyncFieldSpec("revision", .int, .maximum),
                SyncFieldSpec("updatedAt", .date, .stamp),
                SyncFieldSpec("updatedBy", .string, account: true)
            ],
            ownership: .authored(field: "authorAccountID"), stampField: "updatedAt", editorField: "updatedBy"
        ),
        .memoryRevision: SyncTypeSpec(
            fields: [
                SyncFieldSpec("memoryID", .reference, .immutable, target: .memory),
                SyncFieldSpec("text", .string, .immutable),
                SyncFieldSpec("editedBy", .string, .immutable, account: true),
                SyncFieldSpec("editedAt", .date, .stamp),
                SyncFieldSpec("baseRevision", .int, .immutable),
                SyncFieldSpec("reason", .string, .immutable)
            ],
            ownership: .appendOnly, stampField: "editedAt", editorField: "editedBy"
        ),
        .mediaTag: SyncTypeSpec(
            fields: [
                SyncFieldSpec("mediaID", .reference, .immutable, target: .mediaItem),
                SyncFieldSpec("tagID", .reference, .immutable, target: .tag),
                SyncFieldSpec("updatedAt", .date, .stamp),
                SyncFieldSpec("updatedBy", .string, account: true)
            ],
            ownership: .shared, stampField: "updatedAt", editorField: "updatedBy"
        ),
        .favorite: SyncTypeSpec(
            fields: [
                SyncFieldSpec("mediaID", .reference, .immutable, target: .mediaItem),
                SyncFieldSpec("accountID", .string, .immutable, account: true),
                SyncFieldSpec("isFavorite", .bool),
                SyncFieldSpec("changedAt", .date, .stamp)
            ],
            ownership: .perAccount(field: "accountID"), stampField: "changedAt", editorField: "accountID"
        ),
        .placeOverride: SyncTypeSpec(
            fields: [
                SyncFieldSpec("placeID", .reference, .immutable, target: .place),
                SyncFieldSpec("mediaID", .reference, .immutable, target: .mediaItem),
                SyncFieldSpec("accountID", .string, .immutable, account: true),
                SyncFieldSpec("nameOverride", .string),
                SyncFieldSpec("mapLinkOverride", .string),
                SyncFieldSpec("latitude", .double),
                SyncFieldSpec("longitude", .double),
                SyncFieldSpec("updatedAt", .date, .stamp),
                SyncFieldSpec("updatedBy", .string, account: true)
            ],
            ownership: .perAccount(field: "accountID"), stampField: "updatedAt", editorField: "updatedBy"
        ),
        .userGroup: SyncTypeSpec(
            fields: [
                SyncFieldSpec("name", .string),
                SyncFieldSpec("kindRaw", .string),
                SyncFieldSpec("rulesData", .data),
                SyncFieldSpec("ownerAccountID", .string, .immutable, account: true),
                SyncFieldSpec("createdAt", .date, .immutable),
                SyncFieldSpec("updatedAt", .date, .stamp)
            ],
            ownership: .shared, stampField: "updatedAt", editorField: nil
        ),
        .userGroupItem: SyncTypeSpec(
            fields: [
                SyncFieldSpec("groupID", .reference, .immutable, target: .userGroup),
                SyncFieldSpec("mediaID", .reference, .immutable, target: .mediaItem),
                SyncFieldSpec("addedBy", .string, account: true),
                SyncFieldSpec("excluded", .bool),
                SyncFieldSpec("addedAt", .date, .stamp)
            ],
            ownership: .shared, stampField: "addedAt", editorField: "addedBy"
        ),
        // The AI suggestions, undo record and status are the author's working
        // state on their own Mac; only the words travel.
        .photoNote: SyncTypeSpec(
            fields: [
                SyncFieldSpec("mediaID", .reference, .immutable, target: .mediaItem),
                SyncFieldSpec("authorAccountID", .string, .immutable, account: true),
                SyncFieldSpec("text", .string, text: true),
                SyncFieldSpec("createdAt", .date, .immutable),
                SyncFieldSpec("updatedAt", .date, .stamp)
            ],
            ownership: .authored(field: "authorAccountID"), stampField: "updatedAt", editorField: "authorAccountID"
        ),
        .placeNote: SyncTypeSpec(
            fields: [
                SyncFieldSpec("placeKey", .string),
                SyncFieldSpec("placeName", .string),
                SyncFieldSpec("text", .string, text: true),
                SyncFieldSpec("authorAccountID", .string, .immutable, account: true),
                SyncFieldSpec("sourceNoteID", .reference, target: .photoNote),
                SyncFieldSpec("updatedAt", .date, .stamp)
            ],
            ownership: .authored(field: "authorAccountID"), stampField: "updatedAt", editorField: "authorAccountID"
        ),
        .collectionMemory: SyncTypeSpec(
            fields: [
                SyncFieldSpec("scopeRaw", .string, .immutable),
                SyncFieldSpec("scopeKey", .string, .immutable),
                SyncFieldSpec("text", .string, text: true),
                SyncFieldSpec("authorAccountID", .string, .immutable, account: true),
                SyncFieldSpec("createdAt", .date, .immutable),
                SyncFieldSpec("sourceNoteID", .reference, target: .photoNote),
                SyncFieldSpec("updatedAt", .date, .stamp)
            ],
            ownership: .authored(field: "authorAccountID"), stampField: "updatedAt", editorField: "authorAccountID"
        ),
        // A comment under a memory, or a reply to a comment. Both people
        // comment on any memory; each edits and deletes only their own.
        .comment: SyncTypeSpec(
            fields: [
                SyncFieldSpec("memoryID", .reference, .immutable, target: .memory),
                SyncFieldSpec("parentCommentID", .reference, .immutable, target: .comment),
                SyncFieldSpec("text", .string, text: true),
                SyncFieldSpec("authorAccountID", .string, .immutable, account: true, nilMeansLocal: true),
                SyncFieldSpec("createdAt", .date, .immutable),
                SyncFieldSpec("updatedAt", .date, .stamp)
            ],
            ownership: .authored(field: "authorAccountID"), stampField: "updatedAt", editorField: "authorAccountID"
        )
    ]

    /// Drops fields the schema does not list and fields whose value has the
    /// wrong kind, so a record from a newer or broken client cannot write
    /// local-only or mistyped data.
    public static func sanitized(_ record: SyncRecord) -> SyncRecord {
        let spec = record.type.spec
        var clean = SyncRecord(type: record.type, id: record.id)
        for (name, value) in record.fields {
            guard let field = spec.field(name), field.kind == value.kind else { continue }
            clean.fields[name] = value
        }
        return clean
    }

    /// Fields the schema does not list: the app-side coder tests assert this
    /// is empty for every encoded record.
    public static func unknownFields(in record: SyncRecord) -> [String] {
        let known = record.type.spec.fieldNames
        return record.fields.keys.filter { !known.contains($0) }.sorted()
    }
}

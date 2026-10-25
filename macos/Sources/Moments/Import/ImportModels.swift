import Foundation
import MomentsCore

public enum ImportReviewReason: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case missingLocation = "missing-location"
    case fileDateFallback = "file-date-fallback"
    case gpsJump = "gps-jump"
    case captureDateOutsideTrip = "capture-date-outside-trip"
    case timePlaceConflict = "time-place-conflict"
    case airDropReceived = "airdrop-received"
    case nearDuplicate = "near-duplicate"
    case needsDate = "needs-date"
    case timeZoneUnknown = "time-zone-unknown"
    case geocodingRetry = "geocoding-retry"
    case noPhotosGap = "no-photos-gap"
    case transportCandidate = "transport-candidate"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .missingLocation: return String(localized: "No location")
        case .fileDateFallback: return String(localized: "File date used")
        case .gpsJump: return String(localized: "Candidate GPS jump")
        case .captureDateOutsideTrip: return String(localized: "Candidate capture date outside trip")
        case .timePlaceConflict: return String(localized: "Candidate time/place conflict")
        case .airDropReceived: return String(localized: "Possible AirDrop receive time")
        case .nearDuplicate: return String(localized: "Possible near-duplicate")
        case .needsDate: return String(localized: "Needs a date")
        case .timeZoneUnknown: return String(localized: "Time zone needs review")
        case .geocodingRetry: return String(localized: "Place lookup needs retry")
        case .noPhotosGap: return String(localized: "No photos gap")
        case .transportCandidate: return String(localized: "Possible transport")
        }
    }
}

public enum ImportReviewDecision: String, Codable, Equatable, Sendable {
    case pending
    case accepted
    case changed
    case ignored
}

public enum ImportTimeConfidence: String, Codable, Equatable, Sendable {
    case exact
    case zoneUnknown
    case low
    case missing
    case userCorrected
}

public enum ImportConflictKind: String, Codable, Equatable, Hashable, Sendable {
    case shortFastJump
    case highSpeedJump
    case sameSecondFarApart
    case abaLoop
    case transport
    case noPhotosGap
}

public struct ImportedSourceReference: Codable, Equatable, Hashable, Sendable {
    public let contentHash: String
    public let fileName: String
    public let bookmarkData: Data

    public init(contentHash: String, fileName: String, bookmarkData: Data) {
        self.contentHash = contentHash
        self.fileName = fileName
        self.bookmarkData = bookmarkData
    }
}

public struct ImportConflictEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let kind: ImportConflictKind
    public let itemIDs: [String]
    public let distanceMeters: Double?
    public let timeGap: TimeInterval?
    public let detail: String

    public init(
        kind: ImportConflictKind,
        itemIDs: [String],
        distanceMeters: Double? = nil,
        timeGap: TimeInterval? = nil,
        detail: String
    ) {
        self.kind = kind
        self.itemIDs = itemIDs
        self.distanceMeters = distanceMeters
        self.timeGap = timeGap
        self.detail = detail
        self.id = "\(kind.rawValue):\(itemIDs.joined(separator: ","))"
    }
}

public enum ImportCaptureDateSource: String, Codable, Equatable, Sendable {
    case exif
    case asset
    case fileDateFallback
}

public struct ImportGeocodeResult: Codable, Equatable, Sendable {
    public let city: String?
    public let area: String?
    public let spot: String?
    public let timeZoneIdentifier: String?

    public init(city: String? = nil, area: String? = nil, spot: String? = nil, timeZoneIdentifier: String? = nil) {
        self.city = city
        self.area = area
        self.spot = spot
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public protocol ImportGeocoder: Sendable {
    func reverseGeocode(coordinate: GeoPoint) async throws -> ImportGeocodeResult
}

public struct ImportConfiguration: Sendable {
    public var maximumTimeGap: TimeInterval
    public var maximumTripDistanceMeters: Double
    public var gpsJumpDistanceMeters: Double
    public var gpsJumpMaximumTimeGap: TimeInterval
    public var captureDateConflictThreshold: TimeInterval
    public var homeCoordinate: GeoPoint?
    public var conflictConfiguration: ImportConflictConfiguration

    public init(
        maximumTimeGap: TimeInterval = 36 * 60 * 60,
        maximumTripDistanceMeters: Double = 300_000,
        gpsJumpDistanceMeters: Double = 300_000,
        gpsJumpMaximumTimeGap: TimeInterval = 60 * 60,
        captureDateConflictThreshold: TimeInterval = 180 * 24 * 60 * 60,
        homeCoordinate: GeoPoint? = nil,
        conflictConfiguration: ImportConflictConfiguration = .current
    ) {
        self.maximumTimeGap = max(0, maximumTimeGap)
        self.maximumTripDistanceMeters = max(0, maximumTripDistanceMeters)
        self.gpsJumpDistanceMeters = max(0, gpsJumpDistanceMeters)
        self.gpsJumpMaximumTimeGap = max(0, gpsJumpMaximumTimeGap)
        self.captureDateConflictThreshold = max(0, captureDateConflictThreshold)
        self.homeCoordinate = homeCoordinate
        self.conflictConfiguration = conflictConfiguration
    }
}

public struct ImportConflictConfiguration: Codable, Equatable, Sendable {
    public static let current = ImportConflictConfiguration()

    public let version: String
    public let consecutiveDistanceMeters: Double
    public let consecutiveMaximumTimeGap: TimeInterval
    public let highSpeedDistanceMeters: Double
    public let highSpeedMetersPerSecond: Double
    public let sameSecondDistanceMeters: Double
    public let abaMaximumTimeGap: TimeInterval
    public let abaLegDistanceMeters: Double
    public let abaReturnDistanceMeters: Double
    public let transportMinimumDistanceMeters: Double
    public let transportMaximumSpeedKmh: Double
    public let noPhotosGap: TimeInterval

    public init(
        version: String = "import-conflicts-v2",
        consecutiveDistanceMeters: Double = 3_000,
        consecutiveMaximumTimeGap: TimeInterval = 5 * 60,
        highSpeedDistanceMeters: Double = 2_000,
        highSpeedMetersPerSecond: Double = 150_000 / 3_600,
        sameSecondDistanceMeters: Double = 3_000,
        abaMaximumTimeGap: TimeInterval = 30 * 60,
        abaLegDistanceMeters: Double = 3_000,
        abaReturnDistanceMeters: Double = 1_000,
        transportMinimumDistanceMeters: Double = 100_000,
        transportMaximumSpeedKmh: Double = 950,
        noPhotosGap: TimeInterval = 2 * 60 * 60
    ) {
        self.version = version
        self.consecutiveDistanceMeters = consecutiveDistanceMeters
        self.consecutiveMaximumTimeGap = consecutiveMaximumTimeGap
        self.highSpeedDistanceMeters = highSpeedDistanceMeters
        self.highSpeedMetersPerSecond = highSpeedMetersPerSecond
        self.sameSecondDistanceMeters = sameSecondDistanceMeters
        self.abaMaximumTimeGap = abaMaximumTimeGap
        self.abaLegDistanceMeters = abaLegDistanceMeters
        self.abaReturnDistanceMeters = abaReturnDistanceMeters
        self.transportMinimumDistanceMeters = transportMinimumDistanceMeters
        self.transportMaximumSpeedKmh = transportMaximumSpeedKmh
        self.noPhotosGap = noPhotosGap
    }
}

public struct ImportedMediaMetadata: Identifiable, Equatable, Sendable {
    public let id: String
    public let bookmarkData: Data
    public let fileName: String
    public let contentHash: String
    public let captureDate: Date
    public let captureDateSource: ImportCaptureDateSource
    public let timeZoneOffsetMinutes: Int?
    public let latitude: Double?
    public let longitude: Double?
    public let width: Int
    public let height: Int
    public let kind: MediaKind
    public let duration: Double?
    public let exactCaptureDate: Date?
    public let dateHintUTC: Date?
    public let timeConfidence: ImportTimeConfidence
    public let timeZoneIdentifier: String?
    /// The source directory is kept only while an import is being organized.
    /// It is intentionally not part of any persisted model or source reference.
    public let parentDirectoryKey: String?
    /// Apple Live Photo content identifier, used only for pairing in memory.
    public let appleContentIdentifier: String?
    /// EXIF local wall-clock components encoded as UTC until a zone is resolved.
    public let wallClockDate: Date?
    public let sourceReferences: [ImportedSourceReference]
    public let pairedVideoContentHash: String?
    public let pairedVideoBookmarkData: Data?

    public var baseName: String {
        URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    }

    public var isAirDropLike: Bool {
        let normalized = fileName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return ["airdrop", "air drop", "received", "from ", "shared"].contains { normalized.contains($0) }
    }

    public init(
        id: String,
        bookmarkData: Data,
        fileName: String,
        contentHash: String,
        captureDate: Date,
        captureDateSource: ImportCaptureDateSource,
        timeZoneOffsetMinutes: Int?,
        latitude: Double?,
        longitude: Double?,
        width: Int,
        height: Int,
        kind: MediaKind,
        duration: Double?,
        exactCaptureDate: Date? = nil,
        dateHintUTC: Date? = nil,
        timeConfidence: ImportTimeConfidence = .exact,
        timeZoneIdentifier: String? = nil,
        parentDirectoryKey: String? = nil,
        appleContentIdentifier: String? = nil,
        wallClockDate: Date? = nil,
        sourceReferences: [ImportedSourceReference]? = nil,
        pairedVideoContentHash: String? = nil,
        pairedVideoBookmarkData: Data? = nil
    ) {
        self.id = id
        self.bookmarkData = bookmarkData
        self.fileName = fileName
        self.contentHash = contentHash
        self.captureDate = captureDate
        self.captureDateSource = captureDateSource
        self.timeZoneOffsetMinutes = timeZoneOffsetMinutes
        self.latitude = latitude
        self.longitude = longitude
        self.width = width
        self.height = height
        self.kind = kind
        self.duration = duration
        self.exactCaptureDate = exactCaptureDate ?? (timeConfidence == .exact ? captureDate : nil)
        self.dateHintUTC = dateHintUTC ?? (timeConfidence == .low ? captureDate : nil)
        self.timeConfidence = timeConfidence
        self.timeZoneIdentifier = timeZoneIdentifier
        self.parentDirectoryKey = parentDirectoryKey
        self.appleContentIdentifier = appleContentIdentifier
        self.wallClockDate = wallClockDate
        self.sourceReferences = sourceReferences ?? [
            ImportedSourceReference(contentHash: contentHash, fileName: fileName, bookmarkData: bookmarkData)
        ]
        self.pairedVideoContentHash = pairedVideoContentHash
        self.pairedVideoBookmarkData = pairedVideoBookmarkData
    }

    public func replacing(
        kind: MediaKind? = nil,
        duration: Double? = nil,
        sourceReferences: [ImportedSourceReference]? = nil,
        pairedVideoContentHash: String? = nil,
        pairedVideoBookmarkData: Data? = nil,
        timeZoneIdentifier: String? = nil,
        parentDirectoryKey: String? = nil,
        appleContentIdentifier: String? = nil,
        wallClockDate: Date? = nil
    ) -> ImportedMediaMetadata {
        ImportedMediaMetadata(
            id: id,
            bookmarkData: bookmarkData,
            fileName: fileName,
            contentHash: contentHash,
            captureDate: captureDate,
            captureDateSource: captureDateSource,
            timeZoneOffsetMinutes: timeZoneOffsetMinutes,
            latitude: latitude,
            longitude: longitude,
            width: width,
            height: height,
            kind: kind ?? self.kind,
            duration: duration ?? self.duration,
            exactCaptureDate: exactCaptureDate,
            dateHintUTC: dateHintUTC,
            timeConfidence: timeConfidence,
            timeZoneIdentifier: timeZoneIdentifier ?? self.timeZoneIdentifier,
            parentDirectoryKey: parentDirectoryKey ?? self.parentDirectoryKey,
            appleContentIdentifier: appleContentIdentifier ?? self.appleContentIdentifier,
            wallClockDate: wallClockDate ?? self.wallClockDate,
            sourceReferences: sourceReferences ?? self.sourceReferences,
            pairedVideoContentHash: pairedVideoContentHash ?? self.pairedVideoContentHash,
            pairedVideoBookmarkData: pairedVideoBookmarkData ?? self.pairedVideoBookmarkData
        )
    }

    func resolving(
        captureDate: Date,
        exactCaptureDate: Date,
        dateHintUTC: Date?,
        timeConfidence: ImportTimeConfidence,
        timeZoneIdentifier: String
    ) -> ImportedMediaMetadata {
        ImportedMediaMetadata(
            id: id,
            bookmarkData: bookmarkData,
            fileName: fileName,
            contentHash: contentHash,
            captureDate: captureDate,
            captureDateSource: captureDateSource,
            timeZoneOffsetMinutes: timeZoneOffsetMinutes,
            latitude: latitude,
            longitude: longitude,
            width: width,
            height: height,
            kind: kind,
            duration: duration,
            exactCaptureDate: exactCaptureDate,
            dateHintUTC: dateHintUTC,
            timeConfidence: timeConfidence,
            timeZoneIdentifier: timeZoneIdentifier,
            parentDirectoryKey: parentDirectoryKey,
            appleContentIdentifier: appleContentIdentifier,
            wallClockDate: nil,
            sourceReferences: sourceReferences,
            pairedVideoContentHash: pairedVideoContentHash,
            pairedVideoBookmarkData: pairedVideoBookmarkData
        )
    }
}

public struct ImportReviewFlag: Identifiable, Equatable, Sendable {
    public let id: String
    public let fileName: String
    public let reasons: [ImportReviewReason]
    public let detail: String?
    public let suggestedDayKey: String?
    public let suggestedPlaceName: String?
    public let decision: ImportReviewDecision

    public init(
        id: String,
        fileName: String,
        reasons: [ImportReviewReason],
        detail: String? = nil,
        suggestedDayKey: String? = nil,
        suggestedPlaceName: String? = nil,
        decision: ImportReviewDecision = .pending
    ) {
        self.id = id
        self.fileName = fileName
        self.reasons = reasons
        self.detail = detail
        self.suggestedDayKey = suggestedDayKey
        self.suggestedPlaceName = suggestedPlaceName
        self.decision = decision
    }
}

public struct ImportTripSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let itemCount: Int
    public let startDate: Date?
    public let endDate: Date?
    public let isSuggestion: Bool

    public init(id: String, name: String, itemCount: Int, startDate: Date?, endDate: Date?, isSuggestion: Bool = true) {
        self.id = id
        self.name = name
        self.itemCount = itemCount
        self.startDate = startDate
        self.endDate = endDate
        self.isSuggestion = isSuggestion
    }
}

public struct ImportSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let importedCount: Int
    public let skippedCount: Int
    public let tripCount: Int
    public let placeCount: Int
    public let collectionCount: Int
    public let routeCount: Int
    public let trips: [ImportTripSummary]
    public let flags: [ImportReviewFlag]
    public let conflicts: [ImportConflictEvent]

    public init(
        importedCount: Int,
        skippedCount: Int,
        tripCount: Int,
        placeCount: Int,
        collectionCount: Int,
        routeCount: Int,
        trips: [ImportTripSummary],
        flags: [ImportReviewFlag],
        conflicts: [ImportConflictEvent] = []
    ) {
        self.id = UUID().uuidString
        self.importedCount = importedCount
        self.skippedCount = skippedCount
        self.tripCount = tripCount
        self.placeCount = placeCount
        self.collectionCount = collectionCount
        self.routeCount = routeCount
        self.trips = trips
        self.flags = flags
        self.conflicts = conflicts
    }
}

public struct ImportProgress: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case scanning
        case readingMetadata
        case organizing
        case saving
        case finished
        case cancelled
    }

    public let phase: Phase
    public let completed: Int
    public let total: Int
    public let message: String

    public init(phase: Phase, completed: Int, total: Int, message: String) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.message = message
    }

    public var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

extension MediaItem {
    public var importReviewReasons: [ImportReviewReason] {
        (importReviewReasonsRaw ?? "")
            .split(separator: ",")
            .compactMap { ImportReviewReason(rawValue: String($0)) }
    }

    public var needsImportReview: Bool { !importReviewReasons.isEmpty }
}

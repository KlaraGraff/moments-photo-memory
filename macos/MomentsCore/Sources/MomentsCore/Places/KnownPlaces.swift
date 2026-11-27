import Foundation

/// What a place is to the person. Every role counts the same when trips are
/// found (time there is daily life); the role says why, in their words.
public enum PlaceRole: String, Codable, CaseIterable, Sendable {
    case home
    case homeTown
    case work
    case formerWork
    /// A place they said a visit to is no trip ("This is not a trip").
    case notTrip

    /// The roles offered when confirming or adding a place.
    public static let chosen: [PlaceRole] = [.home, .homeTown, .work, .formerWork]
}

/// A place the photos call home, found by `TripSegmenter.homeCandidates`
/// for the person to confirm.
public struct HomeCandidate: Equatable, Sendable {
    public let centre: GeoPoint
    public let firstDate: Date
    public let lastDate: Date
    /// Days with a photo within `usualPlaceClusterRadiusMeters`.
    public let photoDays: Int
    /// Of those, the days in the last 180 days of the library.
    public let recentPhotoDays: Int
    /// Separate stretches there, apart by more than two months.
    public let visits: Int
    /// A photo there in the last 60 days of the library.
    public let isCurrent: Bool
    public internal(set) var suggestedRole: PlaceRole
    /// The photos taken there, in date order, to name the place by.
    public let photoIDs: [String]
}

/// One place the person named, with what it is to them.
public struct KnownPlace: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var role: PlaceRole
    public var latitude: Double
    public var longitude: Double
    /// When they were there, from the photos, for the settings list.
    public var since: Date?
    /// `nil` while they still are.
    public var until: Date?
    public var addedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        role: PlaceRole,
        centre: GeoPoint,
        since: Date? = nil,
        until: Date? = nil,
        addedAt: Date
    ) {
        self.id = id
        self.name = name
        self.role = role
        latitude = centre.latitude
        longitude = centre.longitude
        self.since = since
        self.until = until
        self.addedAt = addedAt
    }

    public var centre: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }
}

/// The places someone named, the candidates they turned down and how long a
/// stay makes daily life: everything the trip finder learns from the person.
/// Stored as JSON in the library's decisions; never leaves the Mac.
public struct KnownPlaceBook: Codable, Equatable, Sendable {
    /// A point the person answered about, so the same candidate is not offered again.
    public struct Spot: Codable, Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double

        public init(_ point: GeoPoint) {
            latitude = point.latitude
            longitude = point.longitude
        }

        public var point: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }
    }

    /// Two points this close are the same place.
    public static let samePlaceMeters: Double = 25_000
    /// The default and the range for `livedThereDays`.
    public static let defaultLivedThereDays = 30
    public static let livedThereDaysRange = 7...365

    public var places: [KnownPlace] = []
    /// Candidates answered "No" (or "It was a trip").
    public var declined: [Spot] = []
    /// Candidates already shown after an import, answered or put off.
    public var asked: [Spot] = []
    /// A stay of this many days or more is daily life; `nil` for the default.
    public var livedThereDays: Int?

    public init() {}

    // MARK: Reading

    public var coordinates: [GeoPoint] { places.map(\.centre) }

    public var effectiveLivedThereDays: Int { livedThereDays ?? Self.defaultLivedThereDays }

    public func place(near point: GeoPoint) -> KnownPlace? {
        places.first { $0.centre.distance(to: point) <= Self.samePlaceMeters }
    }

    public func isDeclined(_ point: GeoPoint) -> Bool {
        declined.contains { $0.point.distance(to: point) <= Self.samePlaceMeters }
    }

    public func wasAsked(_ point: GeoPoint) -> Bool {
        asked.contains { $0.point.distance(to: point) <= Self.samePlaceMeters }
    }

    /// Candidates the person has neither named nor turned down.
    public func open(_ candidates: [HomeCandidate]) -> [HomeCandidate] {
        candidates.filter { place(near: $0.centre) == nil && !isDeclined($0.centre) }
    }

    /// Open candidates not yet shown after an import.
    public func unasked(_ candidates: [HomeCandidate]) -> [HomeCandidate] {
        open(candidates).filter { !wasAsked($0.centre) }
    }

    /// The trip finder, set to use what the person said.
    public func apply(to segmenter: inout TripSegmenter) {
        segmenter.knownPlaces = coordinates
        segmenter.livedThereDays = effectiveLivedThereDays
    }

    // MARK: Changing

    /// The candidate becomes one of their places, with the role they chose.
    @discardableResult
    public mutating func confirm(_ candidate: HomeCandidate, name: String, role: PlaceRole, now: Date) -> KnownPlace {
        let place = KnownPlace(
            name: name,
            role: role,
            centre: candidate.centre,
            since: candidate.firstDate,
            until: candidate.isCurrent ? nil : candidate.lastDate,
            addedAt: now
        )
        add(place)
        return place
    }

    /// Adds a place, or gives the place already there its new name and role.
    public mutating func add(_ place: KnownPlace) {
        declined.removeAll { $0.point.distance(to: place.centre) <= Self.samePlaceMeters }
        if let index = places.firstIndex(where: { $0.centre.distance(to: place.centre) <= Self.samePlaceMeters }) {
            places[index].name = place.name
            places[index].role = place.role
        } else {
            places.append(place)
        }
    }

    /// Remembers that a visit to this place is no trip. A place already
    /// named keeps its own role.
    @discardableResult
    public mutating func rememberNotTrip(name: String, centre: GeoPoint, now: Date) -> KnownPlace {
        if let known = place(near: centre) { return known }
        let place = KnownPlace(name: name, role: .notTrip, centre: centre, addedAt: now)
        places.append(place)
        return place
    }

    public mutating func decline(_ point: GeoPoint) {
        guard !isDeclined(point) else { return }
        declined.append(Spot(point))
    }

    public mutating func markAsked(_ points: [GeoPoint]) {
        for point in points where !wasAsked(point) { asked.append(Spot(point)) }
    }

    public mutating func setRole(_ role: PlaceRole, of id: String) {
        guard let index = places.firstIndex(where: { $0.id == id }) else { return }
        places[index].role = role
    }

    public mutating func remove(_ id: String) {
        places.removeAll { $0.id == id }
    }

    public mutating func setLivedThereDays(_ days: Int) {
        let clamped = min(max(days, Self.livedThereDaysRange.lowerBound), Self.livedThereDaysRange.upperBound)
        livedThereDays = clamped == Self.defaultLivedThereDays ? nil : clamped
    }

    // MARK: Storage

    public static func decode(_ stored: String?) -> KnownPlaceBook {
        guard let data = stored?.data(using: .utf8),
              let book = try? JSONDecoder().decode(KnownPlaceBook.self, from: data) else { return KnownPlaceBook() }
        return book
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

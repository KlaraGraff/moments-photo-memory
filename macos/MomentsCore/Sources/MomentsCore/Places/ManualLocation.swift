import Foundation

/// The pieces of "Set Location…" that need no Apple frameworks: which manual
/// coordinate a photo shows, which photos of the same day can lend theirs,
/// which selected photos a batch changes, and where in the place tree a
/// hand-set coordinate belongs.
public enum ManualLocation {
    // MARK: Which manual coordinate wins

    /// One person's hand-set coordinate for a photo. Each account keeps its
    /// own (overrides are per account in sync), so a shared photo can carry
    /// two.
    public struct OverrideCoordinate: Equatable, Sendable {
        public let accountID: String
        public let point: GeoPoint
        public let updatedAt: Date

        public init(accountID: String, point: GeoPoint, updatedAt: Date) {
            self.accountID = accountID
            self.point = point
            self.updatedAt = updatedAt
        }
    }

    /// The coordinate a photo shows: the one set most recently, by whoever
    /// set it. Ties go to the smaller account id, so both Macs agree.
    public static func resolved(_ overrides: [OverrideCoordinate]) -> OverrideCoordinate? {
        overrides.max { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.accountID > rhs.accountID
        }
    }

    /// One row per override with a coordinate, as the map fetches them.
    public struct OverrideRow: Sendable {
        public let mediaID: String
        public let coordinate: OverrideCoordinate

        public init(mediaID: String, coordinate: OverrideCoordinate) {
            self.mediaID = mediaID
            self.coordinate = coordinate
        }
    }

    /// The winning hand-set coordinate for every photo that has one.
    public static func index(_ rows: [OverrideRow]) -> [String: GeoPoint] {
        var best: [String: OverrideCoordinate] = [:]
        for row in rows {
            if let current = best[row.mediaID] {
                best[row.mediaID] = resolved([current, row.coordinate])
            } else {
                best[row.mediaID] = row.coordinate
            }
        }
        return best.mapValues(\.point)
    }

    // MARK: Same place as a photo from that day

    /// A photo the sheet may borrow a location from. Only the camera's own
    /// coordinate counts: a borrowed or typed one is a guess already.
    public struct DayPhoto: Equatable, Sendable {
        public let id: String
        public let date: Date?
        public let dayKey: String?
        public let cameraPoint: GeoPoint?

        public init(id: String, date: Date?, dayKey: String?, cameraPoint: GeoPoint?) {
            self.id = id
            self.date = date
            self.dayKey = dayKey
            self.cameraPoint = cameraPoint
        }
    }

    public struct Suggestion: Equatable, Sendable {
        public let photoID: String
        public let point: GeoPoint
        /// How long after the nearest selected photo this one was taken;
        /// negative for earlier.
        public let interval: TimeInterval
    }

    /// Up to `limit` photos from the selected photos' days that have a
    /// camera location, nearest in time first. A suggestion within
    /// `distinctMeters` of a nearer one is skipped, so each offers a
    /// different place. Nothing is applied; the sheet only shows these.
    public static func sameDaySuggestions(
        for selected: [DayPhoto],
        among candidates: [DayPhoto],
        limit: Int = 3,
        distinctMeters: Double = 100
    ) -> [Suggestion] {
        let selectedIDs = Set(selected.map(\.id))
        let days = Set(selected.compactMap(\.dayKey))
        let referenceDates = selected.compactMap(\.date).sorted()
        guard limit > 0, !days.isEmpty, !referenceDates.isEmpty else { return [] }

        var ranked: [(suggestion: Suggestion, distance: TimeInterval)] = []
        for candidate in candidates {
            guard !selectedIDs.contains(candidate.id),
                  let day = candidate.dayKey, days.contains(day),
                  let date = candidate.date,
                  let point = candidate.cameraPoint,
                  let nearest = nearestDate(to: date, in: referenceDates) else { continue }
            let interval = date.timeIntervalSince(nearest)
            ranked.append((Suggestion(photoID: candidate.id, point: point, interval: interval), abs(interval)))
        }
        ranked.sort { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            return lhs.suggestion.photoID < rhs.suggestion.photoID
        }

        var picked: [Suggestion] = []
        for entry in ranked {
            if picked.contains(where: { $0.point.distance(to: entry.suggestion.point) < distinctMeters }) { continue }
            picked.append(entry.suggestion)
            if picked.count == limit { break }
        }
        return picked
    }

    private static func nearestDate(to date: Date, in sorted: [Date]) -> Date? {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < date { low = middle + 1 } else { high = middle }
        }
        let after = low < sorted.count ? sorted[low] : nil
        let before = low > 0 ? sorted[low - 1] : nil
        switch (before, after) {
        case let (before?, after?):
            return date.timeIntervalSince(before) <= after.timeIntervalSince(date) ? before : after
        case let (before?, nil): return before
        case let (nil, after?): return after
        default: return nil
        }
    }

    // MARK: Which selected photos a batch changes

    public struct Target: Equatable, Sendable {
        public let id: String
        public let hasCameraLocation: Bool

        public init(id: String, hasCameraLocation: Bool) {
            self.id = id
            self.hasCameraLocation = hasCameraLocation
        }
    }

    /// The photos a batch changes. By default a photo whose camera recorded
    /// a location keeps it; `includingCameraLocated` changes those too (the
    /// camera's coordinate is kept underneath and can be restored).
    public static func targets(_ selected: [Target], includingCameraLocated: Bool) -> [String] {
        selected.filter { includingCameraLocated || !$0.hasCameraLocation }.map(\.id)
    }

    // MARK: Where in the place tree

    public enum Level: String, Sendable {
        case spot, area, city
    }

    /// A place already in the library, as the placement reads it.
    public struct ExistingPlace: Equatable, Sendable {
        public let id: String
        public let level: Level
        public let point: GeoPoint

        public init(id: String, level: Level, point: GeoPoint) {
            self.id = id
            self.level = level
            self.point = point
        }
    }

    /// What to link a hand-located photo to, so grouping and naming by place
    /// work as for a camera location. New places are left unnamed; the
    /// place-name backfill names the city and area later.
    public enum Placement: Equatable, Sendable {
        /// An existing spot close enough to share.
        case spot(id: String)
        /// A new spot under this existing area.
        case newSpot(areaID: String)
        /// A new area and spot under this existing city.
        case newArea(cityID: String)
        /// A new city, area and spot.
        case newCity
    }

    /// The radii match the import: a spot is shared within 1 km, and an area
    /// or city within the clusterer's radius for that level.
    public static func placement(
        for point: GeoPoint,
        among places: [ExistingPlace],
        spotRadiusMeters: Double = 1_000,
        areaRadiusMeters: Double = 8_000,
        cityRadiusMeters: Double = 25_000
    ) -> Placement {
        if let spot = nearest(.spot, to: point, in: places, within: spotRadiusMeters) {
            return .spot(id: spot.id)
        }
        if let area = nearest(.area, to: point, in: places, within: areaRadiusMeters) {
            return .newSpot(areaID: area.id)
        }
        if let city = nearest(.city, to: point, in: places, within: cityRadiusMeters) {
            return .newArea(cityID: city.id)
        }
        return .newCity
    }

    private static func nearest(
        _ level: Level,
        to point: GeoPoint,
        in places: [ExistingPlace],
        within radius: Double
    ) -> ExistingPlace? {
        var best: (place: ExistingPlace, distance: Double)?
        for place in places where place.level == level {
            let distance = place.point.distance(to: point)
            guard distance <= radius else { continue }
            if let current = best,
               current.distance < distance || (current.distance == distance && current.place.id < place.id) {
                continue
            }
            best = (place, distance)
        }
        return best?.place
    }
}

import Foundation

/// Finds trips in a photo library: the stretches spent away from the
/// places someone usually stays (常驻地).
///
/// A usual place is not a setting. It is any place that holds a good share
/// of the photo days of the surrounding months, so there can be several (a
/// work city and parents' town), and they follow a move to another city.
/// Photos taken within `awayRadiusMeters` of a usual place are daily life and
/// belong to no trip. Photos without a location take the side of the located
/// photo closest in time (within `locationlessMatchWindow`). When no usual
/// place stands out, as for a folder that holds a single trip, every photo
/// counts as away and the time and distance gaps alone split the trips.
public struct TripSegmenter: Sendable {
    public struct Result: Equatable, Sendable {
        /// Photo ids per trip, each in date order, trips in date order.
        public let trips: [[String]]
        /// Photos that belong to no trip: taken at a usual place, or in a stretch
        /// away too small to call a trip.
        public let atUsualPlaceIDs: Set<String>
    }

    public var awayRadiusMeters: Double = 50_000
    public var usualPlaceClusterRadiusMeters: Double = 25_000
    /// Usual places are decided over this many days on either side of a photo.
    public var usualPlaceWindowDays: Int = 180
    /// A place needs this many photo days in the window, and this share of
    /// them, to count as a usual place.
    public var minimumUsualPlaceDays: Int = 10
    public var minimumUsualPlaceShare: Double = 0.25
    /// ... spread over this many 30-day stretches, so one long stay away is
    /// never a usual place.
    public var minimumUsualPlaceMonths: Int = 3
    /// Away photos further apart than this start a new trip when they are
    /// also more than `maximumTripDistanceMeters` apart, and that move is
    /// more than `homeDetourRatio` of the way home.
    public var maximumTimeGap: TimeInterval = 36 * 60 * 60
    public var maximumTripDistanceMeters: Double = 300_000
    /// A move longer than this share of the way home counts as having gone home in between.
    public var homeDetourRatio: Double = 0.5
    /// Away photos further apart than this always start a new trip.
    public var maximumQuietGap: TimeInterval = 4 * 24 * 60 * 60
    public var locationlessMatchWindow: TimeInterval = 12 * 60 * 60
    /// Photos without a location and no located photo nearby count as
    /// away: right for a folder from a camera without GPS. In a phone
    /// library they are mostly screenshots and saved images, so daily life.
    public var locationlessDefaultsToAway = false
    /// Where a usual place is known, a stretch away becomes a trip with this many
    /// photos, or when it spans more than one day.
    public var minimumTripItems: Int = 5
    /// A place the person set; it replaces the detected ones everywhere.
    public var fixedUsualPlace: GeoPoint?

    /// Raise this whenever a change moves photos between trips and daily life,
    /// so libraries grouped by older rules are grouped again (`TripRegrouping`).
    /// 2: trips are time away from usual places (#99). 3: a trip stays together
    /// across quiet days far from home (#111).
    public static let rulesVersion = 3

    public init() {}

    /// `stops` are the photos to place. `context` adds photos already in the
    /// library: they tell where the usual places are, lend their side to nearby photos
    /// without a location, and keep a few new photos next to a trip in it.
    public func segment(_ stops: [PhotoStop], context: [PhotoStop] = []) -> Result {
        let ordered = stops.sorted(by: Self.photoOrder)
        guard !ordered.isEmpty else { return Result(trips: [], atUsualPlaceIDs: []) }
        let usual = UsualPlaceFinder(segmenter: self, stops: ordered + context)
        func isAway(_ coordinate: GeoPoint, at date: Date) -> Bool {
            usual.places(at: date).allSatisfy { coordinate.distance(to: $0) > awayRadiusMeters }
        }
        func usualPlaceKnown(at date: Date) -> Bool { !usual.places(at: date).isEmpty }
        func distanceToNearestUsualPlace(_ coordinate: GeoPoint, at date: Date) -> Double? {
            usual.places(at: date).map { coordinate.distance(to: $0) }.min()
        }
        /// A move between two away photos is far enough to end the trip only
        /// when it is also long compared with the way home from both ends: a
        /// short hop between two places far from home is not a trip home.
        func isFarMove(from last: GeoPoint?, at lastDate: Date?, to stop: PhotoStop) -> Bool {
            guard let last, let next = stop.coordinate else { return false }
            let move = last.distance(to: next)
            guard move > maximumTripDistanceMeters else { return false }
            guard let lastDate,
                  let homeFromLast = distanceToNearestUsualPlace(last, at: lastDate),
                  let homeFromNext = distanceToNearestUsualPlace(next, at: stop.date)
            else { return true }
            return move > homeDetourRatio * min(homeFromLast, homeFromNext)
        }

        let located = (ordered + context)
            .compactMap { stop in stop.coordinate.map { (date: stop.date, away: isAway($0, at: stop.date)) } }
            .sorted { $0.date < $1.date }
        let locatedDates = located.map(\.date)
        let libraryAway = context
            .compactMap { stop in stop.coordinate.flatMap { isAway($0, at: stop.date) ? stop.date : nil } }
            .sorted()

        let away: [Bool] = ordered.map { stop in
            if let coordinate = stop.coordinate { return isAway(coordinate, at: stop.date) }
            let index = Self.lowerBound(stop.date, in: locatedDates)
            let nearest = [index - 1, index]
                .filter { located.indices.contains($0) }
                .min { abs(located[$0].date.timeIntervalSince(stop.date)) < abs(located[$1].date.timeIntervalSince(stop.date)) }
            if let nearest, abs(located[nearest].date.timeIntervalSince(stop.date)) <= locationlessMatchWindow {
                return located[nearest].away
            }
            return locationlessDefaultsToAway || !usualPlaceKnown(at: stop.date)
        }

        var runs: [[PhotoStop]] = []
        var current: [PhotoStop] = []
        var lastPosition: (coordinate: GeoPoint, date: Date)?
        for (index, stop) in ordered.enumerated() {
            guard away[index] else {
                if !current.isEmpty { runs.append(current); current = [] }
                lastPosition = nil
                continue
            }
            if let previous = current.last {
                let gap = stop.date.timeIntervalSince(previous.date)
                let far = isFarMove(from: lastPosition?.coordinate, at: lastPosition?.date, to: stop)
                // Without a usual place, a quiet day and a half ends a trip as before.
                if gap > maximumQuietGap || (gap > maximumTimeGap && (far || !usualPlaceKnown(at: stop.date))) {
                    runs.append(current)
                    current = []
                }
            }
            current.append(stop)
            if let coordinate = stop.coordinate { lastPosition = (coordinate, stop.date) }
        }
        if !current.isEmpty { runs.append(current) }

        var trips: [[String]] = []
        var atUsualPlaceIDs = Set(ordered.indices.filter { !away[$0] }.map { ordered[$0].id })
        for run in runs {
            guard let first = run.first, let last = run.last else { continue }
            // Without a usual place there is no daily life to fall back to, and a
            // few photos next to the library's photos away belong with them.
            let nextToLibraryAway = Self.lowerBound(last.date.addingTimeInterval(maximumTimeGap), in: libraryAway, inclusive: true)
                > Self.lowerBound(first.date.addingTimeInterval(-maximumTimeGap), in: libraryAway)
            if run.count >= minimumTripItems || spansSeveralDays(run) || !usualPlaceKnown(at: first.date) || nextToLibraryAway {
                trips.append(run.map(\.id))
            } else {
                atUsualPlaceIDs.formUnion(run.map(\.id))
            }
        }
        return Result(trips: trips, atUsualPlaceIDs: atUsualPlaceIDs)
    }

    private static func photoOrder(_ lhs: PhotoStop, _ rhs: PhotoStop) -> Bool {
        lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date < rhs.date
    }

    /// The first index whose date is not before `date` (after it, when
    /// `inclusive`).
    private static func lowerBound(_ date: Date, in sorted: [Date], inclusive: Bool = false) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < date || (inclusive && sorted[mid] == date) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func spansSeveralDays(_ run: [PhotoStop]) -> Bool {
        guard let first = run.first, let last = run.last else { return false }
        return last.date.timeIntervalSince(first.date) >= 20 * 60 * 60
    }
}

/// Usual places per 30-day bucket: the clusters of daily locations that hold enough
/// of the photo days within `usualPlaceWindowDays`.
private final class UsualPlaceFinder {
    private let fixed: GeoPoint?
    private let centres: [GeoPoint]
    private let daysByCluster: [[Int]]
    private let segmenter: TripSegmenter
    private var cache: [Int: [GeoPoint]] = [:]

    init(segmenter: TripSegmenter, stops: [PhotoStop]) {
        self.segmenter = segmenter
        fixed = segmenter.fixedUsualPlace
        guard fixed == nil else { centres = []; daysByCluster = []; return }
        var pointsByDay: [Int: [GeoPoint]] = [:]
        for stop in stops {
            guard let coordinate = stop.coordinate else { continue }
            pointsByDay[Self.day(of: stop.date), default: []].append(coordinate)
        }
        var centres: [GeoPoint] = []
        var days: [[Int]] = []
        for day in pointsByDay.keys.sorted() {
            let point = Self.median(pointsByDay[day] ?? [])
            if let cluster = centres.firstIndex(where: { $0.distance(to: point) <= segmenter.usualPlaceClusterRadiusMeters }) {
                days[cluster].append(day)
            } else {
                centres.append(point)
                days.append([day])
            }
        }
        self.centres = centres
        daysByCluster = days
    }

    func places(at date: Date) -> [GeoPoint] {
        if let fixed { return [fixed] }
        let bucket = Int((Double(Self.day(of: date)) / 30).rounded(.down))
        if let cached = cache[bucket] { return cached }
        let found = places(bucket: bucket)
        cache[bucket] = found
        return found
    }

    private func places(bucket: Int) -> [GeoPoint] {
        let middle = bucket * 30 + 15
        let window = (middle - segmenter.usualPlaceWindowDays)...(middle + segmenter.usualPlaceWindowDays)
        let counts = daysByCluster.map { Self.count(of: window, in: $0) }
        let total = Double(counts.reduce(0, +))
        return counts.indices
            .filter { counts[$0] >= segmenter.minimumUsualPlaceDays && Double(counts[$0]) >= segmenter.minimumUsualPlaceShare * total }
            .filter { Self.months(of: window, in: daysByCluster[$0]) >= segmenter.minimumUsualPlaceMonths }
            .map { centres[$0] }
    }

    private static func count(of window: ClosedRange<Int>, in sorted: [Int]) -> Int {
        lowerBound(window.upperBound + 1, in: sorted) - lowerBound(window.lowerBound, in: sorted)
    }

    /// How many 30-day stretches the days in `window` touch.
    private static func months(of window: ClosedRange<Int>, in sorted: [Int]) -> Int {
        let slice = sorted[lowerBound(window.lowerBound, in: sorted)..<lowerBound(window.upperBound + 1, in: sorted)]
        return Set(slice.map { Int((Double($0) / 30).rounded(.down)) }).count
    }

    private static func lowerBound(_ value: Int, in sorted: [Int]) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func day(of date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// The per-axis median keeps one stray photo from moving the day.
    private static func median(_ points: [GeoPoint]) -> GeoPoint {
        let latitudes = points.map(\.latitude).sorted()
        let longitudes = points.map(\.longitude).sorted()
        return GeoPoint(latitude: latitudes[latitudes.count / 2], longitude: longitudes[longitudes.count / 2])
    }
}

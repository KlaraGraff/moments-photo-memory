import Foundation

/// Finds trips in a photo library: the stretches spent away from home.
///
/// Home is not a setting. It is any place that holds a good share of the
/// photo days of the surrounding months, so it follows a move to another
/// /// city, and a place visited most weekends counts too. Photos taken within
/// `awayRadiusMeters` of home are daily life and belong to no trip. Photos
/// without a location take the side of the located photo closest in time
/// (within `locationlessMatchWindow`). When no home stands
/// out, as for a folder that holds a single trip, every photo counts as away
/// and the time and distance gaps alone split the trips.
public struct TripSegmenter: Sendable {
    public struct Result: Equatable, Sendable {
        /// Photo ids per trip, each in date order, trips in date order.
        public let trips: [[String]]
        /// Photos that belong to no trip: taken at home, or in a stretch
        /// away too small to call a trip.
        public let homeIDs: Set<String>
    }

    public var awayRadiusMeters: Double = 50_000
    public var homeClusterRadiusMeters: Double = 25_000
    /// Home is decided over this many days on either side of a photo.
    public var homeWindowDays: Int = 180
    /// A place needs this many photo days in the window, and this share of
    /// them, to count as a home.
    public var minimumHomeDays: Int = 10
    public var minimumHomeShare: Double = 0.25
    /// ... spread over this many 30-day stretches, so one long stay away is
    /// never home.
    public var minimumHomeMonths: Int = 3
    /// Away photos further apart than this start a new trip when they are
    /// also more than `maximumTripDistanceMeters` apart.
    public var maximumTimeGap: TimeInterval = 36 * 60 * 60
    public var maximumTripDistanceMeters: Double = 300_000
    /// Away photos further apart than this always start a new trip.
    public var maximumQuietGap: TimeInterval = 4 * 24 * 60 * 60
    public var locationlessMatchWindow: TimeInterval = 12 * 60 * 60
    /// Photos without a location and no located photo nearby count as
    /// away: right for a folder from a camera without GPS. In a phone
    /// library they are mostly screenshots and saved images, so daily life.
    public var locationlessDefaultsToAway = false
    /// Where a home is known, a stretch away becomes a trip with this many
    /// photos, or when it spans more than one day.
    public var minimumTripItems: Int = 5
    /// A home the person set; it replaces the detected one everywhere.
    public var homeCoordinate: GeoPoint?

    public init() {}

    /// `stops` are the photos to place. `context` adds photos already in the
    /// library: they tell where home is, lend their side to nearby photos
    /// without a location, and keep a few new photos next to a trip in it.
    public func segment(_ stops: [PhotoStop], context: [PhotoStop] = []) -> Result {
        let ordered = stops.sorted(by: Self.photoOrder)
        guard !ordered.isEmpty else { return Result(trips: [], homeIDs: []) }
        let home = HomeFinder(segmenter: self, stops: ordered + context)
        func isAway(_ coordinate: GeoPoint, at date: Date) -> Bool {
            home.homes(at: date).allSatisfy { coordinate.distance(to: $0) > awayRadiusMeters }
        }
        func homeKnown(at date: Date) -> Bool { !home.homes(at: date).isEmpty }

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
            return locationlessDefaultsToAway || !homeKnown(at: stop.date)
        }

        var runs: [[PhotoStop]] = []
        var current: [PhotoStop] = []
        var lastCoordinate: GeoPoint?
        for (index, stop) in ordered.enumerated() {
            guard away[index] else {
                if !current.isEmpty { runs.append(current); current = [] }
                lastCoordinate = nil
                continue
            }
            if let previous = current.last {
                let gap = stop.date.timeIntervalSince(previous.date)
                let far = lastCoordinate.flatMap { last in
                    stop.coordinate.map { last.distance(to: $0) > maximumTripDistanceMeters }
                } ?? false
                // Without a home, a quiet day and a half ends a trip as before.
                if gap > maximumQuietGap || (gap > maximumTimeGap && (far || !homeKnown(at: stop.date))) {
                    runs.append(current)
                    current = []
                }
            }
            current.append(stop)
            if let coordinate = stop.coordinate { lastCoordinate = coordinate }
        }
        if !current.isEmpty { runs.append(current) }

        var trips: [[String]] = []
        var homeIDs = Set(ordered.indices.filter { !away[$0] }.map { ordered[$0].id })
        for run in runs {
            guard let first = run.first, let last = run.last else { continue }
            // Without a home there is no daily life to fall back to, and a
            // few photos next to the library's photos away belong with them.
            let nextToLibraryAway = Self.lowerBound(last.date.addingTimeInterval(maximumTimeGap), in: libraryAway, inclusive: true)
                > Self.lowerBound(first.date.addingTimeInterval(-maximumTimeGap), in: libraryAway)
            if run.count >= minimumTripItems || spansSeveralDays(run) || !homeKnown(at: first.date) || nextToLibraryAway {
                trips.append(run.map(\.id))
            } else {
                homeIDs.formUnion(run.map(\.id))
            }
        }
        return Result(trips: trips, homeIDs: homeIDs)
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

/// Homes per 30-day bucket: the clusters of daily locations that hold enough
/// of the photo days within `homeWindowDays`.
private final class HomeFinder {
    private let fixed: GeoPoint?
    private let centres: [GeoPoint]
    private let daysByCluster: [[Int]]
    private let segmenter: TripSegmenter
    private var cache: [Int: [GeoPoint]] = [:]

    init(segmenter: TripSegmenter, stops: [PhotoStop]) {
        self.segmenter = segmenter
        fixed = segmenter.homeCoordinate
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
            if let cluster = centres.firstIndex(where: { $0.distance(to: point) <= segmenter.homeClusterRadiusMeters }) {
                days[cluster].append(day)
            } else {
                centres.append(point)
                days.append([day])
            }
        }
        self.centres = centres
        daysByCluster = days
    }

    func homes(at date: Date) -> [GeoPoint] {
        if let fixed { return [fixed] }
        let bucket = Int((Double(Self.day(of: date)) / 30).rounded(.down))
        if let cached = cache[bucket] { return cached }
        let found = home(bucket: bucket)
        cache[bucket] = found
        return found
    }

    private func home(bucket: Int) -> [GeoPoint] {
        let middle = bucket * 30 + 15
        let window = (middle - segmenter.homeWindowDays)...(middle + segmenter.homeWindowDays)
        let counts = daysByCluster.map { Self.count(of: window, in: $0) }
        let total = Double(counts.reduce(0, +))
        return counts.indices
            .filter { counts[$0] >= segmenter.minimumHomeDays && Double(counts[$0]) >= segmenter.minimumHomeShare * total }
            .filter { Self.months(of: window, in: daysByCluster[$0]) >= segmenter.minimumHomeMonths }
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

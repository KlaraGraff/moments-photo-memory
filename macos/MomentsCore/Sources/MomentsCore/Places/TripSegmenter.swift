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
        /// One entry per frequent place: the indices into the sorted photo
        /// list of its visits' photos, in date order. Those photos also stay
        /// inside `trips`. Empty while frequent places are off.
        public var frequentPlaces: [[Int]] = []
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
    /// A stay away near one place for this many days is a long-stay candidate:
    /// either daily life there or one long trip.
    public var minimumLongStayDays: Int = 21
    /// "Near one place" for a long stay means within this distance of it.
    public var longStayClusterRadiusMeters: Double = 50_000
    /// Photo days at the stay further apart than this belong to different stays,
    /// so monthly weekends at one town are many short visits, not one long stay.
    public var longStayMaximumQuietDays: Int = 21
    /// A long-stay candidate is daily life when fewer than this share of its days
    /// have photos, or when its median photos per photo day is at most
    /// `longStayMedianPhotosPerDay`; otherwise it is one long trip.
    public var longStayPhotoDayShare: Double = 0.5
    public var longStayMedianPhotosPerDay: Double = 3
    /// A stay that touches the start or the end of the library is a move when
    /// it spans more days than this; a shorter stay may simply end with the year.
    public var maximumEdgeStayDays: Int = 200
    /// A place the usual places call home on at least this share of the days
    /// spent there is a second home, so its days never form a frequent place.
    public var minimumSecondHomeShare: Double = 0.5

    /// Frequent places (常去的地方): a place more than `awayRadiusMeters` from
    /// home whose photo days form separate visits within a year. Each visit is
    /// a run of photo days at the place with a day at home before and after it;
    /// a run of `maximumVisitDays` or more is a stay, not a visit. Its photos
    /// stay trip-like segments in `trips` and are also one group in
    /// `Result.frequentPlaces`.
    public var detectsFrequentPlaces = true
    public var frequentPlaceRadiusMeters: Double = 25_000
    /// Separate visits needed within `frequentPlaceWindow` for a frequent place.
    public var minimumFrequentPlaceVisits: Int = 3
    public var frequentPlaceWindow: TimeInterval = 365 * 24 * 60 * 60
    /// A visit is shorter than this many days: a long stay is not a visit.
    public var maximumVisitDays: Int = 21

    /// Raise this whenever a change moves photos between trips and daily life,
    /// so libraries grouped by older rules are grouped again (`TripRegrouping`).
    /// 2: trips are time away from usual places (#99). 3: a trip stays together
    /// across quiet days far from home (#111). 4: long stays vs trips by photo
    /// density, the everyday place found by spread, and frequent places.
    public static let rulesVersion = 4

    public init() {}

    /// `stops` are the photos to place. `context` adds photos already in the
    /// library: they tell where the usual places are, lend their side to nearby photos
    /// without a location, and keep a few new photos next to a trip in it.
    public func segment(_ stops: [PhotoStop], context: [PhotoStop] = []) -> Result {
        let ordered = stops.sorted(by: Self.photoOrder)
        guard !ordered.isEmpty else { return Result(trips: [], atUsualPlaceIDs: []) }
        let photoIndex: [String: Int] = Dictionary(
            ordered.enumerated().map { (offset: Int, stop: PhotoStop) -> (String, Int) in
                (stop.id, offset)
            },
            uniquingKeysWith: { (first: Int, _: Int) -> Int in first }
        )
        let initialUsual = UsualPlaceFinder(segmenter: self, stops: ordered + context)
        // The everyday place, even in a year a long stay or a slow travel
        // takes most of the photo days: the place whose photo days are spread
        // over the most months. It tells a day at home from a day away when a
        // usual place alone cannot.
        let home = fixedUsualPlace ?? Self.spreadHome(segmenter: self, stops: ordered + context)
        // A long stay (or a slow travel that is one long trip) must not turn
        // its far place into a usual place, and a place that is only ever
        // visited on separate short trips is a frequent place, not a home:
        // both kinds of day stay out of the usual-place counts.
        // The day maps behind long stays, frequent places and home days see
        // the whole library, not only the photos being placed: home days in
        // the context must end a stay or a visit just as they do in a full
        // import (`TripRegrouping` passes only suggested trip photos as stops).
        let longStays = Self.longStays(segmenter: self, stops: ordered + context, usual: initialUsual, home: home)
        let frequent = Self.frequentPlaceVisits(
            segmenter: self,
            stops: ordered + context,
            usual: initialUsual,
            home: home,
            longStays: longStays
        )
        let excludedIDs: Set<String> = longStays.isEmpty && frequent.excludedIDs.isEmpty
            ? []
            : Self.longStayIDs(segmenter: self, stops: ordered + context, longStays: longStays)
                .union(frequent.excludedIDs)
        let usual: UsualPlaceFinder = excludedIDs.isEmpty
            ? initialUsual
            : UsualPlaceFinder(
                segmenter: self,
                stops: (ordered + context).filter { (stop: PhotoStop) -> Bool in !excludedIDs.contains(stop.id) }
            )
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

        // A long stay is judged by what was done there, not by its length.
        let forcedSide: [String: Bool] = {
            var sides: [String: Bool] = [:]
            for stay in longStays {
                for stop in ordered {
                    guard let coordinate = stop.coordinate,
                          stay.days.contains(Self.dayNumber(of: stop.date)),
                          coordinate.distance(to: stay.centre) <= longStayClusterRadiusMeters
                    else { continue }
                    sides[stop.id] = !stay.dailyLife
                }
            }
            return sides
        }()

        let located = (ordered + context)
            .compactMap { stop in
                stop.coordinate.map { coordinate in
                    (date: stop.date, away: forcedSide[stop.id] ?? isAway(coordinate, at: stop.date))
                }
            }
            .sorted { $0.date < $1.date }
        let locatedDates = located.map(\.date)
        let libraryAway = context
            .compactMap { stop in stop.coordinate.flatMap { isAway($0, at: stop.date) ? stop.date : nil } }
            .sorted()

        let away: [Bool] = ordered.map { stop in
            if let forced = forcedSide[stop.id] { return forced }
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
        var result = Result(trips: trips, atUsualPlaceIDs: atUsualPlaceIDs)
        if detectsFrequentPlaces {
            // A group holds trip photos only: a visit whose photos ended in
            // daily life is no frequent-place visit, and a place left with too
            // few visits that are trips is no frequent place.
            let tripIDs: Set<String> = Set(trips.flatMap { (trip: [String]) -> [String] in trip })
            let minimumVisits: Int = max(1, minimumFrequentPlaceVisits)
            var groups: [[Int]] = []
            for placeVisits in frequent.visits {
                let tripVisits: [[String]] = placeVisits
                    .map { (visit: [String]) -> [String] in
                        visit.filter { (id: String) -> Bool in tripIDs.contains(id) }
                    }
                    .filter { (visit: [String]) -> Bool in !visit.isEmpty }
                guard tripVisits.count >= minimumVisits else { continue }
                let indices: [Int] = tripVisits
                    .flatMap { (visit: [String]) -> [String] in visit }
                    .compactMap { (id: String) -> Int? in photoIndex[id] }
                guard !indices.isEmpty else { continue }
                groups.append(indices.sorted())
            }
            groups.sort { (left: [Int], right: [Int]) -> Bool in
                (left.first ?? Int.max) < (right.first ?? Int.max)
            }
            result.frequentPlaces = groups
        }
        return result
    }

    /// A frequent place exists before the trips are read: a place away from
    /// home whose photo days form three or more separate visits within a year,
    /// each shorter than three weeks, with a day at home between the visits.
    /// Its photos stay trip-like segments in `trips` and are also one group in
    /// `Result.frequentPlaces`.
    ///
    /// A long stay is no frequent place: its venue is left out here. A road
    /// trip that merely passes through is no visit either: the day before or
    /// after such a one-night stay sits at another far place, not at home.
    private struct FrequentVisits {
        /// Photo ids of each frequent place's visits, in date order, one inner
        /// array per visit.
        let visits: [[[String]]]
        /// Photos of the places that must not count as usual places: a place
        /// visited on separate short trips holds far less of the year than the
        /// home, so it is no everyday place.
        let excludedIDs: Set<String>
    }

    private static func frequentPlaceVisits(
        segmenter: TripSegmenter,
        stops: [PhotoStop],
        usual: UsualPlaceFinder,
        home: GeoPoint?,
        longStays: [LongStay]
    ) -> FrequentVisits {
        guard let home else { return FrequentVisits(visits: [], excludedIDs: []) }
        var pointsByDay: [Int: [GeoPoint]] = [:]
        var idsByDay: [Int: [String]] = [:]
        for stop in stops {
            let day = dayNumber(of: stop.date)
            idsByDay[day, default: []].append(stop.id)
            if let coordinate = stop.coordinate {
                pointsByDay[day, default: []].append(coordinate)
            }
        }
        let allDays: [Int] = pointsByDay.keys.sorted()
        guard let firstDay = allDays.first, let lastDay = allDays.last else {
            return FrequentVisits(visits: [], excludedIDs: [])
        }
        // One median point per photo day, read by home days, stay days and the
        // visit splits, so no day is measured twice.
        var medianByDay: [Int: GeoPoint] = [:]
        for day in allDays {
            guard let points = pointsByDay[day] else { continue }
            medianByDay[day] = median(points)
        }
        let homeDays: Set<Int> = Set(allDays.filter { (day: Int) -> Bool in
            guard let point = medianByDay[day] else { return false }
            return point.distance(to: home) <= segmenter.awayRadiusMeters
        })

        // Days of a long stay's venue are no visits: that is where someone
        // lives for a while, whether it is daily life or one long trip.
        var stayDays = Set<Int>()
        for stay in longStays {
            stayDays.formUnion(stay.days.filter { (day: Int) -> Bool in
                guard let point = medianByDay[day] else { return false }
                return point.distance(to: stay.centre) <= segmenter.longStayClusterRadiusMeters
            })
        }

        // Every day's one median point, grouped by place, stays left out.
        var centres: [GeoPoint] = []
        var daysByPlace: [[Int]] = []
        for day in allDays where !stayDays.contains(day) {
            guard let point = medianByDay[day] else { continue }
            let known: Int? = centres.firstIndex { (centre: GeoPoint) -> Bool in
                centre.distance(to: point) <= segmenter.frequentPlaceRadiusMeters
            }
            if let known {
                daysByPlace[known].append(day)
            } else {
                centres.append(point)
                daysByPlace.append([day])
            }
        }
        guard !centres.isEmpty else { return FrequentVisits(visits: [], excludedIDs: []) }
        // The homes: the everyday place, plus a second home such as the
        // parents' town, which the usual places call home on most of the days
        // spent there. A place that only holds a few separate visits is no
        // home, even when those visits add up to some days.
        var homeCentres: [GeoPoint] = [home]
        for index in centres.indices {
            let centre: GeoPoint = centres[index]
            guard homeCentres.allSatisfy({ (known: GeoPoint) -> Bool in known.distance(to: centre) > segmenter.awayRadiusMeters }) else {
                continue
            }
            let days: [Int] = daysByPlace[index]
            var usualDays = 0
            for day in days {
                let date = Date(timeIntervalSince1970: (Double(day) + 0.5) * 86_400)
                if usual.places(at: date).contains(where: { (place: GeoPoint) -> Bool in
                    place.distance(to: centre) <= segmenter.awayRadiusMeters
                }) {
                    usualDays += 1
                }
            }
            guard Double(usualDays) >= segmenter.minimumSecondHomeShare * Double(days.count) else { continue }
            homeCentres.append(centre)
        }
        func isHomeDay(_ day: Int) -> Bool {
            if homeDays.contains(day) { return true }
            guard let point = medianByDay[day] else { return false }
            return homeCentres.contains { (centre: GeoPoint) -> Bool in point.distance(to: centre) <= segmenter.awayRadiusMeters }
        }
        // Home days between two days, counted once for the whole library:
        // `homePrefix[d - firstDay]` is the number of home days before `d`.
        var homePrefix = [Int](repeating: 0, count: lastDay - firstDay + 2)
        for day in firstDay...lastDay {
            let before: Int = homePrefix[day - firstDay]
            homePrefix[day - firstDay + 1] = before + (isHomeDay(day) ? 1 : 0)
        }
        // A quiet stretch between two photo days at the place ends a visit
        // just as a day at home does, so a place seen only now and then stays
        // separate visits even when the library holds no photos at home.
        let quietDays: Int = Int((segmenter.maximumQuietGap / 86_400).rounded(.down))
        /// True when a whole day at home lies between two photo days, or when
        /// the two days are further apart than the maximum quiet gap.
        func splitByHome(_ first: Int, _ last: Int) -> Bool {
            guard last - first > 1 else { return false }
            if last - first > quietDays { return true }
            return homePrefix[last - firstDay] - homePrefix[first + 1 - firstDay] > 0
        }
        var places: [(firstDay: Int, visits: [[String]])] = []
        var excludedIDs = Set<String>()
        for (index, days) in daysByPlace.enumerated() {
            let centre: GeoPoint = centres[index]
            // A home is no frequent place, however often the person goes there.
            guard homeCentres.allSatisfy({ (known: GeoPoint) -> Bool in known.distance(to: centre) > segmenter.awayRadiusMeters }) else {
                continue
            }
            // Visits: runs of this place's photo days that a day at home ends.
            var runs: [[Int]] = []
            var current: [Int] = []
            for day in days.sorted() {
                if let previous = current.last, splitByHome(previous, day) {
                    runs.append(current)
                    current = []
                }
                current.append(day)
            }
            if !current.isEmpty { runs.append(current) }
            // A night between two other far places is a pass-through.
            func farDay(_ day: Int) -> Bool {
                guard let point = medianByDay[day] else { return false }
                return point.distance(to: home) > segmenter.awayRadiusMeters
                    && point.distance(to: centre) > segmenter.frequentPlaceRadiusMeters
            }
            let visits: [[Int]] = runs.filter { (run: [Int]) -> Bool in
                guard let first = run.first, let last = run.last else { return false }
                guard last - first + 1 < segmenter.maximumVisitDays else { return false }
                return !farDay(first - 1) && !farDay(last + 1)
            }
            let minimumVisits: Int = max(1, segmenter.minimumFrequentPlaceVisits)
            guard visits.count >= minimumVisits else { continue }
            // Three visits within twelve months.
            let firstDays: [Int] = visits.compactMap { (run: [Int]) -> Int? in run.first }
            let windowDays = Int((segmenter.frequentPlaceWindow / 86_400).rounded(.down))
            var enoughInWindow = false
            for start in 0...(firstDays.count - minimumVisits) {
                let lastIndex = start + minimumVisits - 1
                if firstDays[lastIndex] - firstDays[start] <= windowDays {
                    enoughInWindow = true
                    break
                }
            }
            guard enoughInWindow else { continue }
            guard let firstVisitDay = firstDays.first else { continue }
            var visitIDs: [[String]] = []
            for run in visits {
                var ids: [String] = []
                for day in run { ids.append(contentsOf: idsByDay[day] ?? []) }
                if !ids.isEmpty { visitIDs.append(ids) }
            }
            guard visitIDs.count >= minimumVisits else { continue }
            places.append((firstDay: firstVisitDay, visits: visitIDs))
            // A place visited on separate short trips is no home: its days
            // must not count towards the usual places of a half-year window.
            for run in visits {
                for day in run { excludedIDs.formUnion(idsByDay[day] ?? []) }
            }
        }
        let orderedPlaces: [(firstDay: Int, visits: [[String]])] = places.sorted { (left: (firstDay: Int, visits: [[String]]), right: (firstDay: Int, visits: [[String]])) -> Bool in
            left.firstDay < right.firstDay
        }
        return FrequentVisits(visits: orderedPlaces.map(\.visits), excludedIDs: excludedIDs)
    }

    /// The photo ids of the days that belong to a long stay's venue.
    private static func longStayIDs(segmenter: TripSegmenter, stops: [PhotoStop], longStays: [LongStay]) -> Set<String> {
        guard !longStays.isEmpty else { return [] }
        var ids = Set<String>()
        for stop in stops {
            guard let coordinate = stop.coordinate else { continue }
            let day = dayNumber(of: stop.date)
            for stay in longStays where stay.days.contains(day) {
                if coordinate.distance(to: stay.centre) <= segmenter.longStayClusterRadiusMeters {
                    ids.insert(stop.id)
                }
            }
        }
        return ids
    }

    /// The place whose photo days spread over the most months: the everyday
    /// place, even in a year where a long stay takes most of the photo days.
    /// Ties go to the place with more days, then to the earlier one.
    private static func spreadHome(segmenter: TripSegmenter, stops: [PhotoStop]) -> GeoPoint? {
        var pointsByDay: [Int: [GeoPoint]] = [:]
        for stop in stops {
            guard let coordinate = stop.coordinate else { continue }
            pointsByDay[dayNumber(of: stop.date), default: []].append(coordinate)
        }
        var centres: [GeoPoint] = []
        var daysByCluster: [Set<Int>] = []
        for day in pointsByDay.keys.sorted() {
            let point = median(pointsByDay[day] ?? [])
            let known: Int? = centres.firstIndex { (centre: GeoPoint) -> Bool in
                centre.distance(to: point) <= segmenter.usualPlaceClusterRadiusMeters
            }
            if let known {
                daysByCluster[known].insert(day)
            } else {
                centres.append(point)
                daysByCluster.append([day])
            }
        }
        var best: (index: Int, months: Int, days: Int)?
        for index in centres.indices {
            let days: Set<Int> = daysByCluster[index]
            let months: Int = Set(days.map { (day: Int) -> Int in Int((Double(day) / 30).rounded(.down)) }).count
            if let current = best {
                let better: Bool = months > current.months || (months == current.months && days.count > current.days)
                if better { best = (index: index, months: months, days: days.count) }
            } else {
                best = (index: index, months: months, days: days.count)
            }
        }
        guard let best else { return nil }
        return centres[best.index]
    }

    private static func photoOrder(_ lhs: PhotoStop, _ rhs: PhotoStop) -> Bool {
        lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date < rhs.date
    }

    /// One stay away, judged by what was done there.
    private struct LongStay {
        /// The centre of the stay's own photo days.
        let centre: GeoPoint
        /// Every day the stay covers, from its first to its last photo day.
        let days: ClosedRange<Int>
        /// True when the stay is daily life there, false when it is one long trip.
        let dailyLife: Bool
    }

    /// Finds stays away from home that last `minimumLongStayDays` days or more
    /// near one place, and decides for each whether it was daily life (a long
    /// stay) or one long trip.
    ///
    /// Days are grouped by place first, so a weekend excursion out of a stay is
    /// a place of its own and does not cut the stay in two. Days at home end a
    /// stay, so short visits to one town stay separate visits. The place
    /// someone lives at touches the start or the end of the library.
    private static func longStays(
        segmenter: TripSegmenter,
        stops: [PhotoStop],
        usual: UsualPlaceFinder,
        home: GeoPoint?
    ) -> [LongStay] {
        var pointsByDay: [Int: [GeoPoint]] = [:]
        var photosByDay: [Int: Int] = [:]
        for stop in stops {
            guard let coordinate = stop.coordinate else { continue }
            let day = dayNumber(of: stop.date)
            pointsByDay[day, default: []].append(coordinate)
            photosByDay[day, default: 0] += 1
        }
        let allDays: [Int] = pointsByDay.keys.sorted()
        guard let firstDay = allDays.first, let lastDay = allDays.last else { return [] }

        // One median point per day, clustered by place: a day's point joins the
        // first place whose centre is within `longStayClusterRadiusMeters`.
        var centres: [GeoPoint] = []
        var daysByPlace: [[Int]] = []
        for day in allDays {
            let point = median(pointsByDay[day] ?? [])
            let known: Int? = centres.firstIndex { (centre: GeoPoint) -> Bool in
                centre.distance(to: point) <= segmenter.longStayClusterRadiusMeters
            }
            if let known {
                daysByPlace[known].append(day)
            } else {
                centres.append(point)
                daysByPlace.append([day])
            }
        }

        // The library's half-year windows, each with the usual places read
        // once. A window outside a stay that calls the stay's place home means
        // the person lives there at another time of the library: the stay is
        // part of a move, not a long trip.
        let firstBucket: Int = Int((Double(firstDay) / 30).rounded(.down))
        let lastBucket: Int = Int((Double(lastDay) / 30).rounded(.down))
        var windows: [(window: ClosedRange<Int>, places: [GeoPoint])] = []
        for bucket in firstBucket...lastBucket {
            let middle = bucket * 30 + 15
            let window: ClosedRange<Int> = (middle - segmenter.usualPlaceWindowDays)...(middle + segmenter.usualPlaceWindowDays)
            let date = Date(timeIntervalSince1970: (Double(middle) + 0.5) * 86_400)
            windows.append((window: window, places: usual.places(at: date)))
        }
        func isUsualPlaceOutside(_ span: ClosedRange<Int>, centre: GeoPoint) -> Bool {
            for entry in windows {
                guard entry.window.upperBound < span.lowerBound || entry.window.lowerBound > span.upperBound else { continue }
                if entry.places.contains(where: { (place: GeoPoint) -> Bool in
                    place.distance(to: centre) <= segmenter.longStayClusterRadiusMeters
                }) {
                    return true
                }
            }
            return false
        }

        var stays: [LongStay] = []
        for (index, days) in daysByPlace.enumerated() {
            let centre = centres[index]
            // A long stay is away from home: the everyday place itself is no
            // stay, however sparse its photo days look.
            if let home, centre.distance(to: home) <= segmenter.awayRadiusMeters { continue }
            for run in stayRuns(days, maximumQuietDays: segmenter.longStayMaximumQuietDays) {
                for part in stayRunsWithoutHomeDays(
                    run,
                    centre: centre,
                    segmenter: segmenter,
                    usual: usual,
                    home: home,
                    pointsByDay: pointsByDay
                ) {
                    guard let first = part.first, let last = part.last else { continue }
                    let span = first...last
                    guard span.count >= segmenter.minimumLongStayDays else { continue }
                    // A long stay longer than a few months is a move, whether
                    // it touches the edge of the library or not: a year in one
                    // city is where someone lived, not one long trip.
                    guard span.count <= segmenter.maximumEdgeStayDays else { continue }
                    // The same place called home at another time of the
                    // library is a move as well, edge or not.
                    guard !isUsualPlaceOutside(span, centre: centre) else { continue }
                    let counts: [Int] = part.map { (day: Int) -> Int in photosByDay[day] ?? 0 }.sorted()
                    guard !counts.isEmpty else { continue }
                    let photoDayShare = Double(part.count) / Double(span.count)
                    let medianPhotos = counts[counts.count / 2]
                    let dailyLife = photoDayShare < segmenter.longStayPhotoDayShare
                        || Double(medianPhotos) <= segmenter.longStayMedianPhotosPerDay
                    stays.append(LongStay(centre: centre, days: span, dailyLife: dailyLife))
                }
            }
        }
        return stays
    }

    /// Splits sorted photo days into stretches without a gap longer than
    /// `maximumQuietDays`, so monthly weekends at one town stay separate visits.
    private static func stayRuns(_ days: [Int], maximumQuietDays: Int) -> [[Int]] {
        var runs: [[Int]] = []
        var current: [Int] = []
        for day in days {
            if let previous = current.last, day - previous > maximumQuietDays {
                runs.append(current)
                current = []
            }
            current.append(day)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Cuts a run wherever a day at home lies between two days at the place.
    private static func stayRunsWithoutHomeDays(
        _ run: [Int],
        centre: GeoPoint,
        segmenter: TripSegmenter,
        usual: UsualPlaceFinder,
        home: GeoPoint?,
        pointsByDay: [Int: [GeoPoint]]
    ) -> [[Int]] {
        var parts: [[Int]] = []
        var current: [Int] = []
        for day in run {
            let previous: Int? = current.last
            if let previous, isHomeDay(
                between: previous,
                and: day,
                awayFrom: centre,
                segmenter: segmenter,
                usual: usual,
                home: home,
                pointsByDay: pointsByDay
            ) {
                parts.append(current)
                current = []
            }
            current.append(day)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// True when a day between `first` and `last` lies at a usual place other
    /// than the one being judged: then the person went home in between.
    private static func isHomeDay(
        between first: Int,
        and last: Int,
        awayFrom centre: GeoPoint,
        segmenter: TripSegmenter,
        usual: UsualPlaceFinder,
        home: GeoPoint?,
        pointsByDay: [Int: [GeoPoint]]
    ) -> Bool {
        guard last - first > 1 else { return false }
        for day in (first + 1)..<last {
            guard let points = pointsByDay[day] else { continue }
            let point = median(points)
            if let home, point.distance(to: home) <= segmenter.awayRadiusMeters { return true }
            let date = Date(timeIntervalSince1970: (Double(day) + 0.5) * 86_400)
            let homes: [GeoPoint] = usual.places(at: date).filter { (place: GeoPoint) -> Bool in
                place.distance(to: centre) > segmenter.awayRadiusMeters
            }
            for home in homes where point.distance(to: home) <= segmenter.awayRadiusMeters {
                return true
            }
        }
        return false
    }

    /// The per-axis median keeps one stray photo from moving the day.
    private static func median(_ points: [GeoPoint]) -> GeoPoint {
        let latitudes = points.map(\.latitude).sorted()
        let longitudes = points.map(\.longitude).sorted()
        return GeoPoint(latitude: latitudes[latitudes.count / 2], longitude: longitudes[longitudes.count / 2])
    }

    /// Days since the epoch, so photo days can be counted.
    private static func dayNumber(of date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
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

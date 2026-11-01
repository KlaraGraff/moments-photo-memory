import Foundation
import MomentsCore
import XCTest
@testable import Moments

/// The faster TimelineBuilder must return exactly what the old one did. The
/// old one is kept here, unchanged apart from its name, as the reference.
final class TimelineBuilderEquivalenceTests: XCTestCase {
    func testSameDocumentAsTheReferenceBuilder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        for seed in [1, 2, 3, 5, 8, 13, 21, 34] as [UInt64] {
            var random = EquivalenceRandom(seed: seed)
            let count = 40 + Int(random.below(360))
            let (items, trips) = Self.library(count: count, random: &random)
            let fast = TimelineBuilder(calendar: calendar).build(items: items, trips: trips)
            let reference = ReferenceTimelineBuilder(calendar: calendar).build(items: items, trips: trips)
            XCTAssertEqual(Self.dump(fast), Self.dump(reference), "seed \(seed), \(count) photos")
            // Every photo in one stream, as the Timeline page builds it.
            let fastStream = TimelineBuilder(calendar: calendar).build(items: items, trips: [])
            let referenceStream = ReferenceTimelineBuilder(calendar: calendar).build(items: items, trips: [])
            XCTAssertEqual(Self.dump(fastStream), Self.dump(referenceStream), "stream, seed \(seed)")
        }
    }

    private static func library(count: Int, random: inout EquivalenceRandom) -> ([TimelineItemSnapshot], [TimelineSourceTrip]) {
        // Typed step by step throughout: the CI compilers cannot type-check
        // long literal arithmetic mixed with optionals in reasonable time.
        let centres: [(Double, Double)] = (0..<6).map { (_: Int) -> (Double, Double) in
            let latitude: Double = random.unit() * 120 - 60
            let longitude: Double = random.unit() * 340 - 170
            return (latitude, longitude)
        }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let hints: [String?] = [nil, "", "Harbour", "Old Town", "Spot 7", nil, "Market"]
        var items: [TimelineItemSnapshot] = []
        for index in 0..<count {
            let centre = centres[Int(random.below(UInt64(centres.count)))]
            let located = random.unit() > 0.15
            let dated = random.unit() > 0.05
            // Same order of random draws as the one-expression form it replaces.
            var date: Date?
            if dated {
                let seconds: Double = Double(index) * 3_600 * (0.5 + random.unit())
                date = origin.addingTimeInterval(seconds)
            }
            let tripRoll = random.below(10)
            var latitude: Double?
            var longitude: Double?
            if located {
                let latitudeJitter: Double = (random.unit() - 0.5) * 0.6
                latitude = centre.0 + latitudeJitter
                let longitudeJitter: Double = (random.unit() - 0.5) * 0.6
                longitude = centre.1 + longitudeJitter
            }
            let isVideo = random.unit() < 0.1
            let kindRaw: String = isVideo ? MediaKind.video.rawValue : MediaKind.photo.rawValue
            let tripID: String?
            if tripRoll < 3 {
                tripID = "trip-\(tripRoll)"
            } else if tripRoll == 3 {
                tripID = "missing-trip"
            } else {
                tripID = nil
            }
            let placeHint: String? = hints[Int(random.below(UInt64(hints.count)))]
            var dayKey: String?
            if let date, random.unit() < 0.5 {
                dayKey = PhotoNoteDay.key(for: date, calendar: Calendar(identifier: .gregorian))
            }
            items.append(TimelineItemSnapshot(
                id: "item-\(index)",
                title: "Photo \(index)",
                date: date,
                latitude: latitude,
                longitude: longitude,
                kindRaw: kindRaw,
                tripID: tripID,
                placeHint: placeHint,
                dayKey: dayKey
            ))
        }
        let trips: [TimelineSourceTrip] = (0..<3).map { (trip: Int) -> TimelineSourceTrip in
            let itemIDs: [String] = items.filter { _ in random.unit() < 0.1 }.map(\.id)
            let startDate: Date? = trip == 0 ? origin : nil
            let endDate: Date? = trip == 0 ? origin.addingTimeInterval(3 * 86_400) : nil
            return TimelineSourceTrip(
                id: "trip-\(trip)",
                name: "Trip \(trip)",
                itemIDs: itemIDs,
                startDate: startDate,
                endDate: endDate
            )
        }
        return (items, trips)
    }

    private static func dump(_ document: TimelineDocument) -> [String] {
        var lines: [String] = []
        for trip in document.trips {
            lines.append("trip \(trip.id) \(trip.name) \(String(describing: trip.startDate)) \(String(describing: trip.plannedEndDate))")
            for day in trip.days {
                lines.append("  day \(day.id) \(String(describing: day.date)) \(day.memoryKey ?? "-")")
                for event in day.events {
                    switch event {
                    case let .place(place):
                        lines.append("    place \(place.id) \(String(describing: place.date)) \(place.name ?? "-") \(place.cityName ?? "-") \(place.itemIDs)")
                    case let .travel(travel):
                        lines.append("    travel \(travel.id) \(String(describing: travel.date)) \(travel.fromName ?? "-") \(travel.toName ?? "-") \(Int(travel.distanceMeters)) \(travel.fromStopID ?? "-") \(travel.toStopID ?? "-")")
                    }
                }
            }
        }
        return lines
    }
}

private struct EquivalenceRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func below(_ bound: UInt64) -> UInt64 { next() % bound }
}

// MARK: The builder as it was before it was made fast (reference only).

struct ReferenceTimelineBuilder {
    /// The trip that collects photos which belong to no trip.
    static let unassignedTripID = TimelineBuilder.unassignedTripID
    let clusterer: PlaceClusterer
    var calendar: Calendar

    init(clusterer: PlaceClusterer = PlaceClusterer(), calendar: Calendar = .autoupdatingCurrent) {
        self.clusterer = clusterer
        self.calendar = calendar
    }

    func build(items: [TimelineItemSnapshot], trips: [TimelineSourceTrip]) -> TimelineDocument {
        let uniqueItems = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var itemTripIDs: [String: String] = [:]
        for trip in trips {
            for itemID in trip.itemIDs where uniqueItems[itemID] != nil {
                itemTripIDs[itemID] = trip.id
            }
        }

        // Photos whose trip is missing join the photos that are in no trip.
        let knownTripIDs = Set(trips.map(\.id))
        var itemsByTrip: [String: [TimelineItemSnapshot]] = [:]
        for item in uniqueItems.values {
            var tripID = itemTripIDs[item.id] ?? item.tripID ?? Self.unassignedTripID
            if !knownTripIDs.contains(tripID) { tripID = Self.unassignedTripID }
            itemsByTrip[tripID, default: []].append(item)
        }

        var definitions = trips
        if itemsByTrip[Self.unassignedTripID] != nil, !knownTripIDs.contains(Self.unassignedTripID) {
            definitions.append(TimelineSourceTrip(id: Self.unassignedTripID, name: "Unsorted memories"))
        }

        let builtTrips = definitions.map { definition in
            makeTrip(
                definition: definition,
                items: itemsByTrip[definition.id] ?? []
            )
        }
        .sorted(by: tripOrder)

        return TimelineDocument(trips: builtTrips)
    }

    private func makeTrip(definition: TimelineSourceTrip, items: [TimelineItemSnapshot]) -> TimelineTrip {
        let orderedItems = items.sorted(by: itemOrder)
        let stops = orderedItems.compactMap(\.photoStop)
        let spotClusters = clusterer.clusters(for: stops, level: .spot)
        let cityClusters = clusterer.clusters(for: stops, level: .city)
        let spotByItemID = clusterMap(spotClusters)
        let cityByItemID = clusterMap(cityClusters)

        var dayGroups: [RefDayKey: [RefPlaceGroup]] = [:]
        for item in orderedItems {
            let dayKey = makeRefDayKey(for: item)
            let spot = item.photoStop.flatMap { spotByItemID[$0.id] }
            let placeKey = spot?.id ?? fallbackPlaceKey(for: item)
            let city = item.photoStop.flatMap { cityByItemID[$0.id] }
            let cityName = city.flatMap { clusterName($0, items: orderedItems) }
            let placeName = spot.flatMap { clusterName($0, items: orderedItems) }

            if let index = dayGroups[dayKey]?.firstIndex(where: { $0.key == placeKey }) {
                dayGroups[dayKey]?[index].items.append(item)
                if dayGroups[dayKey]?[index].name == nil {
                    dayGroups[dayKey]?[index].name = placeName ?? item.placeHint
                }
                if dayGroups[dayKey]?[index].cityName == nil {
                    dayGroups[dayKey]?[index].cityName = cityName ?? item.placeHint
                }
            } else {
                dayGroups[dayKey, default: []].append(
                    RefPlaceGroup(
                        key: placeKey,
                        date: item.date,
                        name: placeName ?? item.placeHint,
                        cityName: cityName ?? item.placeHint,
                        items: [item]
                    )
                )
            }
        }

        let places = dayGroups.flatMap { dayKey, groups in
            groups.map { (dayKey, $0) }
        }.map { dayKey, group in
            TimelinePlace(
                id: placeID(tripID: definition.id, dayKey: dayKey, placeKey: group.key),
                date: group.items.min(by: itemOrder)?.date,
                name: group.name,
                cityName: group.cityName,
                items: group.items.sorted(by: itemOrder)
            )
        }

        let routes = RouteBuilder(stops: stops, clusterer: clusterer).overview()
        let travelByPlaceID = routes.reduce(into: [String: [TimelineTravel]]()) { result, segment in
            guard let targetID = segment.toStopID,
                  let target = places.first(where: { $0.itemIDs.contains(targetID) }) else { return }
            let fromName = clusterName(segment.from, items: orderedItems)
            let toName = clusterName(segment.to, items: orderedItems)
            let travel = TimelineTravel(
                id: "\(definition.id)|travel|\(segment.id)|\(target.id)",
                date: orderedItems.first(where: { $0.id == targetID })?.date,
                fromName: fromName,
                toName: toName,
                distanceMeters: segment.distanceMeters,
                fromStopID: segment.fromStopID,
                toStopID: segment.toStopID
            )
            result[target.id, default: []].append(travel)
        }

        let dayValues = dayGroups.keys.sorted(by: dayOrder).map { dayKey in
            let dayPlaces = places
                .filter { place in
                    dayGroups[dayKey]?.contains(where: {
                        placeID(tripID: definition.id, dayKey: dayKey, placeKey: $0.key) == place.id
                    }) ?? false
                }
                .sorted(by: placeOrder)
            var events: [TimelineEvent] = []
            for place in dayPlaces {
                let travel = (travelByPlaceID[place.id] ?? []).sorted { travelOrder($0, $1) }
                events.append(contentsOf: travel.map(TimelineEvent.travel))
                events.append(.place(place))
            }
            return TimelineDay(
                id: "\(definition.id)|day|\(dayKey.id)",
                date: dayKey.date,
                events: events,
                memoryKey: dayKey.key
            )
        }

        return TimelineTrip(
            id: definition.id,
            name: definition.name,
            days: dayValues,
            startDate: definition.startDate ?? orderedItems.compactMap(\.date).min(),
            plannedEndDate: definition.endDate
        )
    }

    /// Days follow the photo's own local day (the key day memories are stored
    /// under), so a trip abroad is not split or merged by the Mac's time zone.
    /// Photos without one fall back to the builder's calendar.
    private func makeRefDayKey(for item: TimelineItemSnapshot) -> RefDayKey {
        if let key = item.dayKey, let date = dayStart(fromKey: key) {
            return RefDayKey(date: date, key: key)
        }
        guard let date = item.date else { return RefDayKey(date: nil, key: nil) }
        let start = calendar.startOfDay(for: date)
        return RefDayKey(date: start, key: PhotoNoteDay.key(for: start, calendar: calendar))
    }

    private func dayStart(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func placeID(tripID: String, dayKey: RefDayKey, placeKey: String) -> String {
        "\(tripID)|day|\(dayKey.id)|place|\(placeKey)"
    }

    private func clusterMap(_ clusters: [PlaceCluster]) -> [String: PlaceCluster] {
        clusters.reduce(into: [:]) { result, cluster in
            for stopID in cluster.stopIDs { result[stopID] = cluster }
        }
    }

    private func clusterName(_ cluster: PlaceCluster, items: [TimelineItemSnapshot]) -> String? {
        if let name = cluster.name, !name.isEmpty { return name }
        return cluster.stopIDs
            .compactMap { stopID in items.first(where: { $0.id == stopID })?.placeHint }
            .first(where: { !$0.isEmpty })
    }

    private func fallbackPlaceKey(for item: TimelineItemSnapshot) -> String {
        let hint = item.placeHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hint, !hint.isEmpty { return "fallback:\(hint)" }
        return "fallback:unlocated"
    }

    private func dayOrder(_ lhs: RefDayKey, _ rhs: RefDayKey) -> Bool {
        switch (lhs.date, rhs.date) {
        case let (left?, right?): return left == right ? lhs.id < rhs.id : left < right
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.id < rhs.id
        }
    }

    private func tripOrder(_ lhs: TimelineTrip, _ rhs: TimelineTrip) -> Bool {
        switch (lhs.startDate, rhs.startDate) {
        case let (left?, right?): return left == right ? lhs.id < rhs.id : left < right
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.id < rhs.id
        }
    }

    private func placeOrder(_ lhs: TimelinePlace, _ rhs: TimelinePlace) -> Bool {
        switch (lhs.date, rhs.date) {
        case let (left?, right?): return left == right ? lhs.id < rhs.id : left < right
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.id < rhs.id
        }
    }

    private func travelOrder(_ lhs: TimelineTravel, _ rhs: TimelineTravel) -> Bool {
        switch (lhs.date, rhs.date) {
        case let (left?, right?): return left == right ? lhs.id < rhs.id : left < right
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.id < rhs.id
        }
    }

    private func itemOrder(_ lhs: TimelineItemSnapshot, _ rhs: TimelineItemSnapshot) -> Bool {
        switch (lhs.date, rhs.date) {
        case let (left?, right?): return left == right ? lhs.id < rhs.id : left < right
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.id < rhs.id
        }
    }
}

private struct RefDayKey: Hashable {
    /// Start of the day in the builder's calendar, for headers and ordering.
    let date: Date?
    /// `yyyy-MM-dd`, the key day memories are stored under.
    let key: String?

    var id: String { key ?? "undated" }
}

private struct RefPlaceGroup {
    let key: String
    let date: Date?
    var name: String?
    var cityName: String?
    var items: [TimelineItemSnapshot]
}

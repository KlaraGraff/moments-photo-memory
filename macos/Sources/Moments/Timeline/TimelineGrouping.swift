import Foundation
import MomentsCore

/// Builds the stable trip → day → place hierarchy and inserts major city
/// moves immediately before the place where the move ends.
struct TimelineBuilder {
    /// The trip that collects photos which belong to no trip.
    static let unassignedTripID = "unassigned"
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
        let placeHints = Dictionary(
            orderedItems.map { ($0.id, $0.placeHint) },
            uniquingKeysWith: { first, _ in first }
        )
        let stops = orderedItems.compactMap(\.photoStop)
        let spotClusters = clusterer.clusters(for: stops, level: .spot)
        let cityClusters = clusterer.clusters(for: stops, level: .city)
        let spotByItemID = clusterMap(spotClusters)
        let cityByItemID = clusterMap(cityClusters)

        var dayGroups: [DayKey: [PlaceGroup]] = [:]
        for item in orderedItems {
            let dayKey = makeDayKey(for: item)
            let spot = item.photoStop.flatMap { spotByItemID[$0.id] }
            let placeKey = spot?.id ?? fallbackPlaceKey(for: item)
            let city = item.photoStop.flatMap { cityByItemID[$0.id] }
            let cityName = city.flatMap { clusterName($0, placeHints: placeHints) }
            let placeName = spot.flatMap { clusterName($0, placeHints: placeHints) }

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
                    PlaceGroup(
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
            let fromName = clusterName(segment.from, placeHints: placeHints)
            let toName = clusterName(segment.to, placeHints: placeHints)
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
    private func makeDayKey(for item: TimelineItemSnapshot) -> DayKey {
        if let key = item.dayKey, let date = dayStart(fromKey: key) {
            return DayKey(date: date, key: key)
        }
        guard let date = item.date else { return DayKey(date: nil, key: nil) }
        let start = calendar.startOfDay(for: date)
        return DayKey(date: start, key: PhotoNoteDay.key(for: start, calendar: calendar))
    }

    private func dayStart(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func placeID(tripID: String, dayKey: DayKey, placeKey: String) -> String {
        "\(tripID)|day|\(dayKey.id)|place|\(placeKey)"
    }

    private func clusterMap(_ clusters: [PlaceCluster]) -> [String: PlaceCluster] {
        clusters.reduce(into: [:]) { result, cluster in
            for stopID in cluster.stopIDs { result[stopID] = cluster }
        }
    }

    private func clusterName(_ cluster: PlaceCluster, placeHints: [String: String?]) -> String? {
        if let name = cluster.name, !name.isEmpty { return name }
        return cluster.stopIDs
            .compactMap { placeHints[$0] ?? nil }
            .first(where: { !$0.isEmpty })
    }

    private func fallbackPlaceKey(for item: TimelineItemSnapshot) -> String {
        let hint = item.placeHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hint, !hint.isEmpty { return "fallback:\(hint)" }
        return "fallback:unlocated"
    }

    private func dayOrder(_ lhs: DayKey, _ rhs: DayKey) -> Bool {
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

private struct DayKey: Hashable {
    /// Start of the day in the builder's calendar, for headers and ordering.
    let date: Date?
    /// `yyyy-MM-dd`, the key day memories are stored under.
    let key: String?

    var id: String { key ?? "undated" }
}

private struct PlaceGroup {
    let key: String
    let date: Date?
    var name: String?
    var cityName: String?
    var items: [TimelineItemSnapshot]
}

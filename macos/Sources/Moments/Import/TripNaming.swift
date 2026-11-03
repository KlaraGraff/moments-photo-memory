import Foundation
import MomentsCore
import SwiftData

/// Default trip names: where, then when. "Shanghai · Chongqing · Wulong
/// April 2026" for up to three cities, the country for a longer trip in one
/// country ("Morocco August 2026"), and just the month when nothing is known
/// about the places. Names a person typed (`Trip.overrideName`) are never touched.
enum TripNaming {
    static func name(
        cities: [String],
        countries: [String],
        start: Date?,
        index: Int,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        let place = placePart(cities: cities, countries: countries)
        guard let start else {
            return place ?? String(localized: "Trip") + " " + String(index)
        }
        let when = month(start, locale: locale, calendar: calendar)
        guard let place else { return String(localized: "Trip") + " " + when }
        return place + " " + when
    }

    /// "August 2026", the date half of a default name.
    static func month(_ date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle.dateTime.year().month(.wide).locale(locale)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    static func placePart(cities: [String], countries: [String]) -> String? {
        let cities = unique(cities)
        let countries = unique(countries)
        if !cities.isEmpty, cities.count <= 3 { return cities.joined(separator: " · ") }
        if !countries.isEmpty, countries.count <= 3 { return countries.joined(separator: " · ") }
        if cities.isEmpty { return nil }
        return cities.prefix(3).joined(separator: " · ")
    }

    /// The names the import gave before trips were named after places:
    /// "Trip 2026-08-20" in whichever language the import ran in.
    static func isOldDefaultName(_ name: String) -> Bool {
        name.range(of: #"^(Trip|旅程|Reise) \d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// Names given while the trip's places were still unknown: the old date
    /// names, "Trip August 2026", "旅程 2026年8月" and "Trip 3", in any
    /// language the import ran in. They get the places once the cities are
    /// named. Any month matches: the trip's dates may have moved since, and a
    /// name someone typed lives in `overrideName`, never here.
    static func isPlacelessDefaultName(_ name: String) -> Bool {
        if isOldDefaultName(name) { return true }
        let pattern = #"^(Trip|旅程|Reise) (\d+|\p{L}+\.? \d{4}|\d{4}年\d{1,2}月)$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Renames trips that still carry a default name without places to the
/// place-and-date name, once the cities are named. A trip with more than
/// three cities needs its country: one lookup for its first and one for its
/// last city, through the shared cache and paced like the place backfill.
struct TripNameBackfill: Sendable {
    let geocoder: any ImportGeocoder
    let geocodeCache: ImportGeocodeCache
    /// Waits until one lookup may start; the default draws on the pacer shared
    /// with imports and the place backfill. Tests pass an empty closure.
    var pace: @Sendable () async -> Void = { await ImportGeocodePacer.shared.wait() }
    var timeout: Duration = .seconds(10)

    /// `onlyFullyNamed` is for a run in the middle of naming cities: a trip
    /// renamed early with only some of its cities would lose its date-only
    /// default name and never be renamed again, so it waits until every city
    /// its photos fall in has a name. The scheduler's final run passes false.
    @discardableResult
    func run(container: ModelContainer, onlyFullyNamed: Bool = false) async throws -> Int {
        let context = ModelContext(container)
        let trips = try context.fetch(FetchDescriptor<Trip>()).filter {
            $0.overrideName == nil
                && TripNaming.isPlacelessDefaultName($0.name)
        }
        var renamed = 0
        for trip in trips {
            try Task.checkCancellation()
            let cities = Self.orderedCities(of: trip)
            guard !cities.isEmpty else { continue }
            if onlyFullyNamed, Self.hasUnnamedCity(trip) { continue }
            var countries: [String] = []
            if Set(cities.map(\.name)).count > 3 {
                let ends = cities.count > 1 ? [cities[0], cities[cities.count - 1]] : [cities[0]]
                var countryMissing = false
                for city in ends {
                    if let country = try await country(of: city.coordinate) {
                        countries.append(country)
                    } else {
                        countryMissing = true
                    }
                }
                // A mid-run rename must not freeze a partial name: a trip of
                // more than three cities that lost a country lookup would get a
                // name built from some of its countries only, and the backfill
                // never renames a trip that already holds places. The final run
                // (`onlyFullyNamed: false`) tries again.
                if onlyFullyNamed, countryMissing { continue }
            }
            let start = trip.startDate ?? trip.orderedItems.compactMap(\.captureDate).first
            trip.name = TripNaming.name(cities: cities.map(\.name), countries: countries, start: start, index: 1)
            trip.updatedAt = .now
            renamed += 1
        }
        if renamed > 0 { try context.save() }
        await geocodeCache.persist()
        return renamed
    }

    /// True when a city one of the trip's photos falls in still has no name.
    /// An empty name is exactly the work the place backfill still has to do,
    /// so the trip waits for it instead of freezing a half-named place into
    /// its name.
    static func hasUnnamedCity(_ trip: Trip) -> Bool {
        cityPlaces(of: trip.orderedItems).contains { city in
            city.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The cities the trip's photos fall in, in the order the photos first
    /// reach them, named or not.
    static func cityPlaces(of items: [MediaItem]) -> [Place] {
        let items = items.sorted { ($0.captureDate ?? .distantPast, $0.id) < ($1.captureDate ?? .distantPast, $1.id) }
        var seen = Set<String>()
        var result: [Place] = []
        for item in items {
            var current = item.place
            var depth = 0
            while let place = current, place.kind != .city, depth < 4 {
                current = place.parent
                depth += 1
            }
            guard let city = current, city.kind == .city, seen.insert(city.id).inserted else { continue }
            result.append(city)
        }
        return result
    }

    /// Named cities in the order the trip's photos first reach them.
    static func orderedCities(of trip: Trip) -> [(name: String, coordinate: GeoPoint?)] {
        orderedCities(of: trip.orderedItems)
    }

    /// Named cities in the order these photos, sorted by date, first reach them.
    static func orderedCities(of items: [MediaItem]) -> [(name: String, coordinate: GeoPoint?)] {
        cityPlaces(of: items).compactMap { city in
            guard let name = PlaceDisplayName.resolvedName(of: city) else { return nil }
            let coordinate = city.latitude.flatMap { latitude in
                city.longitude.map { GeoPoint(latitude: latitude, longitude: $0) }
            }
            return (name, coordinate)
        }
    }

    private func country(of coordinate: GeoPoint?) async throws -> String? {
        guard let coordinate else { return nil }
        if let cached = await geocodeCache.result(for: coordinate), let country = cached.country {
            return country
        }
        await pace()
        // A cancelled wait must end the run, not send a lookup.
        try Task.checkCancellation()
        let geocoder = self.geocoder
        let result: ImportGeocodeResult?
        do {
            result = try await ImportGeocodeGate.firstResult(within: timeout) {
                try await geocoder.reverseGeocode(coordinate: coordinate)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        guard let result else { return nil }
        await geocodeCache.insert(result, for: coordinate)
        return result.country
    }
}

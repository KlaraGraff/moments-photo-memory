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

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Renames trips that still carry an old date-only default name to the
/// place-and-date name, once the cities are named. A trip with more than
/// three cities needs its country: one lookup for its first and one for its
/// last city, through the shared cache and spaced like the place backfill.
struct TripNameBackfill: Sendable {
    let geocoder: any ImportGeocoder
    let geocodeCache: ImportGeocodeCache
    var interval: Duration = .seconds(1)
    var timeout: Duration = .seconds(10)

    @discardableResult
    func run(container: ModelContainer) async throws -> Int {
        let context = ModelContext(container)
        let trips = try context.fetch(FetchDescriptor<Trip>()).filter {
            $0.overrideName == nil && TripNaming.isOldDefaultName($0.name)
        }
        var renamed = 0
        var lookups = 0
        for trip in trips {
            try Task.checkCancellation()
            let cities = Self.orderedCities(of: trip)
            guard !cities.isEmpty else { continue }
            var countries: [String] = []
            if Set(cities.map(\.name)).count > 3 {
                let ends = cities.count > 1 ? [cities[0], cities[cities.count - 1]] : [cities[0]]
                for city in ends {
                    if let country = try await country(of: city.coordinate, lookups: &lookups) {
                        countries.append(country)
                    }
                }
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

    /// Named cities in the order the trip's photos first reach them.
    static func orderedCities(of trip: Trip) -> [(name: String, coordinate: GeoPoint?)] {
        orderedCities(of: trip.orderedItems)
    }

    /// Named cities in the order these photos, sorted by date, first reach them.
    static func orderedCities(of items: [MediaItem]) -> [(name: String, coordinate: GeoPoint?)] {
        let items = items.sorted { ($0.captureDate ?? .distantPast, $0.id) < ($1.captureDate ?? .distantPast, $1.id) }
        var seen = Set<String>()
        var result: [(name: String, coordinate: GeoPoint?)] = []
        for item in items {
            var current = item.place
            var depth = 0
            while let place = current, place.kind != .city, depth < 4 {
                current = place.parent
                depth += 1
            }
            guard let city = current, city.kind == .city, seen.insert(city.id).inserted,
                  let name = PlaceDisplayName.resolvedName(of: city) else { continue }
            let coordinate = city.latitude.flatMap { latitude in
                city.longitude.map { GeoPoint(latitude: latitude, longitude: $0) }
            }
            result.append((name, coordinate))
        }
        return result
    }

    private func country(of coordinate: GeoPoint?, lookups: inout Int) async throws -> String? {
        guard let coordinate else { return nil }
        if let cached = await geocodeCache.result(for: coordinate), let country = cached.country {
            return country
        }
        if lookups > 0 { try await Task.sleep(for: interval) }
        lookups += 1
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

import CoreLocation
import Foundation
import MomentsCore

protocol FootprintsGeocoder {
    func reverseGeocode(coordinate: GeoPoint) async throws -> FootprintsGeocodeResult
}

final class CoreLocationFootprintsGeocoder: FootprintsGeocoder {
    private let geocoder = CLGeocoder()

    func reverseGeocode(coordinate: GeoPoint) async throws -> FootprintsGeocodeResult {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemarks = try await geocoder.reverseGeocodeLocation(location)
        guard let placemark = placemarks.first,
              let countryCode = placemark.isoCountryCode,
              let countryName = placemark.country else {
            return .ocean
        }
        return FootprintsGeocodeResult(
            countryCode: countryCode,
            countryName: countryName,
            cityName: FootprintsCityName.pick(
                countryCode: countryCode,
                administrativeArea: placemark.administrativeArea,
                locality: placemark.locality,
                subAdministrativeArea: placemark.subAdministrativeArea
            )
        )
    }
}

/// The city at the level a person means when saying "I have been to Chongqing":
/// one big city even when its suburbs come back as separate localities.
enum FootprintsCityName {
    /// Mainland China's four province-level municipalities: the geocoder names
    /// a district such as 万州区 in `locality`, the city in `administrativeArea`.
    private static let municipalities: Set<String> = [
        "beijing", "shanghai", "tianjin", "chongqing",
        "北京市", "上海市", "天津市", "重庆市"
    ]

    static func pick(
        countryCode: String?,
        administrativeArea: String?,
        locality: String?,
        subAdministrativeArea: String?
    ) -> String? {
        let country = countryCode?.uppercased()
        let administrativeArea = cleaned(administrativeArea)
        let locality = cleaned(locality)
        let subAdministrativeArea = cleaned(subAdministrativeArea)

        if country == "CN",
           let administrativeArea,
           municipalities.contains(administrativeArea.lowercased()) {
            return administrativeArea
        }
        // In China, Hong Kong, Macao and Taiwan the city is the locality; the
        // administrative area above it is the province or region. Elsewhere
        // the same order holds, with a commune sometimes named one level up.
        return locality ?? subAdministrativeArea ?? administrativeArea
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

final class FootprintsGeocodeCache {
    private(set) var values: [String: FootprintsGeocodeResult]
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.values = Self.read(from: self.fileURL)
    }

    func result(for coordinate: GeoPoint) -> FootprintsGeocodeResult? {
        values[Self.key(for: coordinate)]
    }

    func insert(_ result: FootprintsGeocodeResult, for coordinate: GeoPoint) {
        values[Self.key(for: coordinate)] = result
    }

    func save() throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(values)
        try data.write(to: fileURL, options: .atomic)
    }

    static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory
            .appending(path: "Moments", directoryHint: .isDirectory)
            .appending(path: "footprints-geocoding.json")
    }

    /// Rounded to 0.1° (about 11 km): a city's centre moves slightly whenever a
    /// photo is added, and the country does not change at that scale.
    static func key(for coordinate: GeoPoint) -> String {
        String(
            format: "%.1f,%.1f",
            locale: Locale(identifier: "en_US_POSIX"),
            coordinate.latitude,
            coordinate.longitude
        )
    }

    private static func read(from url: URL) -> [String: FootprintsGeocodeResult] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: FootprintsGeocodeResult].self, from: data) else {
            return [:]
        }
        return decoded
    }
}

struct FootprintsGeocodeBatch: Equatable {
    let results: [String: FootprintsGeocodeResult]
    let didEncounterError: Bool
}

private enum FootprintsGeocodingError: Error {
    case timeout
}

final class FootprintsGeocodeResolver {
    private let geocoder: any FootprintsGeocoder
    private let cache: FootprintsGeocodeCache
    private let minimumRequestInterval: TimeInterval
    private let requestTimeout: TimeInterval
    private var lastRequestDate: Date?
    /// Cached entries that were looked up again for a missing city name. Kept
    /// here so a place whose geocoder returns no city is asked only once.
    private var refreshedCityNameKeys: Set<String> = []

    init(
        geocoder: any FootprintsGeocoder,
        cache: FootprintsGeocodeCache,
        minimumRequestInterval: TimeInterval = 0.25,
        requestTimeout: TimeInterval = 10
    ) {
        self.geocoder = geocoder
        self.cache = cache
        self.minimumRequestInterval = max(0, minimumRequestInterval)
        self.requestTimeout = max(0, requestTimeout)
    }

    convenience init() {
        self.init(
            geocoder: CoreLocationFootprintsGeocoder(),
            cache: FootprintsGeocodeCache()
        )
    }

    func resolve(clusters: [PlaceCluster]) async -> FootprintsGeocodeBatch {
        var results: [String: FootprintsGeocodeResult] = [:]
        var didEncounterError = false

        for cluster in clusters {
            // .task(id:) cancels the previous refresh when the input changes;
            // stop here so two batches never mutate the cache at once.
            if Task.isCancelled { break }
            guard let center = cluster.center else { continue }
            let cityNameKey = FootprintsGeocodeCache.key(for: center)
            var refreshedKeyThisRound: String?
            var staleResult: FootprintsGeocodeResult?
            if let cached = cache.result(for: center) {
                // Old cache entries have a country but no city. Look those up
                // once more; the ocean and unknown places stay cached.
                let needsCityName: Bool = !cached.isOcean
                    && cached.cityName == nil
                    && !refreshedCityNameKeys.contains(cityNameKey)
                guard needsCityName else {
                    results[cluster.id] = cached
                    continue
                }
                refreshedCityNameKeys.insert(cityNameKey)
                refreshedKeyThisRound = cityNameKey
                staleResult = cached
            }

            await waitForRateLimit()
            lastRequestDate = Date()
            do {
                let result = try await reverseGeocodeWithTimeout(coordinate: center)
                cache.insert(result, for: center)
                try? cache.save()
                results[cluster.id] = result
            } catch {
                // Keep what the cache already knows, so an offline Mac still
                // counts this place; it is tried again on the next launch.
                if let staleResult {
                    results[cluster.id] = staleResult
                }
                if let refreshedKeyThisRound {
                    refreshedCityNameKeys.remove(refreshedKeyThisRound)
                }
                // Stop after the first failed request. This makes an offline
                // panel explicit and avoids retrying every cluster forever.
                didEncounterError = true
                break
            }
        }
        return FootprintsGeocodeBatch(results: results, didEncounterError: didEncounterError)
    }

    private func reverseGeocodeWithTimeout(coordinate: GeoPoint) async throws -> FootprintsGeocodeResult {
        guard requestTimeout > 0 else {
            return try await geocoder.reverseGeocode(coordinate: coordinate)
        }

        let geocoder = geocoder
        let timeout = requestTimeout
        return try await withThrowingTaskGroup(of: FootprintsGeocodeResult.self) { group in
            group.addTask {
                try await geocoder.reverseGeocode(coordinate: coordinate)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw FootprintsGeocodingError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func waitForRateLimit() async {
        guard minimumRequestInterval > 0, let lastRequestDate else { return }
        let elapsed = Date().timeIntervalSince(lastRequestDate)
        let remaining = minimumRequestInterval - elapsed
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }
}

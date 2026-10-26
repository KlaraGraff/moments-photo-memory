import Foundation
import MomentsCore
import SwiftData

/// Names cities the import left unnamed because its lookup budget ran out or
/// the geocoder failed. The work list comes from the store (cities with an
/// empty name), so a run that is cancelled or quits picks up where it stopped
/// on the next launch. Lookups are spaced by `interval` to respect CLGeocoder's
/// rate limit.
struct PlaceNameBackfill: Sendable {
    let geocoder: any ImportGeocoder
    let geocodeCache: ImportGeocodeCache
    var interval: Duration = .seconds(1)
    var timeout: Duration = .seconds(10)
    var maxConsecutiveFailures = 3

    /// Returns how many cities were named. Stops early after repeated
    /// failures; the rest stay unnamed for the next run.
    @discardableResult
    func run(container: ModelContainer) async throws -> Int {
        let context = ModelContext(container)
        let cityKind = PlaceKind.city.rawValue
        let pending = try context.fetch(FetchDescriptor<Place>(
            predicate: #Predicate { $0.kindRaw == cityKind && $0.name == "" && $0.latitude != nil && $0.longitude != nil },
            sortBy: [SortDescriptor(\.id)]
        ))
        guard !pending.isEmpty else { return 0 }
        do {
            let named = try await name(pending, context: context)
            await geocodeCache.persist()
            return named
        } catch {
            await geocodeCache.persist()
            throw error
        }
    }

    private func name(_ pending: [Place], context: ModelContext) async throws -> Int {
        var named = 0
        var failures = 0
        var isFirstNetworkLookup = true
        for city in pending {
            try Task.checkCancellation()
            guard let latitude = city.latitude, let longitude = city.longitude else { continue }
            let coordinate = GeoPoint(latitude: latitude, longitude: longitude)
            var result = await geocodeCache.result(for: coordinate)
            if result == nil {
                if !isFirstNetworkLookup { try await Task.sleep(for: interval) }
                isFirstNetworkLookup = false
                let geocoder = self.geocoder
                do {
                    result = try await ImportGeocodeGate.firstResult(within: timeout) {
                        try await geocoder.reverseGeocode(coordinate: coordinate)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    result = nil
                }
                guard let result else {
                    failures += 1
                    if failures >= maxConsecutiveFailures { break }
                    continue
                }
                failures = 0
                await geocodeCache.insert(result, for: coordinate)
            }
            guard let result else { continue }
            apply(result, to: city)
            clearRetryFlags(under: city)
            // Save each city so the UI updates as names arrive and a quit
            // loses at most one lookup.
            try context.save()
            named += 1
        }
        return named
    }

    private func apply(_ result: ImportGeocodeResult, to city: Place) {
        city.name = result.city ?? String(localized: "Unknown city")
        for area in city.children where area.kind == .area && area.name.isEmpty {
            area.name = result.area ?? String(localized: "Unknown area")
        }
    }

    /// Photos in a city that just got its name no longer need a place retry.
    private func clearRetryFlags(under city: Place) {
        let retry = ImportReviewReason.geocodingRetry.rawValue
        var places = [city]
        var items: [MediaItem] = []
        while let place = places.popLast() {
            items.append(contentsOf: place.items)
            places.append(contentsOf: place.children)
        }
        for item in items {
            guard let raw = item.importReviewReasonsRaw, raw.contains(retry) else { continue }
            let reasons = raw
                .split(separator: ",")
                .map(String.init)
                .filter { $0 != retry }
            item.importReviewReasonsRaw = reasons.joined(separator: ",")
            if reasons.isEmpty, item.reviewDecisionRaw == ImportReviewDecision.pending.rawValue {
                item.reviewDecisionRaw = ImportReviewDecision.accepted.rawValue
            }
        }
    }
}

/// Runs at most one backfill at a time, in the background, and only while no
/// import runs, so the two don't compete for the geocoder's rate limit.
@MainActor
final class PlaceNameBackfillScheduler {
    static let shared = PlaceNameBackfillScheduler()

    private var task: Task<Void, Never>?
    private var generation = 0
    private var activeImports = 0
    private var container: ModelContainer?
    var makeBackfill: () -> PlaceNameBackfill = {
        PlaceNameBackfill(
            geocoder: CoreLocationImportGeocoder(),
            geocodeCache: ImportGeocodeCache(
                fileURL: URL.applicationSupportDirectory
                    .appending(path: "Moments", directoryHint: .isDirectory)
                    .appending(path: "import-geocoding.json")
            )
        )
    }

    func start(container: ModelContainer) {
        self.container = container
        guard task == nil, activeImports == 0 else { return }
        #if DEBUG
        // Unit tests drive PlaceNameBackfill directly and must not reach the network.
        if UnitTestHostDelegate.isUnitTestHost { return }
        #endif
        generation += 1
        let current = generation
        let backfill = makeBackfill()
        task = Task.detached(priority: .utility) { [weak self] in
            _ = try? await backfill.run(container: container)
            // Then trips still named by date only get their places in the name.
            if !Task.isCancelled {
                _ = try? await TripNameBackfill(geocoder: backfill.geocoder, geocodeCache: backfill.geocodeCache)
                    .run(container: container)
            }
            await self?.finished(current)
        }
    }

    func beginImport() {
        activeImports += 1
        task?.cancel()
        task = nil
    }

    /// Restarts the backfill once the last running import ends, whatever
    /// its outcome.
    func endImport() {
        activeImports = max(0, activeImports - 1)
        if let container { start(container: container) }
    }

    private func finished(_ finishedGeneration: Int) {
        // A paused run may finish after a newer one started.
        if finishedGeneration == generation { task = nil }
    }
}

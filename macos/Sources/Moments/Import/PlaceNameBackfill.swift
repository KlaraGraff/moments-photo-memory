import Foundation
import MomentsCore
import SwiftData

/// Names cities the import left unnamed because the rate window had no room
/// or the geocoder failed. The work list comes from the store (cities with an
/// empty name), so a run that is cancelled or quits picks up where it stopped
/// on the next launch. Lookups go through the shared pacer, so the backfill and
/// any import together stay under CLGeocoder's rate limit.
struct PlaceNameBackfill: Sendable {
    let geocoder: any ImportGeocoder
    let geocodeCache: ImportGeocodeCache
    /// Waits until one lookup may start; the default draws on the pacer shared
    /// with imports, so both together stay under the rate limit. Tests pass an
    /// empty closure.
    var pace: @Sendable () async -> Void = { await ImportGeocodePacer.shared.wait() }
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
        for city in pending {
            try Task.checkCancellation()
            guard let latitude = city.latitude, let longitude = city.longitude else { continue }
            let coordinate = GeoPoint(latitude: latitude, longitude: longitude)
            var result = await geocodeCache.result(for: coordinate)
            if result == nil {
                await pace()
                // A cancelled wait must end the run, not send a lookup that
                // then records a failure against the failure stop.
                try Task.checkCancellation()
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
            repairZones(under: city, named: result)
            // Save each city so the UI updates as names arrive and a quit
            // loses at most one lookup.
            try context.save()
            named += 1
            // Trips seen so far get their place names as they arrive, but only
            // once every city they touch is named (see `TripNameBackfill`).
            if named.isMultiple(of: 10) {
                _ = try await TripNameBackfill(geocoder: geocoder, geocodeCache: geocodeCache, pace: pace)
                    .run(container: context.container, onlyFullyNamed: true)
            }
        }
        return named
    }

    /// True while the store still holds cities without a name, so a run that
    /// stopped early has work left for the scheduler's retry.
    static func hasUnnamedCities(in container: ModelContainer) throws -> Bool {
        let context = ModelContext(container)
        let cityKind = PlaceKind.city.rawValue
        let descriptor = FetchDescriptor<Place>(
            predicate: #Predicate { $0.kindRaw == cityKind && $0.name == "" && $0.latitude != nil && $0.longitude != nil }
        )
        return try context.fetchCount(descriptor) > 0
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
        for item in items(under: city) {
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

    /// Photos under a city whose zone the import could only guess because the
    /// city was still unnamed got the device zone and `.zoneUnknown`. Now that
    /// the city has a name (and usually its zone), they get the real one: the
    /// zone identifier, the day key in that zone and, for a folder photo whose
    /// EXIF wall-clock time was read in the wrong zone, the capture date
    /// resolved again from that wall-clock value.
    private func repairZones(under city: Place, named result: ImportGeocodeResult) {
        guard let identifier = result.timeZoneIdentifier,
              let zone = TimeZone(identifier: identifier) else { return }
        for item in items(under: city) where item.timeConfidence == .zoneUnknown {
            // A date the person corrected themselves is never touched.
            guard item.userCorrectedCaptureDateUTC == nil else { continue }
            item.timeZoneIdentifier = identifier
            if let wallClock = item.captureDateHintUTC {
                let resolved = ImportOrganizer.resolveWallClockDate(wallClock, in: zone)
                item.captureDate = resolved
                item.originalCaptureDateUTC = resolved
            }
            if let date = item.captureDate {
                item.localDayKey = Self.localDayKey(for: date, in: zone)
            }
            item.timeConfidenceRaw = ImportTimeConfidence.exact.rawValue
        }
    }

    /// The `yyyy-MM-dd` day a moment falls on in `zone`, through the same
    /// function the import uses, so a repaired day key matches a fresh import.
    private static func localDayKey(for date: Date, in zone: TimeZone) -> String {
        ImportOrganizer.localDayKey(for: date, in: zone)
    }

    /// The city itself and every area and spot under it.
    private func items(under place: Place) -> [MediaItem] {
        var places = [place]
        var items: [MediaItem] = []
        while let place = places.popLast() {
            items.append(contentsOf: place.items)
            places.append(contentsOf: place.children)
        }
        return items
    }
}

/// Runs at most one backfill at a time, in the background, and only while no
/// import runs, so the two don't compete for the geocoder's rate limit. A run
/// that stops early with cities still unnamed is retried after a growing
/// delay, so a long offline stretch costs a few tries instead of the rest of
/// the app session.
@MainActor
final class PlaceNameBackfillScheduler {
    static let shared = PlaceNameBackfillScheduler()

    /// The first wait after a run that stopped early; doubles up to
    /// `maximumRetryDelay` while runs keep failing, and resets as soon as a
    /// run names a city.
    static let firstRetryDelay: Duration = .seconds(120)
    static let maximumRetryDelay: Duration = .seconds(1_800)

    private var task: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryDelay: Duration = PlaceNameBackfillScheduler.firstRetryDelay
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
        retryTask?.cancel()
        retryTask = nil
        retryDelay = Self.firstRetryDelay
        runNow(container: container)
    }

    func beginImport() {
        activeImports += 1
        task?.cancel()
        task = nil
        retryTask?.cancel()
        retryTask = nil
    }

    /// Restarts the backfill once the last running import ends, whatever
    /// its outcome, and drops a pending retry: the new run starts at once.
    func endImport() {
        activeImports = max(0, activeImports - 1)
        if let container { start(container: container) }
    }

    private func runNow(container: ModelContainer) {
        generation += 1
        let current = generation
        let backfill = makeBackfill()
        task = Task.detached(priority: .utility) { [weak self] in
            let named = (try? await backfill.run(container: container)) ?? 0
            // Whether any city still has no name, computed before the trip pass
            // (it can name cities itself and must not change the answer).
            let cancelled = Task.isCancelled
            let remaining = !cancelled && ((try? PlaceNameBackfill.hasUnnamedCities(in: container)) ?? false)
            // Then trips still named by date only get their places in the name.
            // The final pass waits too (the T1d fix): a trip renamed while only
            // some of its cities have names keeps that partial name forever,
            // because only placeless default names are renamed again.
            if !cancelled {
                _ = try? await TripNameBackfill(geocoder: backfill.geocoder, geocodeCache: backfill.geocodeCache)
                    .run(container: container, onlyFullyNamed: remaining)
            }
            await self?.finished(current, named: named, retryNeeded: remaining)
        }
    }

    private func finished(_ finishedGeneration: Int, named: Int, retryNeeded: Bool) {
        // A paused run may finish after a newer one started.
        guard finishedGeneration == generation else { return }
        task = nil
        if named > 0 { retryDelay = Self.firstRetryDelay }
        // Offline runs stop after three failures. Cities stay unnamed for as
        // long as it lasts, so try again later instead of giving up until the
        // next import or launch.
        guard retryNeeded, activeImports == 0, let container else { return }
        scheduleRetry(container: container)
    }

    private func scheduleRetry(container: ModelContainer) {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.maximumRetryDelay)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.retryNow()
        }
    }

    private func retryNow() {
        retryTask = nil
        guard task == nil, activeImports == 0, let container else { return }
        runNow(container: container)
    }
}

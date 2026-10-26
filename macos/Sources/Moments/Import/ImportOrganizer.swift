import Foundation
import MomentsCore

public actor ImportGeocodeCache {
    private var values: [String: ImportGeocodeResult]
    private let fileURL: URL?
    private var isDirty = false

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: ImportGeocodeResult].self, from: data) {
            values = decoded
        } else {
            values = [:]
        }
    }

    public func result(for coordinate: GeoPoint) -> ImportGeocodeResult? {
        values[key(for: coordinate)]
    }

    public func insert(_ result: ImportGeocodeResult, for coordinate: GeoPoint) {
        values[key(for: coordinate)] = result
        isDirty = true
    }

    /// Writes the cache once (call at the end of an import). Rewriting the
    /// whole file on every insert made large imports quadratic.
    public func persist() {
        guard isDirty, let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(values) {
            try? data.write(to: fileURL, options: .atomic)
        }
        isDirty = false
    }

    private func key(for coordinate: GeoPoint) -> String {
        String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
    }
}

/// Limits reverse-geocoding during one import. CLGeocoder is rate-limited
/// (roughly one request a second, then throttling errors), so an import makes
/// at most `maxLookups` calls, gives each `timeout`, and stops after
/// `maxConsecutiveFailures` failures in a row. Cities it skips keep an empty
/// name and are named later by `PlaceNameBackfill`.
actor ImportGeocodeGate {
    enum Purpose { case timeZone, placeName }

    let maxLookups: Int
    /// Time-zone lookups run first, so they get a smaller share and leave
    /// most of the budget for naming places.
    let maxTimeZoneLookups: Int
    let maxConsecutiveFailures: Int
    let timeout: Duration
    private(set) var lookups = 0
    private var timeZoneLookups = 0
    private var consecutiveFailures = 0

    init(maxLookups: Int = 40, maxTimeZoneLookups: Int = 10, maxConsecutiveFailures: Int = 3, timeout: Duration = .seconds(10)) {
        self.maxLookups = maxLookups
        self.maxTimeZoneLookups = maxTimeZoneLookups
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.timeout = timeout
    }

    /// Reserves one lookup, or returns false when the budget is spent or
    /// the service keeps failing.
    func reserve(for purpose: Purpose) -> Bool {
        guard lookups < maxLookups, consecutiveFailures < maxConsecutiveFailures else { return false }
        if purpose == .timeZone {
            guard timeZoneLookups < maxTimeZoneLookups else { return false }
            timeZoneLookups += 1
        }
        lookups += 1
        return true
    }

    func recordSuccess() { consecutiveFailures = 0 }
    func recordFailure() { consecutiveFailures += 1 }
}

extension ImportGeocodeGate {
    /// Returns the lookup's result, or nil once `timeout` passes, without
    /// waiting for a lookup that ignores cancellation (a task group would wait
    /// for every child). The losing task is cancelled.
    static func firstResult(
        within timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> ImportGeocodeResult
    ) async throws -> ImportGeocodeResult? {
        let race = ResumeOnce<ImportGeocodeResult?>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.attach(continuation)
                let work = Task {
                    do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) }
                }
                let timer = Task {
                    try? await Task.sleep(for: timeout)
                    race.finish(.success(nil))
                }
                race.onFinish { work.cancel(); timer.cancel() }
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }
}

/// Resumes a continuation exactly once, whichever side finishes first, and
/// keeps an early result until the continuation is attached.
final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
    private var finished = false
    private var cleanup: (() -> Void)?

    func attach(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func onFinish(_ action: @escaping () -> Void) {
        lock.lock()
        if finished {
            lock.unlock()
            action()
            return
        }
        cleanup = action
        lock.unlock()
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pending = result }
        let cleanup = self.cleanup
        self.cleanup = nil
        lock.unlock()
        continuation?.resume(with: result)
        cleanup?()
    }
}

struct OrganizedPlace: Equatable, Sendable {
    let id: String
    let name: String
    let kind: PlaceKind
    let latitude: Double?
    let longitude: Double?
    let parentID: String?
}

struct OrganizedMedia: Equatable, Sendable {
    let metadata: ImportedMediaMetadata
    let tripID: String
    let placeID: String?
    let suggestedPlaceID: String?
    let suggestedPlaceName: String?
    let localDayKey: String
    let timeZoneIdentifier: String?
    let reasons: [ImportReviewReason]
    let reviewDetail: String?
}

struct OrganizedTrip: Equatable, Sendable {
    let id: String
    let name: String
    let startDate: Date?
    let endDate: Date?
    let itemIDs: [String]
}

struct OrganizedImportPlan: Equatable, Sendable {
    let media: [OrganizedMedia]
    let trips: [OrganizedTrip]
    let places: [OrganizedPlace]
    let collectionCount: Int
    let routeCount: Int
    let flags: [ImportReviewFlag]
    let conflicts: [ImportConflictEvent]
}

struct ImportOrganizer {
    let configuration: ImportConfiguration
    let geocoder: any ImportGeocoder
    let geocodeCache: ImportGeocodeCache
    let geocodeDelay: @Sendable () async -> Void
    let geocodeGate: ImportGeocodeGate
    /// Reports (lookups made, lookup budget) so the UI shows progress while
    /// places are looked up.
    let geocodeProgress: @Sendable (Int, Int) -> Void

    init(
        configuration: ImportConfiguration,
        geocoder: any ImportGeocoder,
        geocodeCache: ImportGeocodeCache,
        geocodeDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(nanoseconds: 100_000_000)
        },
        geocodeGate: ImportGeocodeGate = ImportGeocodeGate(),
        geocodeProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) {
        self.configuration = configuration
        self.geocoder = geocoder
        self.geocodeCache = geocodeCache
        self.geocodeDelay = geocodeDelay
        self.geocodeGate = geocodeGate
        self.geocodeProgress = geocodeProgress
    }

    /// `sourceFolderName` names trips whose photos carry no real capture date;
    /// it stays in the local store only.
    func organize(_ inputMetadata: [ImportedMediaMetadata], sourceFolderName: String? = nil) async throws -> OrganizedImportPlan {
        let metadata = try await resolveCaptureDates(inputMetadata)
        guard !metadata.isEmpty else {
            return OrganizedImportPlan(media: [], trips: [], places: [], collectionCount: 0, routeCount: 0, flags: [], conflicts: [])
        }

        let ordered = metadata.sorted { lhs, rhs in
            lhs.captureDate == rhs.captureDate ? lhs.id < rhs.id : lhs.captureDate < rhs.captureDate
        }
        let tripGroups = splitTrips(ordered)
        var allMedia: [OrganizedMedia] = []
        var trips: [OrganizedTrip] = []
        var places: [OrganizedPlace] = []
        var allFlags: [ImportReviewFlag] = []
        let conflicts = ImportConflictDetector(configuration: configuration.conflictConfiguration).detect(metadata)
        let conflictsByItemID = conflicts.reduce(into: [String: [ImportConflictEvent]]()) { result, event in
            for itemID in event.itemIDs { result[itemID, default: []].append(event) }
        }
        let nearDuplicateIDs = nearDuplicateIDs(in: ordered)
        let orderedIndex = Dictionary(ordered.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var outsideDateIDs = Set<String>()
        for index in 1..<tripGroups.count {
            guard let previous = tripGroups[index - 1].last,
                  let current = tripGroups[index].first else { continue }
            if current.captureDate.timeIntervalSince(previous.captureDate) > configuration.captureDateConflictThreshold {
                outsideDateIDs.insert(current.id)
            }
        }

        var undatedTripCount = 0
        for (index, group) in tripGroups.enumerated() {
            try Task.checkCancellation()
            let tripID = stableID(prefix: "trip", ids: group.map(\.id))
            let isUndated = group.allSatisfy { $0.captureDateSource == .fileDateFallback }
            let tripName: String
            if isUndated {
                // Several undated groups from one folder get numbered names.
                undatedTripCount += 1
                let base = Self.undatedTripName(folderName: sourceFolderName)
                tripName = undatedTripCount == 1 ? base : base + " " + String(undatedTripCount)
            } else {
                tripName = Self.defaultTripName(for: group.first?.captureDate, index: index + 1)
            }
            let stops = group.compactMap { item -> PhotoStop? in
                guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
                return PhotoStop(id: item.id, date: item.captureDate, coordinate: GeoPoint(latitude: latitude, longitude: longitude))
            }
            let clusterer = PlaceClusterer(maximumTimeGap: configuration.maximumTimeGap)
            let spotClusters = clusterer.clusters(for: stops, level: .spot)
            let areaClusters = clusterer.clusters(for: stops, level: .area)
            let cityClusters = clusterer.clusters(for: stops, level: .city)
            let cityLookup = try await cityNames(for: cityClusters)
            let cityNames = cityLookup.values

            let cityByStop = clusterMap(cityClusters)
            let areaByStop = clusterMap(areaClusters)
            let spotByStop = clusterMap(spotClusters)
            var placeByID: [String: OrganizedPlace] = [:]
            for cluster in cityClusters {
                let name = cityLookup.failed.contains(cluster.id)
                    ? ""
                    : cityNames[cluster.id]?.city ?? String(localized: "Unknown city")
                placeByID[cluster.id] = OrganizedPlace(
                    id: cluster.id,
                    name: name,
                    kind: .city,
                    latitude: cluster.center?.latitude,
                    longitude: cluster.center?.longitude,
                    parentID: nil
                )
            }
            for cluster in areaClusters {
                let parent = cluster.stopIDs.compactMap { cityByStop[$0]?.id }.first
                placeByID[cluster.id] = OrganizedPlace(
                    id: cluster.id,
                    name: cityLookup.failed.contains(parent ?? "")
                        ? ""
                        : cityNames[parent ?? ""]?.area ?? String(localized: "Unknown area"),
                    kind: .area,
                    latitude: cluster.center?.latitude,
                    longitude: cluster.center?.longitude,
                    parentID: parent
                )
            }
            for cluster in spotClusters {
                let parent = cluster.stopIDs.compactMap { areaByStop[$0]?.id }.first
                placeByID[cluster.id] = OrganizedPlace(
                    id: cluster.id,
                    name: String(localized: "Spot") + " " + String(cluster.id.suffix(6)),
                    kind: .spot,
                    latitude: cluster.center?.latitude,
                    longitude: cluster.center?.longitude,
                    parentID: parent
                )
            }
            places.append(contentsOf: placeByID.values)

            for (groupIndex, item) in group.enumerated() {
                let coordinate = item.latitude.flatMap { latitude in
                    item.longitude.map { longitude in GeoPoint(latitude: latitude, longitude: longitude) }
                }
                var reasons: [ImportReviewReason] = []
                var detailParts: [String] = []
                if coordinate == nil { reasons.append(.missingLocation) }
                if item.timeConfidence == .zoneUnknown { reasons.append(.timeZoneUnknown) }
                if item.captureDateSource == .fileDateFallback {
                    reasons.append(.fileDateFallback)
                    reasons.append(.needsDate)
                }
                if item.isAirDropLike {
                    reasons.append(.airDropReceived)
                    detailParts.append("The file name suggests a received/shared copy; check its date and place.")
                }
                if isGPSJump(item: item, in: ordered, index: orderedIndex) { reasons.append(.gpsJump) }
                if outsideDateIDs.contains(item.id) || isCaptureDateOutsideTrip(item: item, at: groupIndex, in: group) {
                    reasons.append(.captureDateOutsideTrip)
                }
                if nearDuplicateIDs.contains(item.id) { reasons.append(.nearDuplicate) }
                if let cityID = cityByStop[item.id]?.id, cityLookup.failed.contains(cityID) {
                    reasons.append(.geocodingRetry)
                }
                for event in conflictsByItemID[item.id] ?? [] {
                    switch event.kind {
                    case .transport:
                        reasons.append(.transportCandidate)
                    case .noPhotosGap:
                        reasons.append(.noPhotosGap)
                    default:
                        reasons.append(.timePlaceConflict)
                    }
                    detailParts.append(event.detail)
                }
                reasons = Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
                let city = cityByStop[item.id].flatMap { cityNames[$0.id] }
                let suggested = nearestPlaceSuggestion(for: item, in: group, spotByStop: spotByStop)
                let suggestedName = suggested.flatMap { placeByID[$0]?.name }
                let timeZoneIdentifier = item.timeZoneIdentifier
                    ?? city?.timeZoneIdentifier
                    ?? nearestTimeZoneIdentifier(for: item, in: group)
                    ?? TimeZone.autoupdatingCurrent.identifier
                let dayKey = localDayKey(for: item, timeZoneIdentifier: timeZoneIdentifier)
                let placeID = item.latitude.flatMap { latitude in
                    item.longitude.flatMap { longitude in
                        spotByStop[item.id]?.id ?? cityByStop[item.id]?.id
                    }
                }
                let reviewDetail = detailParts.isEmpty ? nil : Array(Set(detailParts)).joined(separator: " ")
                allMedia.append(OrganizedMedia(
                    metadata: item,
                    tripID: tripID,
                    placeID: placeID,
                    suggestedPlaceID: placeID == nil ? suggested : nil,
                    suggestedPlaceName: placeID == nil ? suggestedName : nil,
                    localDayKey: dayKey,
                    timeZoneIdentifier: timeZoneIdentifier,
                    reasons: reasons,
                    reviewDetail: reviewDetail
                ))
                if !reasons.isEmpty {
                    allFlags.append(ImportReviewFlag(
                        id: item.id,
                        fileName: item.fileName,
                        reasons: reasons,
                        detail: reviewDetail,
                        suggestedDayKey: dayKey,
                        suggestedPlaceName: suggestedName
                    ))
                }
            }
            trips.append(OrganizedTrip(
                id: tripID,
                name: tripName,
                startDate: group.compactMap(\.exactCaptureDate).min(),
                endDate: group.compactMap(\.exactCaptureDate).max(),
                itemIDs: group.map(\.id)
            ))
        }

        let descriptors = metadata.map {
            MediaDescriptor(id: $0.id, captureDate: $0.captureDate, pixelWidth: $0.width, pixelHeight: $0.height, fileNameHint: $0.fileName)
        }
        let collectionCount = CollectionGrouper().group(descriptors).count
        let metadataByID = Dictionary(metadata.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let routeCount = trips.reduce(into: 0) { result, trip in
            let stops = trip.itemIDs.compactMap { id -> PhotoStop? in
                guard let item = metadataByID[id], let latitude = item.latitude, let longitude = item.longitude else { return nil }
                return PhotoStop(id: id, date: item.captureDate, coordinate: GeoPoint(latitude: latitude, longitude: longitude))
            }
            result += RouteBuilder(
                stops: stops,
                clusterer: PlaceClusterer(maximumTimeGap: configuration.maximumTimeGap)
            ).overview().count
        }
        return OrganizedImportPlan(
            media: allMedia.sorted { $0.metadata.id < $1.metadata.id },
            trips: trips,
            places: places.sorted { $0.id < $1.id },
            collectionCount: collectionCount,
            routeCount: routeCount,
            flags: allFlags.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending },
            conflicts: conflicts
        )
    }

    /// Resolve offset-less EXIF wall-clock values before any ordering,
    /// grouping, conflict detection, or Live Photo pairing uses them.
    func resolveCaptureDates(_ metadata: [ImportedMediaMetadata]) async throws -> [ImportedMediaMetadata] {
        let unresolved = metadata.filter { wallClockDate(for: $0) != nil }
        guard !unresolved.isEmpty else { return metadata }

        var timeZones: [String: String] = [:]
        for item in metadata {
            if let identifier = item.timeZoneIdentifier {
                timeZones[item.id] = identifier
            }
        }

        // A coordinate's own geocode is the strongest source for an
        // offset-less EXIF value. Time zones don't change within a few dozen
        // kilometres, so look up one representative per ~0.5° cell instead of
        // one per photo (thousands of photos used to mean thousands of
        // rate-limited calls). Failures are ignored so a neighbouring known
        // zone or the device zone can still be used.
        let needingZone = unresolved.filter { timeZones[$0.id] == nil && coordinate(for: $0) != nil }
        let cells = Dictionary(grouping: needingZone) { item -> String in
            let point = coordinate(for: item)!
            return "\((point.latitude * 2).rounded()),\((point.longitude * 2).rounded())"
        }
        for (_, members) in cells.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            guard let representative = members.first.flatMap(coordinate(for:)),
                  let result = try await lookupGeocode(coordinate: representative, for: .timeZone),
                  let identifier = result.timeZoneIdentifier else { continue }
            for member in members { timeZones[member.id] = identifier }
        }

        let candidates = metadata.compactMap { item -> (date: Date, identifier: String)? in
            guard let identifier = timeZones[item.id] else { return nil }
            return (item.captureDate, identifier)
        }.sorted { $0.date == $1.date ? $0.identifier < $1.identifier : $0.date < $1.date }

        return metadata.map { item in
            guard let wallClockDate = wallClockDate(for: item) else { return item }
            let identifier = timeZones[item.id]
                ?? Self.nearestIdentifier(in: candidates, to: item.captureDate)
            let zoneUnknown = identifier == nil
            let resolvedIdentifier = identifier ?? TimeZone.autoupdatingCurrent.identifier
            let resolvedDate = resolveWallClockDate(
                wallClockDate,
                in: TimeZone(identifier: resolvedIdentifier) ?? .autoupdatingCurrent
            )
            return item.resolving(
                captureDate: resolvedDate,
                exactCaptureDate: resolvedDate,
                dateHintUTC: zoneUnknown ? wallClockDate : nil,
                timeConfidence: zoneUnknown ? .zoneUnknown : .exact,
                timeZoneIdentifier: resolvedIdentifier
            )
        }
    }

    /// The identifier closest in time (ties go to the smaller identifier),
    /// found by binary search in `sorted` (by date, then identifier).
    static func nearestIdentifier(in sorted: [(date: Date, identifier: String)], to date: Date) -> String? {
        guard !sorted.isEmpty else { return nil }
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid].date < date { low = mid + 1 } else { high = mid }
        }
        // The nearest entries are the run of equal dates just before `low`
        // and the run starting at `low`; the first of each run has the
        // smallest identifier.
        var options: [(gap: TimeInterval, identifier: String)] = []
        if low < sorted.count { options.append((sorted[low].date.timeIntervalSince(date), sorted[low].identifier)) }
        if low > 0 {
            var start = low - 1
            while start > 0, sorted[start - 1].date == sorted[low - 1].date { start -= 1 }
            options.append((date.timeIntervalSince(sorted[start].date), sorted[start].identifier))
        }
        return options.min { $0.gap == $1.gap ? $0.identifier < $1.identifier : $0.gap < $1.gap }?.identifier
    }

    private func resolveWallClockDate(_ wallClockDate: Date, in timeZone: TimeZone) -> Date {
        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = sourceCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: wallClockDate
        )
        var targetCalendar = Calendar(identifier: .gregorian)
        targetCalendar.timeZone = timeZone
        return targetCalendar.date(from: components) ?? wallClockDate
    }

    /// Only items that still carry raw EXIF wall-clock time need resolving.
    /// `resolving(...)` clears it, so running this twice (importer, then
    /// organizer) never re-resolves an item against the zone it was given.
    private func wallClockDate(for item: ImportedMediaMetadata) -> Date? {
        item.wallClockDate
    }

    private func coordinate(for item: ImportedMediaMetadata) -> GeoPoint? {
        guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    private func lookupGeocode(coordinate: GeoPoint, for purpose: ImportGeocodeGate.Purpose) async throws -> ImportGeocodeResult? {
        if let cached = await geocodeCache.result(for: coordinate) { return cached }
        guard await geocodeGate.reserve(for: purpose) else { return nil }
        geocodeProgress(await geocodeGate.lookups, geocodeGate.maxLookups)
        await geocodeDelay()
        do {
            let geocoder = self.geocoder
            let result = try await ImportGeocodeGate.firstResult(within: geocodeGate.timeout) {
                try await geocoder.reverseGeocode(coordinate: coordinate)
            }
            guard let result else {
                await geocodeGate.recordFailure()
                return nil
            }
            await geocodeGate.recordSuccess()
            await geocodeCache.insert(result, for: coordinate)
            return result
        } catch is CancellationError {
            try Task.checkCancellation()
            await geocodeGate.recordFailure()
            return nil
        } catch {
            await geocodeGate.recordFailure()
            return nil
        }
    }

    private func splitTrips(_ ordered: [ImportedMediaMetadata]) -> [[ImportedMediaMetadata]] {
        var groups: [[ImportedMediaMetadata]] = []
        var current: [ImportedMediaMetadata] = []
        for item in ordered {
            if let previous = current.last,
               shouldSplit(previous: previous, current: item) {
                groups.append(current)
                current = []
            }
            current.append(item)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private func shouldSplit(previous: ImportedMediaMetadata, current: ImportedMediaMetadata) -> Bool {
        if current.captureDate.timeIntervalSince(previous.captureDate) > configuration.maximumTimeGap { return true }
        guard let lhs = coordinate(for: previous), let rhs = coordinate(for: current) else { return false }
        return Self.tripCoordinatesCanJoin(lhs, rhs, configuration: configuration) == false
    }

    /// Shared with incremental import matching so refreshed assets follow the
    /// same distance and home-boundary rules as initial organization.
    static func tripCoordinatesCanJoin(
        _ lhs: GeoPoint,
        _ rhs: GeoPoint,
        configuration: ImportConfiguration
    ) -> Bool {
        if lhs.distance(to: rhs) > configuration.maximumTripDistanceMeters { return false }
        if let home = configuration.homeCoordinate,
           (lhs.distance(to: home) <= configuration.maximumTripDistanceMeters)
                != (rhs.distance(to: home) <= configuration.maximumTripDistanceMeters) {
            return false
        }
        return true
    }

    private func isGPSJump(item: ImportedMediaMetadata, in ordered: [ImportedMediaMetadata], index orderedIndex: [String: Int]) -> Bool {
        guard let index = orderedIndex[item.id] else { return false }
        guard index > 0, index + 1 < ordered.count else { return false }
        let before = ordered[index - 1]
        let after = ordered[index + 1]
        guard let first = coordinate(for: before), let middle = coordinate(for: item), let last = coordinate(for: after) else { return false }
        let withinHour = abs(item.captureDate.timeIntervalSince(before.captureDate)) <= configuration.gpsJumpMaximumTimeGap
            && abs(after.captureDate.timeIntervalSince(item.captureDate)) <= configuration.gpsJumpMaximumTimeGap
        return withinHour && first.distance(to: middle) > configuration.gpsJumpDistanceMeters
            && middle.distance(to: last) > configuration.gpsJumpDistanceMeters
            && first.distance(to: last) <= configuration.gpsJumpDistanceMeters
    }

    private func isCaptureDateOutsideTrip(item: ImportedMediaMetadata, at index: Int, in group: [ImportedMediaMetadata]) -> Bool {
        guard group.count > 1 else { return false }
        let neighbours = [index > 0 ? group[index - 1] : nil, index + 1 < group.count ? group[index + 1] : nil].compactMap { $0 }
        return neighbours.contains { abs(item.captureDate.timeIntervalSince($0.captureDate)) > configuration.captureDateConflictThreshold }
    }

    private func localDayKey(for item: ImportedMediaMetadata, timeZoneIdentifier: String?) -> String {
        var calendar = Calendar(identifier: .gregorian)
        if let offset = item.timeZoneOffsetMinutes,
           let timeZone = TimeZone(secondsFromGMT: offset * 60) {
            calendar.timeZone = timeZone
        } else if let timeZoneIdentifier,
                  let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            calendar.timeZone = timeZone
        } else {
            calendar.timeZone = .autoupdatingCurrent
        }
        let components = calendar.dateComponents([.year, .month, .day], from: item.captureDate)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func cityNames(for clusters: [PlaceCluster]) async throws -> (values: [String: ImportGeocodeResult], failed: Set<String>) {
        var values: [String: ImportGeocodeResult] = [:]
        var failed = Set<String>()
        for cluster in clusters {
            try Task.checkCancellation()
            guard let center = cluster.center else { continue }
            if let cached = await geocodeCache.result(for: center) {
                values[cluster.id] = cached
                continue
            }
            do {
                if let result = try await lookupGeocode(coordinate: center, for: .placeName) {
                    values[cluster.id] = result
                } else {
                    failed.insert(cluster.id)
                }
            } catch is CancellationError {
                throw CancellationError()
            }
        }
        return (values, failed)
    }

    private func clusterMap(_ clusters: [PlaceCluster]) -> [String: PlaceCluster] {
        clusters.reduce(into: [:]) { result, cluster in
            for stopID in cluster.stopIDs { result[stopID] = cluster }
        }
    }

    private func nearDuplicateIDs(in ordered: [ImportedMediaMetadata]) -> Set<String> {
        let groups = Dictionary(grouping: ordered) { item in
            "\(item.captureDate.timeIntervalSinceReferenceDate)|\(item.width)x\(item.height)"
        }
        return groups.values
            .filter { $0.count > 1 }
            .flatMap { $0.map(\.id) }
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    private func nearestPlaceSuggestion(
        for item: ImportedMediaMetadata,
        in group: [ImportedMediaMetadata],
        spotByStop: [String: PlaceCluster]
    ) -> String? {
        guard item.latitude == nil || item.longitude == nil else { return nil }
        return group
            .filter { $0.latitude != nil && $0.longitude != nil }
            .min { abs($0.captureDate.timeIntervalSince(item.captureDate)) < abs($1.captureDate.timeIntervalSince(item.captureDate)) }
            .flatMap { spotByStop[$0.id]?.id }
    }

    private func nearestTimeZoneIdentifier(for item: ImportedMediaMetadata, in group: [ImportedMediaMetadata]) -> String? {
        group
            .filter { $0.timeZoneIdentifier != nil }
            .min { abs($0.captureDate.timeIntervalSince(item.captureDate)) < abs($1.captureDate.timeIntervalSince(item.captureDate)) }?
            .timeZoneIdentifier
    }

    /// Folders are usually named after the trip; generic container folders
    /// such as Downloads or a camera's DCIM say nothing about it.
    static func undatedTripName(folderName: String?) -> String {
        let name = folderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowered = name.lowercased()
        let generic: Set<String> = [
            "downloads", "desktop", "documents", "pictures", "photos", "images", "dcim",
            "camera", "camera roll", "import", "imports", "export", "new folder", "untitled folder",
            "untitled", "no name", "eos_digital",
            "下载", "桌面", "文稿", "图片", "照片", "相册", "新建文件夹", "未命名文件夹"
        ]
        // DCF camera folders such as 100APPLE, 101MSDCF or 100_PANA, but not
        // trip names that start with a year such as 2025Rome.
        let isCameraFolder = lowered.range(of: #"^\d{3}(?:[a-z]{5}|_[a-z]{4})$"#, options: .regularExpression) != nil
        if name.isEmpty || generic.contains(lowered) || isCameraFolder {
            return String(localized: "Undated photos")
        }
        return name
    }

    private static func defaultTripName(for date: Date?, index: Int) -> String {
        guard let date else { return String(localized: "Trip") + " " + String(index) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return String(localized: "Trip") + " " + formatter.string(from: date)
    }

    private func stableID(prefix: String, ids: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in (prefix + "\u{0}" + ids.sorted().joined(separator: "\u{0}")).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(prefix)-\(String(hash, radix: 16))"
    }
}

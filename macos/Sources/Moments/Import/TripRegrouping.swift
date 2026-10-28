import Foundation
import MomentsCore
import SwiftData

/// Regroups a library imported before trips meant time away from the usual
/// places (`TripSegmenter`): imports then put every photo in a trip, so daily
/// life became hundreds of small chapters. Runs once per Mac.
///
/// Only photos still in a trip the import suggested and nobody touched are
/// grouped again. A trip that was renamed, confirmed, edited, merged, split,
/// given a cover or a trip memory keeps its photos; photos placed by hand
/// (`TripAssignmentLocks`) never move; and a photo in no trip was taken out
/// by hand (imports used to put every photo in one), so it stays out. An
/// old trip that keeps most of its photos keeps its id, and empty old trips
/// go away. It runs on the main context before importing can start, so it
/// never races an import or an edit.
enum TripRegrouping {
    static let versionKey = "moments.trip.groupingVersion"
    static let currentVersion = 2

    struct Outcome: Equatable {
        var trips = 0
        var removed = 0
        var leftTrips = 0
    }

    /// Regroups once; later calls do nothing.
    @MainActor
    @discardableResult
    static func runOnce(context: ModelContext, defaults: UserDefaults = TripAssignmentLocks.store) throws -> Outcome? {
        guard defaults.integer(forKey: versionKey) < currentVersion else { return nil }
        let covered = Set(TripCoverChoice.decode(defaults.string(forKey: TripCoverChoice.defaultsKey) ?? "").keys)
        let outcome = try regroup(context: context, locked: TripAssignmentLocks.lockedIDs(defaults: defaults), covered: covered)
        defaults.set(currentVersion, forKey: versionKey)
        return outcome
    }

    static func regroup(
        context: ModelContext,
        locked: Set<String>,
        covered: Set<String> = [],
        configuration: ImportConfiguration = ImportConfiguration(),
        calendar: Calendar = .current
    ) throws -> Outcome {
        let items = try context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil }))
        let trips = try context.fetch(FetchDescriptor<Trip>())
        let kept = try keptTripIDs(trips, context: context, locked: locked, covered: covered)

        let tripIDs = Set(trips.map(\.id))
        let undated = ImportCaptureDateSource.fileDateFallback.rawValue
        let free = items.filter { item in
            guard !locked.contains(item.id), item.effectiveCaptureDate != nil,
                  item.captureDateSourceRaw != undated else { return false }
            guard let tripID = item.trip?.id ?? item.tripID else { return false }
            return !kept.contains(tripID) && tripIDs.contains(tripID)
        }
        guard !free.isEmpty else { return Outcome() }
        let freeIDs = Set(free.map(\.id))

        var segmenter = TripSegmenter()
        segmenter.maximumTimeGap = configuration.maximumTimeGap
        segmenter.maximumTripDistanceMeters = configuration.maximumTripDistanceMeters
        segmenter.fixedUsualPlace = configuration.homeCoordinate
        let stops = free.map { item in
            PhotoStop(id: item.id, date: item.effectiveCaptureDate ?? .distantPast, coordinate: coordinate(of: item))
        }
        let library = ImportOrganizer.libraryStops(items.filter { !freeIDs.contains($0.id) })
        let result = segmenter.segment(stops, context: library)

        let byID = Dictionary(free.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldTripIDs = Dictionary(free.compactMap { item in (item.trip?.id ?? item.tripID).map { (item.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let replaceable = Dictionary(trips.filter { !kept.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reused = Set<String>()
        var outcome = Outcome()

        for (index, ids) in result.trips.enumerated() {
            let members = ids.compactMap { byID[$0] }
            guard !members.isEmpty else { continue }
            // The old trip holding most of these photos carries on.
            let counts = Dictionary(ids.compactMap { oldTripIDs[$0] }.filter { replaceable[$0] != nil && !reused.contains($0) }.map { ($0, 1) }, uniquingKeysWith: +)
            let previous = counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }
                .flatMap { replaceable[$0.key] }
            let dates = members.compactMap(\.effectiveCaptureDate)
            let trip: Trip
            if let previous {
                trip = previous
                reused.insert(previous.id)
            } else {
                trip = Trip(id: stableID(ids), name: "", suggestionStatusRaw: "suggestion")
                context.insert(trip)
            }
            trip.startDate = dates.min()
            trip.endDate = dates.max()
            for item in members where item.trip?.id != trip.id {
                item.trip = trip
                item.tripID = trip.id
                item.updatedAt = .now
            }
            trip.name = name(for: members, start: trip.startDate, index: index + 1, calendar: calendar)
            trip.updatedAt = .now
            outcome.trips += 1
        }
        for id in result.atUsualPlaceIDs {
            guard let item = byID[id], item.trip != nil || item.tripID != nil else { continue }
            item.trip = nil
            item.tripID = nil
            item.updatedAt = .now
            outcome.leftTrips += 1
        }
        // Saved before the deletes, so they cannot take photos along.
        try context.save()
        for trip in replaceable.values where !reused.contains(trip.id) {
            // What is left is in Recently Deleted or dated by file only.
            let left = trip.items
            if left.allSatisfy({ $0.deletedAt != nil }) {
                for item in left {
                    item.trip = nil
                    item.tripID = nil
                }
                context.delete(trip)
                outcome.removed += 1
            } else {
                let dates = left.filter { $0.deletedAt == nil }.compactMap(\.effectiveCaptureDate)
                trip.startDate = dates.min()
                trip.endDate = dates.max()
            }
        }
        try context.save()
        return outcome
    }

    /// Trips someone shaped by hand: renamed, confirmed, edited, merged,
    /// split, given a cover or a trip memory, or holding a photo placed by
    /// hand. Every hand edit sets `updatedBy`; imports never do.
    static func keptTripIDs(_ trips: [Trip], context: ModelContext, locked: Set<String>, covered: Set<String>) throws -> Set<String> {
        let tripScope = NoteMemoryScope.trip.rawValue
        let remembered = Set(try context.fetch(FetchDescriptor<CollectionMemory>(
            predicate: #Predicate { $0.scopeRaw == tripScope }
        )).map(\.scopeKey))
        return Set(trips.filter { trip in
            trip.overrideName != nil || !trip.isSuggestion || trip.updatedBy != nil
                || trip.mergeOverrideID != nil || trip.splitOverrideDayKeys != nil
                || remembered.contains(trip.id) || covered.contains(trip.id)
                || trip.items.contains { locked.contains($0.id) }
        }.map(\.id))
    }

    /// Place and month for up to three named cities. A longer trip, or one
    /// whose cities are not named yet, gets the month alone, which
    /// `TripNameBackfill` turns into place and month later.
    private static func name(for members: [MediaItem], start: Date?, index: Int, calendar: Calendar) -> String {
        let cities = TripNameBackfill.orderedCities(of: members).map(\.name)
        let place = Set(cities).count <= 3 ? cities : []
        return TripNaming.name(cities: place, countries: [], start: start, index: index, calendar: calendar)
    }

    private static func coordinate(of item: MediaItem) -> GeoPoint? {
        guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    static func stableID(_ ids: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in ("trip\u{0}" + ids.sorted().joined(separator: "\u{0}")).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "trip-\(String(hash, radix: 16))"
    }
}

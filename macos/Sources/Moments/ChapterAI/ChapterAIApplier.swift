import Foundation
import MomentsCore
import SwiftData

/// The chapters Moments made itself, so a later run may make them again,
/// and the ones someone deleted, so no run brings them back. Kept on this
/// Mac with the trip locks.
struct ChapterAIRegistry: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var start: String
        var end: String
        var isTrip: Bool
        /// The chapter's `updatedAt` when Moments wrote it; a chapter
        /// changed since was changed by hand.
        var stamp: Double
    }

    static let defaultsKey = "moments.chapterAI.registry"

    var made: [String: Entry] = [:]
    var dismissed: [Entry] = []

    static func load(_ defaults: UserDefaults) -> ChapterAIRegistry {
        guard let data = defaults.data(forKey: defaultsKey),
              let registry = try? JSONDecoder().decode(ChapterAIRegistry.self, from: data) else { return ChapterAIRegistry() }
        return registry
    }

    func save(_ defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

/// Writes the model's chapters: trips as `Trip`s, other kinds as chapter
/// groups. What people made or changed by hand stays as it is, and the whole
/// write can be undone.
@MainActor
struct ChapterAIApplier {
    let context: ModelContext
    var defaults: UserDefaults = TripAssignmentLocks.store
    var calendar: Calendar = .current
    var now: Date = .now

    struct Outcome: Equatable {
        var trips = 0
        var chapters = 0
        /// Chapters Moments had made before, replaced by this run.
        var removed = 0
        /// Photos that left a trip Moments had put them in.
        var left = 0
        var skipped: [ChapterProposal] = []
    }

    struct Written {
        var outcome: Outcome
        var undo: TripEdits.Undo
        /// Put back on undo.
        var registryBefore: ChapterAIRegistry
    }

    /// Which chapters this run may redo, and which it must leave alone.
    struct State {
        var registry: ChapterAIRegistry
        var replaceableTrips: [String: Trip]
        var keptTrips: [Trip]
        var machineGroups: [String: UserGroup]
        var keptGroups: [UserGroup]
        var locked: Set<String>

        var keptTripIDs: Set<String> { Set(keptTrips.map(\.id)) }
    }

    func state() throws -> State {
        var registry = ChapterAIRegistry.load(defaults)
        let locked = TripAssignmentLocks.lockedIDs(defaults: defaults)
        let covered = Set(TripCoverChoice.decode(defaults.string(forKey: TripCoverChoice.defaultsKey) ?? "").keys)
        let trips = try context.fetch(FetchDescriptor<Trip>())
        let kept = try TripRegrouping.keptTripIDs(trips, context: context, locked: locked, covered: covered)
        let groups = try context.fetch(FetchDescriptor<UserGroup>(predicate: #Predicate { $0.kindRaw == "chapter" }))
        var machineGroups: [String: UserGroup] = [:]
        var keptGroups: [UserGroup] = []
        for group in groups {
            if let entry = registry.made[group.id], abs(group.updatedAt.timeIntervalSince1970 - entry.stamp) < 1 {
                machineGroups[group.id] = group
            } else {
                // Made by hand, or changed by hand since Moments made it.
                registry.made[group.id] = nil
                keptGroups.append(group)
            }
        }
        let tripIDs = Set(trips.map(\.id))
        for (id, entry) in registry.made where !tripIDs.contains(id) && machineGroups[id] == nil {
            // Someone deleted it.
            registry.made[id] = nil
            registry.dismissed.append(entry)
        }
        for id in kept { registry.made[id] = nil }
        return State(
            registry: registry,
            replaceableTrips: Dictionary(trips.filter { !kept.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            keptTrips: trips.filter { kept.contains($0.id) },
            machineGroups: machineGroups,
            keptGroups: keptGroups,
            locked: locked
        )
    }

    /// Days in chapters people made or changed, and chapters they deleted.
    func taken(_ state: State) -> [ChapterAssignment.Taken] {
        var taken: [ChapterAssignment.Taken] = []
        for trip in state.keptTrips {
            guard let start = trip.startDate, let end = trip.endDate else { continue }
            taken.append(.init(start: TripEdits.dayKey(start, calendar: calendar), end: TripEdits.dayKey(end, calendar: calendar), isTrip: true))
        }
        for group in state.keptGroups {
            guard let range = dayRange(of: group) else { continue }
            taken.append(.init(start: range.lowerBound, end: range.upperBound, isTrip: false))
        }
        taken += state.registry.dismissed.map { .init(start: $0.start, end: $0.end, isTrip: $0.isTrip) }
        return taken
    }

    func dayRange(of group: UserGroup) -> ClosedRange<String>? {
        let info = group.chapterInfo
        guard let start = info.startDate, let end = info.endDate, start <= end else { return nil }
        return TripEdits.dayKey(start, calendar: calendar)...TripEdits.dayKey(end, calendar: calendar)
    }

    func apply(_ proposals: [ChapterProposal], scope: ClosedRange<String>? = nil) throws -> Written {
        let before = ChapterAIRegistry.load(defaults)
        let state = try state()
        var registry = state.registry
        let session = TripEdits.Session(context: context, now: now, calendar: calendar, defaults: defaults)
        var outcome = Outcome()

        let undated = ImportCaptureDateSource.fileDateFallback.rawValue
        let items = try context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil }))
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let keptTripIDs = state.keptTripIDs
        let assignable = items.compactMap { item -> ChapterAssignment.Item? in
            guard item.captureDateSourceRaw != undated, ChapterAIApplier.isMine(item),
                  let key = PhotoNoteDay.key(for: item) else { return nil }
            let tripID = item.trip?.id ?? item.tripID
            return ChapterAssignment.Item(
                id: item.id,
                dayKey: key,
                isScreenshot: item.isScreenshot,
                isFree: !state.locked.contains(item.id) && !(tripID.map { keptTripIDs.contains($0) } ?? false),
                isInMachineTrip: tripID.map { state.replaceableTrips[$0] != nil } ?? false
            )
        }
        let result = ChapterAssignment.assign(items: assignable, proposals: proposals, taken: taken(state), scope: scope)
        outcome.skipped = result.skipped

        // Chapters Moments made before, in the days looked at again.
        for group in state.machineGroups.values {
            if let scope, let range = dayRange(of: group), !range.overlaps(scope) { continue }
            TripEdits.delete(group, session: session)
            registry.made[group.id] = nil
            outcome.removed += 1
        }

        for chapter in result.chapters {
            guard let start = TripEdits.dayStart(chapter.proposal.start, calendar: calendar),
                  let lastDay = TripEdits.dayStart(chapter.proposal.end, calendar: calendar) else { continue }
            let group = UserGroup(name: chapter.proposal.title, kind: .chapter, createdAt: now, updatedAt: now)
            group.chapterInfo = ChapterInfo(
                type: ChapterType(raw: chapter.proposal.type.rawValue).raw,
                symbol: nil,
                startDate: start,
                endDate: TripEdits.endOfDay(lastDay, calendar: calendar),
                summary: chapter.proposal.summary.isEmpty ? nil : chapter.proposal.summary,
                madeBy: "ai"
            )
            context.insert(group)
            session.created(group)
            for id in chapter.itemIDs {
                let membership = UserGroupItem(groupID: group.id, mediaID: id, addedAt: now)
                context.insert(membership)
                session.created(membership)
            }
            registry.made[group.id] = .init(start: chapter.proposal.start, end: chapter.proposal.end, isTrip: false, stamp: now.timeIntervalSince1970)
            outcome.chapters += 1
        }

        var reused = Set<String>()
        for chapter in result.trips {
            let members = chapter.itemIDs.compactMap { byID[$0] }
            // The old trip holding most of these photos carries on.
            let counts = Dictionary(members.compactMap { $0.trip?.id ?? $0.tripID }
                .filter { state.replaceableTrips[$0] != nil && !reused.contains($0) }
                .map { ($0, 1) }, uniquingKeysWith: +)
            let previous = counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }
                .flatMap { state.replaceableTrips[$0.key] }
            let trip: Trip
            if let previous {
                trip = previous
                session.record(trip)
                reused.insert(trip.id)
            } else {
                trip = Trip(id: TripRegrouping.stableID(chapter.itemIDs), name: chapter.proposal.title, suggestionStatusRaw: "suggestion")
                context.insert(trip)
                session.created(trip)
            }
            let dates = members.compactMap(\.effectiveCaptureDate)
            trip.name = chapter.proposal.title
            trip.startDate = dates.min()
            trip.endDate = dates.max()
            trip.updatedAt = now
            for item in members where item.trip?.id != trip.id { session.place(item, in: trip) }
            registry.made[trip.id] = .init(start: chapter.proposal.start, end: chapter.proposal.end, isTrip: true, stamp: now.timeIntervalSince1970)
            outcome.trips += 1
        }
        for id in result.leaving {
            guard let item = byID[id] else { continue }
            session.place(item, in: nil)
            outcome.left += 1
        }
        // Saved before the deletes, so they cannot take photos along.
        try context.save()

        for trip in state.replaceableTrips.values where !reused.contains(trip.id) {
            let left = trip.items.filter { $0.deletedAt == nil }
            session.record(trip)
            if left.isEmpty {
                for item in trip.items { session.place(item, in: nil) }
                context.delete(trip)
                registry.made[trip.id] = nil
                outcome.removed += 1
            } else {
                let dates = left.compactMap(\.effectiveCaptureDate)
                trip.startDate = dates.min()
                trip.endDate = dates.max()
            }
        }
        try context.save()
        registry.save(defaults)
        return Written(outcome: outcome, undo: session.undo, registryBefore: before)
    }

    /// Puts back what one run wrote.
    static func undo(_ written: Written, context: ModelContext, defaults: UserDefaults = TripAssignmentLocks.store) {
        TripEdits.undo(written.undo, context: context, defaults: defaults)
        written.registryBefore.save(defaults)
    }

    /// The person's own photos; a partner's shared photos are never sent.
    static func isMine(_ item: MediaItem) -> Bool {
        item.ownerAccountID == nil || item.ownerAccountID == MomentsAccount.localID
    }
}

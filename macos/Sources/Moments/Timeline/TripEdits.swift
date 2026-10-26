import Foundation
import MomentsCore
import SwiftData

/// Changes to which photos a trip holds: new dates, a day added or taken
/// out, a trip split in two or two trips merged. Every change can be undone
/// in one step.
///
/// Changing the dates re-sorts photos on its own:
/// - photos in the new dates that belong to no trip join;
/// - the trip's photos outside the new dates leave ("Not in a trip");
/// - photos in the new dates that another trip holds stay there and are
///   offered afterwards;
/// - photos someone placed by hand (`TripAssignmentLocks`) and photos
///   without a date never move.
/// Adding or removing a day, splitting and merging are done by hand, so
/// they move what was asked for and lock it.
enum TripEdits {
    struct Member: Equatable {
        let id: String
        let date: Date?
        let tripID: String?
        let isLocked: Bool
    }

    struct Plan: Equatable {
        var joining: [String] = []
        var leaving: [String] = []
        /// Photos in the new dates that another trip holds, by that trip's id.
        var elsewhere: [String: [String]] = [:]
    }

    /// From the start day's midnight to the end day's last second.
    static func range(start: Date, end: Date, calendar: Calendar) -> ClosedRange<Date> {
        let first = calendar.startOfDay(for: min(start, end))
        return first...endOfDay(max(start, end), calendar: calendar)
    }

    static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        return next.addingTimeInterval(-1)
    }

    static func plan(tripID: String, range: ClosedRange<Date>, members: [Member]) -> Plan {
        var plan = Plan()
        for member in members where !member.isLocked {
            guard let date = member.date else { continue }
            let inside = range.contains(date)
            if member.tripID == tripID {
                if !inside { plan.leaving.append(member.id) }
            } else if let other = member.tripID {
                if inside { plan.elsewhere[other, default: []].append(member.id) }
            } else if inside {
                plan.joining.append(member.id)
            }
        }
        return plan
    }

    // MARK: Undo

    struct TripState {
        let name: String
        let overrideName: String?
        let startDate: Date?
        let endDate: Date?
        let suggestionStatusRaw: String?
        let confirmedAt: Date?

        init(_ trip: Trip) {
            name = trip.name
            overrideName = trip.overrideName
            startDate = trip.startDate
            endDate = trip.endDate
            suggestionStatusRaw = trip.suggestionStatusRaw
            confirmedAt = trip.confirmedAt
        }
    }

    /// Everything one change touched, as it was before.
    struct Undo {
        /// `nil` for a trip the change created.
        fileprivate(set) var trips: [String: TripState?] = [:]
        /// Each moved photo and the trip it was in.
        fileprivate(set) var items: [String: String?] = [:]
        fileprivate(set) var memoryKeys: [String: String] = [:]
        fileprivate(set) var newLocks: Set<String> = []

        var isEmpty: Bool { trips.isEmpty && items.isEmpty && memoryKeys.isEmpty }
    }

    /// Records each thing before it changes, then saves.
    @MainActor
    final class Session {
        let context: ModelContext
        let now: Date
        let calendar: Calendar
        private(set) var undo: Undo
        private let defaults: UserDefaults

        init(context: ModelContext, now: Date = .now, calendar: Calendar = .current, defaults: UserDefaults = .standard, continuing undo: Undo = Undo()) {
            self.context = context
            self.now = now
            self.calendar = calendar
            self.defaults = defaults
            self.undo = undo
        }

        func record(_ trip: Trip) {
            if undo.trips[trip.id] == nil { undo.trips[trip.id] = .some(TripState(trip)) }
        }

        func created(_ trip: Trip) {
            if undo.trips[trip.id] == nil { undo.trips[trip.id] = .some(nil) }
        }

        func move(_ item: MediaItem, to trip: Trip?, lock: Bool = false) {
            if undo.items[item.id] == nil { undo.items[item.id] = .some(item.trip?.id ?? item.tripID) }
            item.trip = trip
            item.tripID = trip?.id
            item.updatedAt = now
            item.updatedBy = MomentsAccount.localID
            if lock, !TripAssignmentLocks.isLocked(item.id, defaults: defaults) {
                TripAssignmentLocks.lock(item.id, defaults: defaults)
                undo.newLocks.insert(item.id)
            }
        }

        func rekey(_ memory: CollectionMemory, to key: String) {
            if undo.memoryKeys[memory.id] == nil { undo.memoryKeys[memory.id] = memory.scopeKey }
            memory.scopeKey = key
            memory.updatedAt = now
        }

        func touch(_ trip: Trip) {
            trip.updatedAt = now
            trip.updatedBy = MomentsAccount.localID
        }

        func save() { try? context.save() }

        var allItems: [MediaItem] { (try? context.fetch(FetchDescriptor<MediaItem>())) ?? [] }
        var allTrips: [Trip] { (try? context.fetch(FetchDescriptor<Trip>())) ?? [] }
    }

    /// Puts back the dates, names, photos and memories one change touched.
    @MainActor
    static func undo(_ undo: Undo, context: ModelContext, defaults: UserDefaults = .standard, now: Date = .now) {
        var tripByID = Dictionary(
            ((try? context.fetch(FetchDescriptor<Trip>())) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (id, state) in undo.trips {
            if let state {
                let trip = tripByID[id] ?? {
                    // A trip merged away comes back under its own id.
                    let trip = Trip(id: id, name: state.name)
                    context.insert(trip)
                    tripByID[id] = trip
                    return trip
                }()
                trip.name = state.name
                trip.overrideName = state.overrideName
                trip.startDate = state.startDate
                trip.endDate = state.endDate
                trip.suggestionStatusRaw = state.suggestionStatusRaw
                trip.confirmedAt = state.confirmedAt
                trip.updatedAt = now
            }
        }
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        for item in items {
            guard let previous = undo.items[item.id] else { continue }
            let trip = previous.flatMap { tripByID[$0] }
            item.trip = trip
            item.tripID = trip?.id
            item.updatedAt = now
        }
        if !undo.memoryKeys.isEmpty {
            let memories = (try? context.fetch(FetchDescriptor<CollectionMemory>())) ?? []
            for memory in memories {
                guard let key = undo.memoryKeys[memory.id] else { continue }
                memory.scopeKey = key
                memory.updatedAt = now
            }
        }
        // Trips the change created go last, once their photos have left.
        for (id, state) in undo.trips where state == nil {
            if let trip = tripByID[id] { context.delete(trip) }
        }
        if !undo.newLocks.isEmpty {
            let kept = TripAssignmentLocks.lockedIDs(defaults: defaults).subtracting(undo.newLocks)
            defaults.set(Array(kept).sorted(), forKey: TripAssignmentLocks.defaultsKey)
        }
        try? context.save()
    }

    // MARK: Dates

    /// What new dates would do, for the preview before they are applied.
    @MainActor
    static func preview(_ trip: Trip, start: Date, end: Date, context: ModelContext, calendar: Calendar = .current, locked: Set<String> = TripAssignmentLocks.lockedIDs()) -> Plan {
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        return plan(tripID: trip.id, range: range(start: start, end: end, calendar: calendar), members: members(items, locked: locked))
    }

    struct DatesOutcome {
        var undo: Undo
        let joined: Int
        let left: Int
        /// Other trips holding photos in the new dates, most photos first.
        let elsewhere: [(tripID: String, name: String, itemIDs: [String])]
    }

    @MainActor
    static func changeDates(of trip: Trip, start: Date, end: Date, session: Session, locked: Set<String> = TripAssignmentLocks.lockedIDs()) -> DatesOutcome {
        let items = session.allItems
        let range = Self.range(start: start, end: end, calendar: session.calendar)
        let plan = Self.plan(tripID: trip.id, range: range, members: members(items, locked: locked))
        let itemByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldStart = firstDay(of: trip)

        session.record(trip)
        trip.startDate = range.lowerBound
        trip.endDate = range.upperBound
        for id in plan.leaving { if let item = itemByID[id] { session.move(item, to: nil) } }
        for id in plan.joining { if let item = itemByID[id] { session.move(item, to: trip) } }
        rename(trip, start: range.lowerBound, oldStart: oldStart, session: session)
        session.touch(trip)
        session.save()

        let names = Dictionary(session.allTrips.map { ($0.id, $0.effectiveName) }, uniquingKeysWith: { first, _ in first })
        let elsewhere = plan.elsewhere
            .map { (tripID: $0.key, name: names[$0.key] ?? "", itemIDs: $0.value) }
            .sorted { $0.itemIDs.count > $1.itemIDs.count }
        return DatesOutcome(undo: session.undo, joined: plan.joining.count, left: plan.leaving.count, elsewhere: elsewhere)
    }

    // MARK: By hand

    /// Photos join the trip, and its dates stretch to hold them.
    @MainActor
    static func add(_ itemIDs: [String], to trip: Trip, session: Session) {
        let wanted = Set(itemIDs)
        let items = session.allItems.filter { wanted.contains($0.id) }
        guard !items.isEmpty else { return }
        let oldStart = firstDay(of: trip)
        session.record(trip)
        for item in items { session.move(item, to: trip, lock: true) }
        stretchDates(of: trip, toHold: items.compactMap(\.effectiveCaptureDate), calendar: session.calendar)
        rename(trip, start: trip.startDate ?? oldStart, oldStart: oldStart, session: session)
        session.touch(trip)
        session.save()
    }

    /// One day's photos leave the trip; a first or last day also leaves its dates.
    @MainActor
    static func removeDay(_ day: Date, from trip: Trip, session: Session) {
        let calendar = session.calendar
        let leaving = trip.items.filter { item in
            item.effectiveCaptureDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        }
        guard !leaving.isEmpty else { return }
        let oldStart = firstDay(of: trip)
        session.record(trip)
        for item in leaving { session.move(item, to: nil, lock: true) }
        let remaining = trip.items.filter { item in !leaving.contains { $0.id == item.id } }.compactMap(\.effectiveCaptureDate)
        if let first = remaining.min(), let last = remaining.max() {
            if let start = trip.startDate, calendar.isDate(start, inSameDayAs: day) || start > first {
                trip.startDate = calendar.startOfDay(for: first)
            }
            if let end = trip.endDate, calendar.isDate(end, inSameDayAs: day) || end < last {
                trip.endDate = endOfDay(last, calendar: calendar)
            }
        }
        rename(trip, start: trip.startDate ?? oldStart, oldStart: oldStart, session: session)
        session.touch(trip)
        session.save()
    }

    /// The trip ends the day before `day`; a new trip starts on it with the
    /// photos from that day on. The trip's memories stay with the first part.
    @MainActor
    @discardableResult
    static func split(_ trip: Trip, at day: Date, session: Session) -> Trip? {
        let calendar = session.calendar
        let cut = calendar.startOfDay(for: day)
        let later = trip.items.filter { ($0.effectiveCaptureDate ?? .distantPast) >= cut }
        let earlier = trip.items.filter { ($0.effectiveCaptureDate ?? .distantPast) < cut && $0.effectiveCaptureDate != nil }
        guard !later.isEmpty, !earlier.isEmpty else { return nil }
        let oldStart = firstDay(of: trip)
        let oldEnd = trip.endDate

        session.record(trip)
        let part = Trip(name: "", startDate: cut, endDate: oldEnd, updatedAt: session.now, updatedBy: MomentsAccount.localID)
        session.context.insert(part)
        session.created(part)
        for item in later { session.move(item, to: part, lock: true) }
        if let last = earlier.compactMap(\.effectiveCaptureDate).max() {
            trip.endDate = endOfDay(last, calendar: calendar)
        }
        if let end = part.endDate, let last = later.compactMap(\.effectiveCaptureDate).max(), end < last {
            part.endDate = endOfDay(last, calendar: calendar)
        }
        rename(trip, start: oldStart, oldStart: oldStart, session: session)
        part.name = defaultName(items: later, start: cut, calendar: calendar)
            ?? TripNaming.name(cities: [], countries: [], start: cut, index: 1, calendar: calendar)
        session.touch(trip)
        session.save()
        return part
    }

    /// `other`'s photos and trip memories move into `trip`, its dates widen
    /// to hold both, and `other` goes away.
    @MainActor
    static func merge(_ other: Trip, into trip: Trip, session: Session) {
        guard other.id != trip.id else { return }
        let oldStart = firstDay(of: trip)
        session.record(trip)
        session.record(other)
        let moving = other.items
        for item in moving { session.move(item, to: trip, lock: true) }
        let memories = (try? session.context.fetch(FetchDescriptor<CollectionMemory>())) ?? []
        for memory in memories where memory.scope == .trip && memory.scopeKey == other.id {
            session.rekey(memory, to: trip.id)
        }
        let starts = [trip.startDate, other.startDate].compactMap { $0 }
        let ends = [trip.endDate, other.endDate].compactMap { $0 }
        if let first = starts.min() { trip.startDate = first }
        if let last = ends.max() { trip.endDate = last }
        stretchDates(of: trip, toHold: moving.compactMap(\.effectiveCaptureDate), calendar: session.calendar)
        rename(trip, start: trip.startDate ?? oldStart, oldStart: oldStart, session: session)
        session.touch(trip)
        session.context.delete(other)
        session.save()
    }

    // MARK: Helpers

    private static func members(_ items: [MediaItem], locked: Set<String>) -> [Member] {
        items.map { item in
            Member(id: item.id, date: item.effectiveCaptureDate, tripID: item.trip?.id ?? item.tripID, isLocked: locked.contains(item.id))
        }
    }

    private static func firstDay(of trip: Trip) -> Date? {
        trip.startDate ?? trip.items.compactMap(\.effectiveCaptureDate).min()
    }

    private static func stretchDates(of trip: Trip, toHold dates: [Date], calendar: Calendar) {
        guard let first = dates.min(), let last = dates.max() else { return }
        if trip.startDate.map({ first < $0 }) ?? true { trip.startDate = calendar.startOfDay(for: first) }
        if trip.endDate.map({ last > $0 }) ?? true { trip.endDate = endOfDay(last, calendar: calendar) }
    }

    /// A name the app gave follows the trip's photos and month; a name
    /// someone typed (`overrideName`) stays.
    @MainActor
    private static func rename(_ trip: Trip, start: Date?, oldStart: Date?, session: Session) {
        guard trip.overrideName == nil, let start else { return }
        // By id, not `trip.items`: the moves above are not saved yet.
        let items = session.allItems.filter { $0.tripID == trip.id }
        if let name = defaultName(items: items, start: start, calendar: session.calendar) {
            trip.name = name
            return
        }
        // A long trip is named after its country, which needs a lookup:
        // keep the place and change only the month.
        guard let oldStart else { return }
        let oldMonth = TripNaming.month(oldStart, calendar: session.calendar)
        if trip.name.hasSuffix(oldMonth) {
            trip.name = String(trip.name.dropLast(oldMonth.count)) + TripNaming.month(start, calendar: session.calendar)
        }
    }

    /// "Lisbon · Porto April 2026" when the photos reach at most three
    /// named cities; `nil` when a name needs the country.
    @MainActor
    private static func defaultName(items: [MediaItem], start: Date, calendar: Calendar) -> String? {
        let cities = TripNameBackfill.orderedCities(of: items).map(\.name)
        guard !cities.isEmpty, Set(cities).count <= 3 else { return nil }
        return TripNaming.name(cities: cities, countries: [], start: start, index: 1, calendar: calendar)
    }
}

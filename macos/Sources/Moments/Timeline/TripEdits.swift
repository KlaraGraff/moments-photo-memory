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
        /// The photo's own `yyyy-MM-dd`, the day the Trips page shows it under.
        let dayKey: String?
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

    /// The photo's own day, as the Trips page groups it: its local day from
    /// import, so a trip abroad keeps its days whatever the Mac's time zone.
    static func dayKey(_ item: MediaItem) -> String? { PhotoNoteDay.key(for: item) }

    static func dayKey(_ date: Date, calendar: Calendar) -> String { PhotoNoteDay.key(for: date, calendar: calendar) }

    /// Midnight of a `yyyy-MM-dd` day in `calendar`.
    static func dayStart(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// `first` and `last` are `yyyy-MM-dd`, both included.
    static func plan(tripID: String, first: String, last: String, members: [Member]) -> Plan {
        var plan = Plan()
        for member in members where !member.isLocked {
            guard let key = member.dayKey else { continue }
            let inside = key >= first && key <= last
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
        let mergeOverrideID: String?
        let splitOverrideDayKeys: String?
        let updatedBy: String?

        init(_ trip: Trip) {
            mergeOverrideID = trip.mergeOverrideID
            splitOverrideDayKeys = trip.splitOverrideDayKeys
            updatedBy = trip.updatedBy
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
        /// Chapters that are not trips; `nil` for one the change created.
        fileprivate(set) var groups: [String: GroupState?] = [:]
        /// Chapter memberships by id; `nil` for one the change created.
        fileprivate(set) var memberships: [String: MembershipState?] = [:]

        var isEmpty: Bool { trips.isEmpty && items.isEmpty && memoryKeys.isEmpty && groups.isEmpty && memberships.isEmpty }
    }

    struct GroupState {
        let name: String
        let rulesData: Data
        let kindRaw: String
        let ownerAccountID: String
        let createdAt: Date

        init(_ group: UserGroup) {
            name = group.name
            rulesData = group.rulesData
            kindRaw = group.kindRaw
            ownerAccountID = group.ownerAccountID
            createdAt = group.createdAt
        }
    }

    struct MembershipState {
        let groupID: String
        let mediaID: String
        let excluded: Bool
        let addedBy: String
        let addedAt: Date

        init(_ membership: UserGroupItem) {
            groupID = membership.groupID
            mediaID = membership.mediaID
            excluded = membership.excluded
            addedBy = membership.addedBy
            addedAt = membership.addedAt
        }
    }

    /// Records each thing before it changes, then saves.
    @MainActor
    final class Session {
        let context: ModelContext
        let now: Date
        let calendar: Calendar
        private(set) var undo: Undo
        private let defaults: UserDefaults

        init(context: ModelContext, now: Date = .now, calendar: Calendar = .current, defaults: UserDefaults = TripAssignmentLocks.store, continuing undo: Undo = Undo()) {
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

        func record(_ group: UserGroup) {
            if undo.groups[group.id] == nil { undo.groups[group.id] = .some(GroupState(group)) }
        }

        func created(_ group: UserGroup) {
            if undo.groups[group.id] == nil { undo.groups[group.id] = .some(nil) }
        }

        func record(_ membership: UserGroupItem) {
            if undo.memberships[membership.id] == nil { undo.memberships[membership.id] = .some(MembershipState(membership)) }
        }

        func created(_ membership: UserGroupItem) {
            if undo.memberships[membership.id] == nil { undo.memberships[membership.id] = .some(nil) }
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
    static func undo(_ undo: Undo, context: ModelContext, defaults: UserDefaults = TripAssignmentLocks.store, now: Date = .now) {
        var tripByID = Dictionary(
            ((try? context.fetch(FetchDescriptor<Trip>())) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (id, state) in undo.trips {
            if let state {
                let trip: Trip
                if let existing = tripByID[id] {
                    trip = existing
                } else {
                    // A trip merged away comes back under its own id.
                    trip = Trip(id: id, name: state.name)
                    context.insert(trip)
                    tripByID[id] = trip
                }
                trip.name = state.name
                trip.overrideName = state.overrideName
                trip.startDate = state.startDate
                trip.endDate = state.endDate
                trip.suggestionStatusRaw = state.suggestionStatusRaw
                trip.confirmedAt = state.confirmedAt
                trip.mergeOverrideID = state.mergeOverrideID
                trip.splitOverrideDayKeys = state.splitOverrideDayKeys
                trip.updatedBy = state.updatedBy
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
        // Chapters that are not trips, and their photos.
        var groupByID = Dictionary(
            ((try? context.fetch(FetchDescriptor<UserGroup>())) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (id, state) in undo.groups {
            guard let state else { continue }
            let group: UserGroup
            if let existing = groupByID[id] {
                group = existing
            } else {
                group = UserGroup(id: id, name: state.name, ownerAccountID: state.ownerAccountID, createdAt: state.createdAt)
                context.insert(group)
                groupByID[id] = group
            }
            group.name = state.name
            group.kindRaw = state.kindRaw
            group.rulesData = state.rulesData
            group.updatedAt = now
        }
        if !undo.memberships.isEmpty {
            let memberships = Dictionary(
                ((try? context.fetch(FetchDescriptor<UserGroupItem>())) ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for (id, state) in undo.memberships {
                if let state {
                    let membership = memberships[id] ?? {
                        let restored = UserGroupItem(id: id, groupID: state.groupID, mediaID: state.mediaID, addedBy: state.addedBy, addedAt: state.addedAt)
                        context.insert(restored)
                        return restored
                    }()
                    membership.excluded = state.excluded
                } else if let membership = memberships[id] {
                    context.delete(membership)
                }
            }
        }
        let createdGroups = Set(undo.groups.filter { $0.value == nil }.map(\.key))
        if !createdGroups.isEmpty {
            // Rows added to a created chapter after it was made go with it.
            for membership in (try? context.fetch(FetchDescriptor<UserGroupItem>())) ?? [] where createdGroups.contains(membership.groupID) {
                context.delete(membership)
            }
        }
        for id in createdGroups {
            if let group = groupByID[id] { context.delete(group) }
        }

        // Trips the change created go last, once their photos have left and
        // that is saved, so deleting them cannot take the photos' trip along.
        try? context.save()
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

    /// Members gathered once, for a preview that follows the date pickers.
    @MainActor
    static func members(context: ModelContext, locked: Set<String> = TripAssignmentLocks.lockedIDs()) -> [Member] {
        // Photos in Recently Deleted keep their trip but don't count in it.
        let items = (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        return members(items, trips: trips, locked: locked)
    }

    static func plan(for trip: Trip, start: Date, end: Date, members: [Member], calendar: Calendar) -> Plan {
        plan(
            tripID: trip.id,
            first: dayKey(min(start, end), calendar: calendar),
            last: dayKey(max(start, end), calendar: calendar),
            members: members
        )
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
        let plan = Self.plan(for: trip, start: start, end: end, members: members(items, trips: session.allTrips, locked: locked), calendar: session.calendar)
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

    /// A new trip over these dates. Photos in them that belong to no trip
    /// join, as when a trip's dates change. A typed name is kept as the
    /// trip's own; without one the trip is named after its places.
    @MainActor
    static func create(named name: String, start: Date, end: Date, session: Session, locked: Set<String> = TripAssignmentLocks.lockedIDs()) -> (trip: Trip, outcome: DatesOutcome) {
        let range = Self.range(start: start, end: end, calendar: session.calendar)
        let trip = Trip(
            name: TripNaming.name(cities: [], countries: [], start: range.lowerBound, index: 1, calendar: session.calendar),
            startDate: range.lowerBound,
            endDate: range.upperBound,
            updatedAt: session.now,
            updatedBy: MomentsAccount.localID
        )
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { trip.overrideName = typed }
        session.context.insert(trip)
        session.created(trip)
        let outcome = changeDates(of: trip, start: start, end: end, session: session, locked: locked)
        return (trip, outcome)
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
        stretchDates(of: trip, toHold: items.compactMap { dayKey($0) }, calendar: session.calendar)
        rename(trip, start: trip.startDate ?? oldStart, oldStart: oldStart, session: session)
        session.touch(trip)
        session.save()
    }

    /// One day's photos leave the trip; a first or last day also leaves its dates.
    @MainActor
    static func removeDay(_ key: String, from trip: Trip, session: Session) {
        let calendar = session.calendar
        let leaving = trip.items.filter { dayKey($0) == key }
        guard !leaving.isEmpty else { return }
        let oldStart = firstDay(of: trip)
        session.record(trip)
        for item in leaving { session.move(item, to: nil, lock: true) }
        let remaining = trip.items.filter { $0.tripID == trip.id && dayKey($0) != key }.compactMap { dayKey($0) }
        if let first = remaining.min(), let last = remaining.max() {
            if let start = trip.startDate, dayKey(start, calendar: calendar) == key || dayKey(start, calendar: calendar) > first,
               let day = dayStart(first, calendar: calendar) {
                trip.startDate = day
            }
            if let end = trip.endDate, dayKey(end, calendar: calendar) == key || dayKey(end, calendar: calendar) < last,
               let day = dayStart(last, calendar: calendar) {
                trip.endDate = endOfDay(day, calendar: calendar)
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
    static func split(_ trip: Trip, at key: String, session: Session) -> Trip? {
        let calendar = session.calendar
        guard let cut = dayStart(key, calendar: calendar) else { return nil }
        let later = trip.items.filter { (dayKey($0) ?? "") >= key }
        let earlier = trip.items.filter { dayKey($0).map { $0 < key } ?? false }
        guard !later.isEmpty, !earlier.isEmpty else { return nil }
        let oldStart = firstDay(of: trip)
        let oldEnd = trip.endDate

        session.record(trip)
        let part = Trip(name: "", startDate: cut, endDate: oldEnd, updatedAt: session.now, updatedBy: MomentsAccount.localID)
        session.context.insert(part)
        session.created(part)
        for item in later { session.move(item, to: part, lock: true) }
        if let last = earlier.compactMap { dayKey($0) }.max(), let day = dayStart(last, calendar: calendar) {
            trip.endDate = endOfDay(day, calendar: calendar)
        }
        if let last = later.compactMap { dayKey($0) }.max(), let day = dayStart(last, calendar: calendar),
           part.endDate.map({ dayKey($0, calendar: calendar) < last }) ?? true {
            part.endDate = endOfDay(day, calendar: calendar)
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
        stretchDates(of: trip, toHold: moving.compactMap { dayKey($0) }, calendar: session.calendar)
        rename(trip, start: trip.startDate ?? oldStart, oldStart: oldStart, session: session)
        session.touch(trip)
        // Saved before the delete, so it cannot take the photos' new trip along.
        session.save()
        session.context.delete(other)
        session.save()
    }

    // MARK: Helpers

    /// A photo pointing at a trip that no longer exists counts as in no trip,
    /// as it shows on the Trips page.
    private static func members(_ items: [MediaItem], trips: [Trip], locked: Set<String>) -> [Member] {
        let known = Set(trips.map(\.id))
        return items.map { item in
            let tripID = (item.trip?.id ?? item.tripID).flatMap { known.contains($0) ? $0 : nil }
            return Member(id: item.id, dayKey: dayKey(item), tripID: tripID, isLocked: locked.contains(item.id))
        }
    }

    private static func firstDay(of trip: Trip) -> Date? {
        trip.startDate ?? trip.items.compactMap(\.effectiveCaptureDate).min()
    }

    private static func stretchDates(of trip: Trip, toHold keys: [String], calendar: Calendar) {
        guard let first = keys.min(), let last = keys.max() else { return }
        if trip.startDate.map({ first < dayKey($0, calendar: calendar) }) ?? true, let day = dayStart(first, calendar: calendar) {
            trip.startDate = day
        }
        if trip.endDate.map({ last > dayKey($0, calendar: calendar) }) ?? true, let day = dayStart(last, calendar: calendar) {
            trip.endDate = endOfDay(day, calendar: calendar)
        }
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

// MARK: - Chapters that are not trips

/// Events, celebrations, stretches of time and custom chapters keep their
/// photos as `UserGroupItem` rows, so a photo can be in a trip and in any
/// number of them. A photo taken out by hand stays as an `excluded` row, so
/// new dates never bring it back.
extension TripEdits {
    @MainActor
    static func memberships(of group: UserGroup, context: ModelContext) -> [UserGroupItem] {
        let groupID = group.id
        let predicate = #Predicate<UserGroupItem> { $0.groupID == groupID }
        return (try? context.fetch(FetchDescriptor<UserGroupItem>(predicate: predicate))) ?? []
    }

    /// Photos in the chapter now, by id.
    @MainActor
    static func memberIDs(of group: UserGroup, context: ModelContext) -> Set<String> {
        Set(memberships(of: group, context: context).filter { !$0.excluded }.map(\.mediaID))
    }

    /// The chapter's members in the shape `plan` reads: in the chapter, or
    /// not; photos taken out by hand are locked.
    @MainActor
    static func members(of group: UserGroup, context: ModelContext) -> [Member] {
        let rows = memberships(of: group, context: context)
        let inside = Set(rows.filter { !$0.excluded }.map(\.mediaID))
        let excluded = Set(rows.filter(\.excluded).map(\.mediaID))
        let items = (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        return items.map { item in
            Member(id: item.id, dayKey: dayKey(item), tripID: inside.contains(item.id) ? group.id : nil, isLocked: excluded.contains(item.id))
        }
    }

    /// A new chapter over these dates holding every dated photo in them,
    /// whatever trip or chapter they are also in.
    @MainActor
    @discardableResult
    static func createChapter(named name: String, type: ChapterType, symbol: String?, start: Date, end: Date, session: Session) -> UserGroup {
        let range = Self.range(start: start, end: end, calendar: session.calendar)
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = UserGroup(
            name: typed.isEmpty ? type.label + " " + TripNaming.month(range.lowerBound, calendar: session.calendar) : typed,
            kind: .chapter,
            createdAt: session.now,
            updatedAt: session.now
        )
        group.chapterInfo = ChapterInfo(type: type.raw, symbol: symbol, startDate: range.lowerBound, endDate: range.upperBound)
        session.context.insert(group)
        session.created(group)
        let first = dayKey(range.lowerBound, calendar: session.calendar)
        let last = dayKey(range.upperBound, calendar: session.calendar)
        for item in session.allItems {
            guard let key = dayKey(item), key >= first, key <= last else { continue }
            let membership = UserGroupItem(groupID: group.id, mediaID: item.id, addedAt: session.now)
            session.context.insert(membership)
            session.created(membership)
        }
        session.save()
        return group
    }

    /// New dates: photos in them join, the chapter's photos outside leave.
    /// Photos taken out by hand stay out.
    @MainActor
    @discardableResult
    static func changeDates(of group: UserGroup, start: Date, end: Date, session: Session) -> (joined: Int, left: Int) {
        let range = Self.range(start: start, end: end, calendar: session.calendar)
        let plan = Self.plan(for: group.id, start: start, end: end, members: members(of: group, context: session.context), calendar: session.calendar)
        let rows = memberships(of: group, context: session.context)
        session.record(group)
        var info = group.chapterInfo
        info.startDate = range.lowerBound
        info.endDate = range.upperBound
        group.chapterInfo = info
        let leaving = Set(plan.leaving)
        for row in rows where !row.excluded && leaving.contains(row.mediaID) {
            session.record(row)
            session.context.delete(row)
        }
        for id in plan.joining {
            let membership = UserGroupItem(groupID: group.id, mediaID: id, addedAt: session.now)
            session.context.insert(membership)
            session.created(membership)
        }
        group.updatedAt = session.now
        session.save()
        return (plan.joining.count, plan.leaving.count)
    }

    /// Photos join the chapter by hand; its dates stretch to hold them.
    @MainActor
    static func add(_ itemIDs: [String], to group: UserGroup, session: Session) {
        let wanted = Set(itemIDs)
        let rows = memberships(of: group, context: session.context)
        session.record(group)
        for id in wanted {
            if let row = rows.first(where: { $0.mediaID == id }) {
                guard row.excluded else { continue }
                session.record(row)
                row.excluded = false
            } else {
                let membership = UserGroupItem(groupID: group.id, mediaID: id, addedAt: session.now)
                session.context.insert(membership)
                session.created(membership)
            }
        }
        let keys = session.allItems.filter { wanted.contains($0.id) }.compactMap { dayKey($0) }
        stretchChapter(group, toHold: keys, calendar: session.calendar)
        group.updatedAt = session.now
        session.save()
    }

    /// One day's photos leave the chapter and stay out; a first or last day
    /// also leaves its dates.
    @MainActor
    static func removeDay(_ key: String, from group: UserGroup, session: Session) {
        let calendar = session.calendar
        let rows = memberships(of: group, context: session.context).filter { !$0.excluded }
        let keyByID = Dictionary(session.allItems.map { ($0.id, dayKey($0)) }, uniquingKeysWith: { first, _ in first })
        let leaving = rows.filter { keyByID[$0.mediaID] == .some(key) }
        guard !leaving.isEmpty else { return }
        session.record(group)
        for row in leaving {
            session.record(row)
            row.excluded = true
        }
        let remaining = rows.filter { keyByID[$0.mediaID] != .some(key) }.compactMap { keyByID[$0.mediaID] ?? nil }
        var info = group.chapterInfo
        if let first = remaining.min(), let last = remaining.max() {
            if let start = info.startDate, dayKey(start, calendar: calendar) == key, let day = dayStart(first, calendar: calendar) {
                info.startDate = day
            }
            if let end = info.endDate, dayKey(end, calendar: calendar) == key, let day = dayStart(last, calendar: calendar) {
                info.endDate = endOfDay(day, calendar: calendar)
            }
        }
        group.chapterInfo = info
        group.updatedAt = session.now
        session.save()
    }

    /// The chapter goes away; its photos stay in the Library and any trip.
    @MainActor
    static func delete(_ group: UserGroup, session: Session) {
        session.record(group)
        for row in memberships(of: group, context: session.context) {
            session.record(row)
            session.context.delete(row)
        }
        session.save()
        session.context.delete(group)
        session.save()
    }

    /// The trip goes away; its photos become "Not in a trip" and its trip
    /// memories stay stored under its id, back if undone.
    @MainActor
    static func delete(_ trip: Trip, session: Session) {
        session.record(trip)
        for item in trip.items { session.move(item, to: nil) }
        session.save()
        session.context.delete(trip)
        session.save()
    }

    static func plan(for chapterID: String, start: Date, end: Date, members: [Member], calendar: Calendar) -> Plan {
        plan(
            tripID: chapterID,
            first: dayKey(min(start, end), calendar: calendar),
            last: dayKey(max(start, end), calendar: calendar),
            members: members
        )
    }

    private static func stretchChapter(_ group: UserGroup, toHold keys: [String], calendar: Calendar) {
        guard let first = keys.min(), let last = keys.max() else { return }
        var info = group.chapterInfo
        if info.startDate.map({ first < dayKey($0, calendar: calendar) }) ?? true, let day = dayStart(first, calendar: calendar) {
            info.startDate = day
        }
        if info.endDate.map({ last > dayKey($0, calendar: calendar) }) ?? true, let day = dayStart(last, calendar: calendar) {
            info.endDate = endOfDay(day, calendar: calendar)
        }
        group.chapterInfo = info
    }
}

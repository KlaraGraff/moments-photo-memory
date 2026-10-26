import Foundation
import SwiftData

extension MediaItem {
    /// The time zone the photo was taken in: the one set for it, else the
    /// camera's recorded offset, else this Mac's. Times of a photo are shown
    /// in it, as Photos does, so a photo taken at 14:00 in Tokyo reads 14:00.
    var captureTimeZone: TimeZone {
        if let identifier = timeZoneIdentifier, let zone = TimeZone(identifier: identifier) { return zone }
        if let minutes = localTimeZoneOffsetMinutes, let zone = TimeZone(secondsFromGMT: minutes * 60) { return zone }
        return .autoupdatingCurrent
    }
}

/// Adjust Date and Time for one photo or many, as in Photos: the earliest
/// photo gets the new time and every other photo moves by the same amount, so
/// their order and spacing stay. A new time zone applies to all of them.
///
/// The camera's time stays in `captureDate`; the new time goes to
/// `userCorrectedCaptureDateUTC`, which imports never overwrite (nor the time
/// zone and day of a photo that has it).
@MainActor
enum DateTimeAdjustment {
    /// What one photo had before an adjustment, so Undo can put it back.
    struct ItemSnapshot: Equatable {
        let id: String
        let userCorrectedCaptureDateUTC: Date?
        let timeZoneIdentifier: String?
        let localDayKey: String?
        let timeConfidenceRaw: String?

        init(_ item: MediaItem) {
            id = item.id
            userCorrectedCaptureDateUTC = item.userCorrectedCaptureDateUTC
            timeZoneIdentifier = item.timeZoneIdentifier
            localDayKey = item.localDayKey
            timeConfidenceRaw = item.timeConfidenceRaw
        }
    }

    /// A trip's dates before an adjustment moved its photos.
    struct TripSnapshot: Equatable {
        let id: String
        let startDate: Date?
        let endDate: Date?
    }

    struct Snapshot: Equatable {
        var items: [ItemSnapshot] = []
        var trips: [TripSnapshot] = []
    }

    /// The photo the new time is set on: the earliest, as in Photos.
    static func reference(in items: [MediaItem]) -> MediaItem? {
        items.min { ($0.effectiveCaptureDate ?? .distantFuture, $0.id) < ($1.effectiveCaptureDate ?? .distantFuture, $1.id) }
    }

    /// The same clock time in another zone: 14:00 in Shanghai becomes 14:00 in
    /// Tokyo. Changing the zone in the sheet keeps what the clock reads.
    static func keepingClockTime(_ date: Date, from oldZone: TimeZone, to newZone: TimeZone) -> Date {
        var source = Calendar(identifier: .gregorian)
        source.timeZone = oldZone
        var target = Calendar(identifier: .gregorian)
        target.timeZone = newZone
        let parts = source.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return target.date(from: parts) ?? date
    }

    /// The `yyyy-MM-dd` day a moment falls on in `zone`.
    static func dayKey(for date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Sets the earliest photo to `referenceDate` and moves the others by the
    /// same amount; with `timeZone`, every photo is placed in that zone.
    /// Photos without any date get `referenceDate` itself. Returns what they
    /// had before. Trips the photos belong to take their new first and last days.
    @discardableResult
    static func apply(
        to items: [MediaItem],
        referenceDate: Date,
        timeZone: TimeZone?,
        now: Date = .now
    ) -> Snapshot {
        var snapshot = Snapshot()
        guard let reference = reference(in: items) else { return snapshot }
        snapshot.trips = tripSnapshots(for: items)
        let delta = reference.effectiveCaptureDate.map { referenceDate.timeIntervalSince($0) } ?? 0
        for item in items {
            snapshot.items.append(ItemSnapshot(item))
            let newDate = item.effectiveCaptureDate.map { $0.addingTimeInterval(delta) } ?? referenceDate
            let zoneChanged = timeZone.map { $0.identifier != item.timeZoneIdentifier } ?? false
            // A zone set by an earlier correction is the person's too; keeping
            // the correction keeps imports from putting the old zone back.
            let keepsEarlierZone = item.userCorrectedCaptureDateUTC != nil && item.timeZoneIdentifier != nil
            if let timeZone { item.timeZoneIdentifier = timeZone.identifier }
            // Back to the camera's own time, in its own zone: the correction goes.
            if !zoneChanged, !keepsEarlierZone, let original = item.captureDate, abs(original.timeIntervalSince(newDate)) < 1 {
                item.userCorrectedCaptureDateUTC = nil
                if item.timeConfidenceRaw == ImportTimeConfidence.userCorrected.rawValue { item.timeConfidenceRaw = nil }
            } else {
                item.userCorrectedCaptureDateUTC = newDate
                item.timeConfidenceRaw = ImportTimeConfidence.userCorrected.rawValue
            }
            item.localDayKey = dayKey(for: newDate, in: item.captureTimeZone)
            item.updatedAt = now
            item.updatedBy = MomentsAccount.localID
        }
        refreshTripDates(for: items, delta: delta, now: now)
        return snapshot
    }

    /// Goes back to the camera's time for every photo that was adjusted, in
    /// the zone the camera recorded when it did (otherwise the next Photos
    /// import looks the zone up again).
    @discardableResult
    static func revert(_ items: [MediaItem], now: Date = .now) -> Snapshot {
        var snapshot = Snapshot(trips: tripSnapshots(for: items))
        for item in items where item.userCorrectedCaptureDateUTC != nil {
            snapshot.items.append(ItemSnapshot(item))
            item.userCorrectedCaptureDateUTC = nil
            if let minutes = item.localTimeZoneOffsetMinutes, let zone = TimeZone(secondsFromGMT: minutes * 60) {
                item.timeZoneIdentifier = zone.identifier
            }
            if item.timeConfidenceRaw == ImportTimeConfidence.userCorrected.rawValue { item.timeConfidenceRaw = nil }
            if let date = item.captureDate { item.localDayKey = dayKey(for: date, in: item.captureTimeZone) }
            item.updatedAt = now
            item.updatedBy = MomentsAccount.localID
        }
        refreshTripDates(for: items, delta: nil, now: now)
        return snapshot
    }

    static func restore(_ snapshot: Snapshot, context: ModelContext, now: Date = .now) {
        let ids = snapshot.items.map(\.id)
        let items = ((try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { ids.contains($0.id) }))) ?? [])
        let itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for saved in snapshot.items {
            guard let item = itemsByID[saved.id] else { continue }
            item.userCorrectedCaptureDateUTC = saved.userCorrectedCaptureDateUTC
            item.timeZoneIdentifier = saved.timeZoneIdentifier
            item.localDayKey = saved.localDayKey
            item.timeConfidenceRaw = saved.timeConfidenceRaw
            item.updatedAt = now
            item.updatedBy = MomentsAccount.localID
        }
        let tripIDs = snapshot.trips.map(\.id)
        let trips = ((try? context.fetch(FetchDescriptor<Trip>(predicate: #Predicate { tripIDs.contains($0.id) }))) ?? [])
        for trip in trips {
            guard let saved = snapshot.trips.first(where: { $0.id == trip.id }) else { continue }
            trip.startDate = saved.startDate
            trip.endDate = saved.endDate
            trip.updatedAt = now
        }
    }

    private static func trips(of items: [MediaItem]) -> [Trip] {
        var seen = Set<String>()
        return items.compactMap(\.trip).filter { seen.insert($0.id).inserted }
    }

    private static func tripSnapshots(for items: [MediaItem]) -> [TripSnapshot] {
        trips(of: items).map { TripSnapshot(id: $0.id, startDate: $0.startDate, endDate: $0.endDate) }
    }

    /// Moving every photo of a trip moves the trip by the same amount, so a
    /// chapter's own start and end keep their shape. Moving only some of its
    /// photos widens the trip to take them in, and never shortens dates
    /// someone set.
    private static func refreshTripDates(for items: [MediaItem], delta: TimeInterval?, now: Date) {
        let movedIDs = Set(items.map(\.id))
        for trip in trips(of: items) {
            var start = trip.startDate
            var end = trip.endDate
            if let delta, trip.items.allSatisfy({ movedIDs.contains($0.id) }), start != nil || end != nil {
                start = start?.addingTimeInterval(delta)
                end = end?.addingTimeInterval(delta)
            }
            let dates = trip.items.compactMap(\.effectiveCaptureDate)
            if let first = dates.min() { start = min(start ?? first, first) }
            if let last = dates.max() { end = max(end ?? last, last) }
            guard trip.startDate != start || trip.endDate != end else { continue }
            trip.startDate = start
            trip.endDate = end
            trip.updatedAt = now
        }
    }
}

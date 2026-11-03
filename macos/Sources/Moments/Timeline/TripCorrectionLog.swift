import Foundation
import MomentsCore
import os
import SwiftData

/// A local, detailed log of every hand correction to trips and chapters: one
/// JSON line per change, kept at `Application Support/Moments/trip-corrections.jsonl`.
///
/// The log is for the two people who use the app, on their Mac only. Nothing
/// here opens a connection: there is no upload and no telemetry.
///
/// Writes go through the `TripCorrectionLog` actor, off the main thread. A
/// failed write is logged and the edit goes on: a correction is never lost
/// because the log could not be written.
actor TripCorrectionLog {
    static let shared = TripCorrectionLog()

    /// Where the log lives; tests pass a temporary file.
    nonisolated let fileURL: URL

    private static let logger = Logger(subsystem: "org.example.Moments", category: "TripCorrectionLog")

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    /// The folder is made when the first entry is written, so asking for the
    /// path never touches the disk.
    nonisolated static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory
            .appending(path: "Moments", directoryHint: .isDirectory)
            .appending(path: "trip-corrections.jsonl")
    }

    // MARK: Settings

    /// The name typed under Settings > General > Correction log; empty until
    /// someone fills it in.
    nonisolated static let editorKey = "moments.trip-corrections.editor"

    nonisolated static func editorName(defaults: UserDefaults = .standard) -> String {
        (defaults.string(forKey: editorKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    // MARK: Writing

    /// Appends one line. Never throws: a failure is logged, not shown.
    func append(_ entry: Entry) {
        do {
            var data: Data = try JSONEncoder().encode(entry)
            data.append(0x0A)
            let folder: URL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle: FileHandle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            Self.logger.error("Could not write a trip correction: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The number of entries in the log, shown in Settings.
    func count() -> Int {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
        return text.split(whereSeparator: \.isNewline).filter { (line: Substring) -> Bool in
            !line.trimmingCharacters(in: .whitespaces).isEmpty
        }.count
    }

    /// Empties the log; the file stays and starts again at zero lines.
    func clear() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Could not clear the trip correction log: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copies the log to `destination`, as the export panel asks.
    func export(to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try Data().write(to: destination, options: .atomic)
            return
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: fileURL, to: destination)
    }
}

// MARK: - Entry

extension TripCorrectionLog {
    /// One hand correction, as one line of the log.
    struct Entry: Codable, Sendable, Equatable {
        /// One action a person can take on a trip or chapter.
        enum Action: String, Codable, Sendable, CaseIterable {
            case delete
            case toActivity
            case toTrip
            case split
            case merge
            case changeDates
            case addDay
            case removeDay
            case addPhotos
            case removePhotos
            case rename
            case confirm
            case create
            case undo
        }

        var version: Int
        var id: UUID
        /// ISO 8601 with the Mac's time zone.
        var at: String
        /// Who typed it in Settings; empty when nobody did.
        var editor: String
        var appVersion: String
        var rulesVersion: Int
        var action: Action
        /// The trips or chapters involved, as they were before the change.
        var before: [TripCorrectionSnapshot]
        /// The same, as they are after it.
        var after: [TripCorrectionSnapshot]
        var movedPhotoIDs: [String]
        var note: String?
        /// For `undo`: the entry it reverses.
        var reverses: UUID?

        init(
            version: Int = 1,
            id: UUID = UUID(),
            at: String,
            editor: String,
            appVersion: String,
            rulesVersion: Int,
            action: Action,
            before: [TripCorrectionSnapshot] = [],
            after: [TripCorrectionSnapshot] = [],
            movedPhotoIDs: [String] = [],
            note: String? = nil,
            reverses: UUID? = nil
        ) {
            self.version = version
            self.id = id
            self.at = at
            self.editor = editor
            self.appVersion = appVersion
            self.rulesVersion = rulesVersion
            self.action = action
            self.before = before
            self.after = after
            self.movedPhotoIDs = movedPhotoIDs
            self.note = note
            self.reverses = reverses
        }
    }
}

// MARK: - Snapshot

/// One trip or chapter as it stood at the moment of the change.
struct TripCorrectionSnapshot: Codable, Sendable, Equatable {
    struct Day: Codable, Sendable, Equatable {
        /// `yyyy-MM-dd`.
        let date: String
        /// English weekday name, so one entry reads the same on every Mac.
        let weekday: String
        let photos: Int
        let located: Int
        let screenshots: Int
        let city: String?
        let distanceFromHomeKm: Double?
    }

    let id: String
    /// `trip` or `chapter`.
    let kind: String
    /// For a chapter: event, celebration, period or `custom:<label>`.
    let chapterType: String?
    let name: String
    let overrideName: String?
    let status: String?
    let confirmed: Bool
    /// `yyyy-MM-dd`; nil when the trip or chapter has no dates.
    let start: String?
    let end: String?
    let dayCount: Int
    let photoCount: Int
    let videoCount: Int
    /// In visit order.
    let cities: [String]
    /// In visit order.
    let countries: [String]
    let centreLatitude: Double?
    let centreLongitude: Double?
    let homeLatitude: Double?
    let homeLongitude: Double?
    let distanceFromHomeKmMedian: Double?
    let distanceFromHomeKmMax: Double?
    let photoDayShare: Double
    let medianPhotosPerPhotoDay: Double
    let screenshotShare: Double
    let noLocationShare: Double
    let weekdayPhotoDayShare: Double
    let weekendPhotoDayShare: Double
    let days: [Day]
}

// MARK: - Building snapshots from the store

/// Builds snapshots from the store as it stands at that moment. One builder
/// lives for one logged change, so the photos outside any trip (needed for
/// `home`) are fetched once even when the change touches several trips.
@MainActor
final class TripCorrectionSnapshotBuilder {
    private let context: ModelContext
    private let calendar: Calendar
    private var outsideTrips: [MediaItem]?

    init(context: ModelContext, calendar: Calendar = .current) {
        self.context = context
        self.calendar = calendar
    }

    /// A trip, or nil when it is no longer in the store (deleted, merged away).
    func trip(_ trip: Trip) -> TripCorrectionSnapshot {
        let items: [MediaItem] = trip.items.filter { (item: MediaItem) -> Bool in item.deletedAt == nil }
        return make(
            id: trip.id,
            kind: "trip",
            chapterType: nil,
            name: trip.effectiveName,
            overrideName: trip.overrideName,
            status: trip.suggestionStatusRaw,
            confirmed: trip.confirmedAt != nil,
            start: trip.startDate,
            end: trip.endDate,
            items: items
        )
    }

    /// A chapter: an event, a celebration, a period or a custom chapter.
    func chapter(_ group: UserGroup) -> TripCorrectionSnapshot {
        let rows: [UserGroupItem] = TripEdits.memberships(of: group, context: context)
        let inside: Set<String> = Set(rows.filter { (row: UserGroupItem) -> Bool in !row.excluded }.map(\.mediaID))
        let all: [MediaItem] = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        let items: [MediaItem] = all.filter { (item: MediaItem) -> Bool in
            inside.contains(item.id) && item.deletedAt == nil
        }
        let info: ChapterInfo = group.chapterInfo
        return make(
            id: group.id,
            kind: "chapter",
            chapterType: group.chapterType.raw,
            name: group.name,
            overrideName: nil,
            status: nil,
            confirmed: false,
            start: info.startDate,
            end: info.endDate,
            items: items
        )
    }

    /// A trip by id, wherever it stands right now; nil when it is gone.
    func snapshot(tripID: String) -> TripCorrectionSnapshot? {
        let trips: [Trip] = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        guard let trip = trips.first(where: { (trip: Trip) -> Bool in trip.id == tripID }) else { return nil }
        return self.trip(trip)
    }

    /// A chapter by id, wherever it stands right now; nil when it is gone.
    func snapshot(chapterID: String) -> TripCorrectionSnapshot? {
        let groups: [UserGroup] = (try? context.fetch(FetchDescriptor<UserGroup>())) ?? []
        guard let group = groups.first(where: { (group: UserGroup) -> Bool in group.id == chapterID }) else { return nil }
        return chapter(group)
    }

    // MARK: Building

    private func make(
        id: String,
        kind: String,
        chapterType: String?,
        name: String,
        overrideName: String?,
        status: String?,
        confirmed: Bool,
        start: Date?,
        end: Date?,
        items: [MediaItem]
    ) -> TripCorrectionSnapshot {
        let sorted: [MediaItem] = items.sorted { (first: MediaItem, second: MediaItem) -> Bool in
            let firstDate: Date = first.effectiveCaptureDate ?? .distantPast
            let secondDate: Date = second.effectiveCaptureDate ?? .distantPast
            return (firstDate, first.id) < (secondDate, second.id)
        }
        let nameCities: [(name: String, coordinate: GeoPoint?)] = TripNameBackfill.orderedCities(of: sorted)
        let startDay: Date? = start.map { (date: Date) -> Date in self.calendar.startOfDay(for: date) }
            ?? sorted.compactMap(\.effectiveCaptureDate).min().map { (date: Date) -> Date in self.calendar.startOfDay(for: date) }
        let endDay: Date? = end.map { (date: Date) -> Date in self.calendar.startOfDay(for: date) }
            ?? sorted.compactMap(\.effectiveCaptureDate).max().map { (date: Date) -> Date in self.calendar.startOfDay(for: date) }
        let homeCity: (Double, Double)? = self.home(start: startDay, end: endDay)

        let photoCount: Int = sorted.count
        let videoCount: Int = sorted.filter { (item: MediaItem) -> Bool in item.kind == .video }.count
        let screenshotCount: Int = sorted.filter { (item: MediaItem) -> Bool in item.isScreenshot }.count
        let locatedItems: [MediaItem] = sorted.filter { (item: MediaItem) -> Bool in item.effectiveCoordinate != nil }

        let byDay: [String: [MediaItem]] = Dictionary(grouping: sorted) { (item: MediaItem) -> String in
            item.effectiveCaptureDate.map { (date: Date) -> String in
                PhotoNoteDay.key(for: date, calendar: self.calendar)
            } ?? ""
        }
        let photoDays: [String] = byDay.keys.filter { (key: String) -> Bool in !key.isEmpty }.sorted()

        let allDistances: [Double] = self.distances(of: locatedItems, home: homeCity)
        let rows: [TripCorrectionSnapshot.Day] = self.dayRows(
            from: startDay,
            to: endDay,
            byDay: byDay,
            home: homeCity
        )

        let weekdayDays: Int = photoDays.filter { (key: String) -> Bool in
            guard let date = TripEdits.dayStart(key, calendar: self.calendar) else { return false }
            let weekday: Int = self.calendar.component(.weekday, from: date)
            return weekday != 1 && weekday != 7
        }.count
        let weekendDays: Int = photoDays.count - weekdayDays
        let counts: [Double] = photoDays.map { (key: String) -> Double in
            Double(byDay[key]?.count ?? 0)
        }

        let latitudes: [Double] = locatedItems.compactMap { (item: MediaItem) -> Double? in
            item.effectiveCoordinate?.latitude
        }
        let longitudes: [Double] = locatedItems.compactMap { (item: MediaItem) -> Double? in
            item.effectiveCoordinate?.longitude
        }
        let centreLatitude: Double? = latitudes.isEmpty ? nil : latitudes.reduce(0, +) / Double(latitudes.count)
        let centreLongitude: Double? = longitudes.isEmpty ? nil : longitudes.reduce(0, +) / Double(longitudes.count)
        let cities: [String] = nameCities.map(\.name)
        let countries: [String] = self.countries(of: nameCities)

        return TripCorrectionSnapshot(
            id: id,
            kind: kind,
            chapterType: chapterType,
            name: name,
            overrideName: overrideName,
            status: status,
            confirmed: confirmed,
            start: startDay.map { (date: Date) -> String in Self.dayKey(date, calendar: self.calendar) },
            end: endDay.map { (date: Date) -> String in Self.dayKey(date, calendar: self.calendar) },
            dayCount: rows.count,
            photoCount: photoCount,
            videoCount: videoCount,
            cities: cities,
            countries: countries,
            centreLatitude: Self.rounded(centreLatitude),
            centreLongitude: Self.rounded(centreLongitude),
            homeLatitude: homeCity.map { (coordinate: (Double, Double)) -> Double in Self.rounded(coordinate.0) ?? 0 },
            homeLongitude: homeCity.map { (coordinate: (Double, Double)) -> Double in Self.rounded(coordinate.1) ?? 0 },
            distanceFromHomeKmMedian: Self.rounded(Self.median(allDistances)),
            distanceFromHomeKmMax: Self.rounded(allDistances.max()),
            photoDayShare: Self.share(photoDays.count, of: rows.count),
            medianPhotosPerPhotoDay: Self.median(counts) ?? 0,
            screenshotShare: Self.share(screenshotCount, of: photoCount),
            noLocationShare: Self.share(photoCount - locatedItems.count, of: photoCount),
            weekdayPhotoDayShare: Self.share(weekdayDays, of: photoDays.count),
            weekendPhotoDayShare: Self.share(weekendDays, of: photoDays.count),
            days: rows
        )
    }

    /// One row per day from `start` to `end`, both included; none without dates.
    private func dayRows(
        from start: Date?,
        to end: Date?,
        byDay: [String: [MediaItem]],
        home: (Double, Double)?
    ) -> [TripCorrectionSnapshot.Day] {
        guard let start, let end else { return [] }
        var rows: [TripCorrectionSnapshot.Day] = []
        var cursor: Date = start
        while cursor <= end, rows.count < 3_660 {
            let key: String = Self.dayKey(cursor, calendar: calendar)
            let items: [MediaItem] = byDay[key] ?? []
            let weekday: Int = calendar.component(.weekday, from: cursor)
            let located: Int = items.filter { (item: MediaItem) -> Bool in item.effectiveCoordinate != nil }.count
            let screenshots: Int = items.filter { (item: MediaItem) -> Bool in item.isScreenshot }.count
            rows.append(
                TripCorrectionSnapshot.Day(
                    date: key,
                    weekday: Self.weekdayName(weekday),
                    photos: items.count,
                    located: located,
                    screenshots: screenshots,
                    city: Self.cityName(of: items),
                    distanceFromHomeKm: Self.rounded(Self.median(distances(of: items, home: home)))
                )
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return rows
    }

    /// The busiest city centre among photos in no trip in the ±180 days around
    /// the trip, rounded to 2 decimals; nil when there are none.
    private func home(start: Date?, end: Date?) -> (Double, Double)? {
        guard let start, let end else { return nil }
        let from: Date = calendar.date(byAdding: .day, value: -180, to: start) ?? start
        let to: Date = calendar.date(byAdding: .day, value: 180, to: end) ?? end
        let candidates: [MediaItem] = self.itemsOutsideTrips().filter { (item: MediaItem) -> Bool in
            guard let date = item.effectiveCaptureDate else { return false }
            return date >= from && date <= to
        }
        var counts: [String: Int] = [:]
        var centres: [String: (Double, Double)] = [:]
        var order: [String] = []
        for item in candidates {
            guard let coordinate: (Double, Double) = Self.cityCentre(of: item) else { continue }
            let key: String = Self.coordinateKey(coordinate)
            if counts[key] == nil {
                centres[key] = coordinate
                order.append(key)
            }
            counts[key, default: 0] += 1
        }
        var best: String?
        for key in order {
            let count: Int = counts[key] ?? 0
            let bestCount: Int = best.flatMap { counts[$0] } ?? -1
            if count > bestCount { best = key }
        }
        return best.flatMap { centres[$0] }
    }

    /// Photos in no trip. A photo pointing at a trip that no longer exists
    /// counts as in no trip, as it shows on the Trips page.
    private func itemsOutsideTrips() -> [MediaItem] {
        if let outsideTrips { return outsideTrips }
        let all: [MediaItem] = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        let trips: [Trip] = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        let known: Set<String> = Set(trips.map(\.id))
        let outside: [MediaItem] = all.filter { (item: MediaItem) -> Bool in
            guard item.deletedAt == nil else { return false }
            guard let tripID: String = item.trip?.id ?? item.tripID else { return true }
            return !known.contains(tripID)
        }
        outsideTrips = outside
        return outside
    }

    private func distances(of items: [MediaItem], home: (Double, Double)?) -> [Double] {
        guard let home else { return [] }
        return items.compactMap { (item: MediaItem) -> Double? in
            guard let coordinate: (Double, Double) = item.effectiveCoordinate else { return nil }
            return Self.kilometres(from: home, to: coordinate)
        }
    }

    /// Countries in visit order, from the geocoding cache the import filled;
    /// the log never looks anything up itself.
    private func countries(of cities: [(name: String, coordinate: GeoPoint?)]) -> [String] {
        var result: [String] = []
        for city in cities {
            guard let coordinate = city.coordinate else { continue }
            guard let name = TripCorrectionRecorder.countryName(at: coordinate) else { continue }
            if !result.contains(name) { result.append(name) }
        }
        return result
    }

    // MARK: Values

    /// The city a photo's place sits in, walking up to four steps.
    static func cityCentre(of item: MediaItem) -> (Double, Double)? {
        var current: Place? = item.place
        var depth = 0
        while let place = current, place.kind != .city, depth < 4 {
            current = place.parent
            depth += 1
        }
        guard let city = current, city.kind == .city,
              let latitude = city.latitude, let longitude = city.longitude else { return nil }
        return (latitude, longitude)
    }

    /// The first named city among the photos on a day, in time order.
    static func cityName(of items: [MediaItem]) -> String? {
        let sorted: [MediaItem] = items.sorted { (first: MediaItem, second: MediaItem) -> Bool in
            let firstDate: Date = first.effectiveCaptureDate ?? .distantPast
            let secondDate: Date = second.effectiveCaptureDate ?? .distantPast
            return (firstDate, first.id) < (secondDate, second.id)
        }
        return TripNameBackfill.orderedCities(of: sorted).first?.name
    }

    static func coordinateKey(_ coordinate: (Double, Double)) -> String {
        String(format: "%.2f,%.2f", locale: Locale(identifier: "en_US_POSIX"), coordinate.0, coordinate.1)
    }

    /// Great-circle kilometres between two coordinates.
    static func kilometres(from start: (Double, Double), to end: (Double, Double)) -> Double {
        let first = GeoPoint(latitude: start.0, longitude: start.1)
        let second = GeoPoint(latitude: end.0, longitude: end.1)
        return first.distance(to: second) / 1_000
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted: [Double] = values.sorted()
        let middle: Int = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// A fraction rounded to three places, so one entry reads cleanly.
    static func share(_ count: Int, of total: Int) -> Double {
        guard total > 0 else { return 0 }
        return ((Double(count) / Double(total)) * 1_000).rounded() / 1_000
    }

    static func rounded(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return (value * 100).rounded() / 100
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        PhotoNoteDay.key(for: date, calendar: calendar)
    }

    /// English weekday name, so one entry reads the same in every language.
    static func weekdayName(_ weekday: Int) -> String {
        let names: [String] = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let index: Int = weekday - 1
        return names.indices.contains(index) ? names[index] : ""
    }
}

// MARK: - Writing entries

/// Makes one entry and hands it to the log. The edit itself never waits.
@MainActor
enum TripCorrectionRecorder {
    private static var inFlight: [Task<Void, Never>] = []

    /// The log in use; tests swap in one over a temporary file.
    static var log: TripCorrectionLog = .shared
    /// Where the editor name is read from; tests swap in their own suite.
    static var defaults: UserDefaults = .standard
    /// Countries come from the cache the import filled, read only, never a
    /// lookup. Tests swap in a stub so they touch no real folder.
    static var countryLookup: (GeoPoint) -> String? = { coordinate in
        FootprintsGeocodeCache().result(for: coordinate)?.countryName
    }

    static func countryName(at coordinate: GeoPoint) -> String? {
        countryLookup(coordinate)
    }

    static func append(_ entry: TripCorrectionLog.Entry) {
        let log = self.log
        let task = Task { await log.append(entry) }
        inFlight.append(task)
        if inFlight.count > 64 { inFlight.removeFirst(inFlight.count - 64) }
    }

    /// Waits for the writes started so far; tests call it so the file is whole.
    static func flush() async {
        let tasks: [Task<Void, Never>] = inFlight
        inFlight = []
        for task in tasks { await task.value }
    }

    /// An entry for one change. `before` and `after` are built by the caller
    /// from the store, before and after the save.
    static func entry(
        _ action: TripCorrectionLog.Entry.Action,
        before: [TripCorrectionSnapshot],
        after: [TripCorrectionSnapshot],
        movedPhotoIDs: [String] = [],
        note: String? = nil,
        reverses: UUID? = nil,
        now: Date = .now
    ) -> TripCorrectionLog.Entry {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // The Mac's own offset, so a line can be read against the photos' days.
        formatter.timeZone = .current
        return TripCorrectionLog.Entry(
            at: formatter.string(from: now),
            editor: TripCorrectionLog.editorName(defaults: defaults),
            appVersion: TripCorrectionLog.appVersion,
            rulesVersion: TripSegmenter.rulesVersion,
            action: action,
            before: before,
            after: after,
            movedPhotoIDs: movedPhotoIDs,
            note: note,
            reverses: reverses
        )
    }
}

extension TripCorrectionRecorder {
    /// Records one change and returns the entry's id, so an undo can point
    /// back at it. `before` and `after` come from the store.
    @discardableResult
    static func record(
        _ action: TripCorrectionLog.Entry.Action,
        before: [TripCorrectionSnapshot],
        after: [TripCorrectionSnapshot],
        movedPhotoIDs: [String] = [],
        note: String? = nil,
        reverses: UUID? = nil
    ) -> UUID {
        let built: TripCorrectionLog.Entry = Self.entry(
            action,
            before: before,
            after: after,
            movedPhotoIDs: movedPhotoIDs,
            note: note,
            reverses: reverses
        )
        append(built)
        return built.id
    }
}

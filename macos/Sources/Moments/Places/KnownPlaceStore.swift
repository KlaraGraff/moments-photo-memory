import Foundation
import MomentsCore
import SwiftData

/// What the person told the trip finder about their places
/// (`KnownPlaceBook`): their home, home town and work sites, the places a
/// visit to is no trip, the candidates they turned down and how long a stay
/// makes daily life. Kept with the library's decisions, so it travels with
/// backups and never leaves the Mac.
enum KnownPlaceStore {
    static let key = "moments.places.known"

    static func book(defaults: any DecisionStore = TripAssignmentLocks.store) -> KnownPlaceBook {
        KnownPlaceBook.decode(defaults.string(forKey: key))
    }

    static func save(_ book: KnownPlaceBook, defaults: any DecisionStore = TripAssignmentLocks.store) {
        defaults.set(book.encoded(), forKey: key)
    }

    /// Changes the book and, when what the trip finder reads changed,
    /// groups the trips nobody touched again. Returns the book as it was.
    @MainActor
    @discardableResult
    static func change(
        context: ModelContext?,
        defaults: any DecisionStore = TripAssignmentLocks.store,
        _ edit: (inout KnownPlaceBook) -> Void
    ) -> KnownPlaceBook {
        let before = book(defaults: defaults)
        var after = before
        edit(&after)
        guard after != before else { return before }
        save(after, defaults: defaults)
        if let context, findsTripsDifferently(before, after) {
            regroup(context: context, defaults: defaults)
        }
        return before
    }

    /// Whether the trip finder would read the two books differently.
    static func findsTripsDifferently(_ first: KnownPlaceBook, _ second: KnownPlaceBook) -> Bool {
        first.coordinates != second.coordinates || first.effectiveLivedThereDays != second.effectiveLivedThereDays
    }

    /// Trips the import suggested and nobody touched are found again with
    /// the book; trips someone changed keep their photos (see
    /// `TripRegrouping`). Daily life that left a trip can become an event.
    @MainActor
    static func regroup(context: ModelContext, defaults: any DecisionStore = TripAssignmentLocks.store) {
        let covered = Set(TripCoverChoice.decode(defaults.string(forKey: TripCoverChoice.defaultsKey) ?? "").keys)
        var configuration = ImportConfiguration()
        configuration.knownPlaces = book(defaults: defaults)
        _ = try? TripRegrouping.regroup(
            context: context,
            locked: TripAssignmentLocks.lockedIDs(defaults: defaults),
            covered: covered,
            configuration: configuration
        )
        EventSuggestions.suggest(in: context, defaults: defaults)
    }

    // MARK: Places found in the photos

    /// The places the photos call home, named after their most common city,
    /// most photographed first. The search runs off the main thread.
    @MainActor
    static func findPlaces(items: [MediaItem], book: KnownPlaceBook) async -> [FoundPlace] {
        let stops = ImportOrganizer.libraryStops(items)
        guard !stops.isEmpty else { return [] }
        var segmenter = TripSegmenter()
        book.apply(to: &segmenter)
        let finder = segmenter
        let candidates = await Task.detached(priority: .utility) { finder.homeCandidates(stops) }.value
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return candidates.map { candidate in
            FoundPlace(candidate: candidate, name: cityName(of: candidate.photoIDs.compactMap { byID[$0] }))
        }
    }

    /// The city most of these photos were taken in.
    @MainActor
    static func cityName(of items: [MediaItem]) -> String {
        var counts: [String: Int] = [:]
        // A sample is enough to tell the most common city.
        let step = max(1, items.count / 400)
        for item in stride(from: 0, to: items.count, by: step).map({ items[$0] }) {
            guard let name = cityName(of: item) else { continue }
            counts[name, default: 0] += 1
        }
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
            ?? String(localized: "A place without a name")
    }

    /// The city a photo was taken in, or its nearest named place.
    @MainActor
    static func cityName(of item: MediaItem) -> String? {
        var current = item.place
        var depth = 0
        var nearest: String?
        while let place = current, depth < 5 {
            let name = PlaceDisplayName.resolvedName(of: place)
            if nearest == nil { nearest = name }
            if place.kind == .city, let name { return name }
            current = place.parent
            depth += 1
        }
        return nearest
    }

    // MARK: "This is not a trip"

    /// Where a trip's photos were taken, for remembering the place: the
    /// middle of its located photos and the city most of them are in.
    @MainActor
    static func placeOfTrip(_ items: [MediaItem]) -> (name: String, centre: GeoPoint)? {
        let located = items.compactMap { item -> GeoPoint? in
            guard let latitude = item.latitude, let longitude = item.longitude,
                  latitude != 0 || longitude != 0 else { return nil }
            return GeoPoint(latitude: latitude, longitude: longitude)
        }
        guard !located.isEmpty else { return nil }
        // The photo with the most others within a short drive: a day trip
        // out of town does not pull the centre away.
        let sample = stride(from: 0, to: located.count, by: max(1, located.count / 200)).map { located[$0] }
        let centre = sample.max { first, second in
            sample.filter { $0.distance(to: first) < 10_000 }.count < sample.filter { $0.distance(to: second) < 10_000 }.count
        } ?? located[0]
        return (cityName(of: items), centre)
    }
}

/// A place found in the photos, ready to show.
struct FoundPlace: Identifiable, Equatable {
    let candidate: HomeCandidate
    let name: String

    var id: String { "\(candidate.centre.latitude),\(candidate.centre.longitude)" }

    /// "2025.03 – now" or "2023.06 – 2025.02".
    func dateSpan(locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("yyyyMM")
        let first = formatter.string(from: candidate.firstDate)
        if candidate.isCurrent { return String(localized: "\(first) – now") }
        return "\(first) – \(formatter.string(from: candidate.lastDate))"
    }

    /// What the photos show about the place, in plain words.
    var detail: String {
        let days = String(localized: "Photos on \(candidate.photoDays) days")
        guard candidate.visits > 1 else { return days }
        return "\(days) · \(String(localized: "\(candidate.visits) separate stays"))"
    }
}

extension PlaceRole {
    var label: String {
        switch self {
        case .home: String(localized: "Home")
        case .homeTown: String(localized: "Home town")
        case .work: String(localized: "Work site")
        case .formerWork: String(localized: "Former work site")
        case .notTrip: String(localized: "Not a trip")
        }
    }

    /// The line under a place in Settings.
    var meaning: String {
        switch self {
        case .home: String(localized: "Time here is daily life")
        case .homeTown: String(localized: "Going back here, and the way there, is no trip")
        case .work: String(localized: "Time here is daily life, nights too")
        case .formerWork: String(localized: "Going back to visit is no trip")
        case .notTrip: String(localized: "A visit here is no trip")
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .homeTown: "house.and.flag"
        case .work: "building.2"
        case .formerWork: "building.2.crop.circle"
        case .notTrip: "mappin.slash"
        }
    }
}

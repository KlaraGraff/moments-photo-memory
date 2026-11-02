import Foundation
@testable import MomentsCore

/// A synthetic library with the truth for the "frequent place" rule: a place
/// away from home visited three or more separate times within twelve months
/// becomes one group, and each visit stays a trip-like segment inside it.
struct SyntheticPlaceScenario {
    let scenario: SyntheticScenario
    /// Truth frequent places: each inner array lists the trip names that form
    /// one frequent place, in date order; empty when the library has none.
    let frequentGroups: [[String]]

    /// Photo ids per frequent group, in date order (the scenario's date order).
    func truthFrequentPhotoGroups() -> [[String]] {
        frequentGroups.map { (names: [String]) -> [String] in
            scenario.photos
                .filter { (photo: SyntheticPhoto) -> Bool in
                    guard let trip = photo.truthTrip else { return false }
                    return names.contains(trip)
                }
                .map { (photo: SyntheticPhoto) -> String in photo.id }
        }
    }
}

/// Built in the same style as `SyntheticLibrary.hardScenarios(seed:)`. Besides
/// the labelled frequent places, the catalog holds today's bug: on a long trip
/// far from home the stay at the destination becomes a usual place, so the end
/// of the trip falls into daily life. The first version of `far-long-trip`
/// (stay to day 173, photo days at 0.5) did not show the bug, so the stay is
/// 45 days (140 to 184) and daily life has a photo day with probability 0.4.
extension SyntheticLibrary {
    static func placeScenarios(seed: UInt64 = 1) -> [SyntheticPlaceScenario] {
        [
            farLongTrip(seed: seed &+ 200 &+ 1),
            secondPlaceVisits(seed: seed &+ 200 &+ 2),
            twoVisitsOnly(seed: seed &+ 200 &+ 3),
            // The hard catalogue's seed, so the photos are the same as `monthly-weekends`.
            monthlyDresden(seed: seed &+ 100 &+ 7),
            passThrough(seed: seed &+ 200 &+ 5),
            frequentFarPlace(seed: seed &+ 200 &+ 6),
        ]
    }

    // MARK: - Scenarios

    private static func farLongTrip(seed: UInt64) -> SyntheticPlaceScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [PlaceDraft] = []
        let tripDays = 120..<185
        for day in 0..<365 where !tripDays.contains(day) {
            drafts += placeDailyPhotos(&rng, at: PlacePlaces.berlin, day: day, photoDayProbability: 0.4)
        }
        // Six cities, three to four days each, all 8,000 to 11,000 km away.
        let legs: [(days: Range<Int>, place: GeoPoint)] = [
            (120..<123, PlacePlaces.tokyo),
            (123..<126, PlacePlaces.kyoto),
            (126..<129, PlacePlaces.osaka),
            (129..<132, PlacePlaces.hiroshima),
            (132..<136, PlacePlaces.fukuoka),
            (136..<140, PlacePlaces.sapporo),
        ]
        for leg in legs {
            for day in leg.days {
                drafts += placeTripPhotos(&rng, at: leg.place, day: day, trip: "far")
            }
        }
        // Then a long stay in Tokyo with a photo every day, still the same trip.
        for day in 140..<185 {
            drafts += placeTripPhotos(&rng, at: PlacePlaces.tokyo, day: day, trip: "far")
        }
        return SyntheticPlaceScenario(
            scenario: placeScenario(name: "far-long-trip", drafts: drafts),
            frequentGroups: []
        )
    }

    private static func secondPlaceVisits(seed: UInt64) -> SyntheticPlaceScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [PlaceDraft] = []
        let visits: [(days: Range<Int>, name: String)] = [
            (28..<35, "v1"),
            (108..<121, "v2"),
            (200..<203, "v3"),
            (304..<305, "v4"),
        ]
        let lisbonDays = 150..<154
        var visitByDay: [Int: String] = [:]
        for visit in visits {
            for day in visit.days { visitByDay[day] = visit.name }
        }
        for day in 0..<365 {
            if let visit = visitByDay[day] {
                drafts += placeTripPhotos(&rng, at: PlacePlaces.dresden, day: day, trip: visit)
            } else if lisbonDays.contains(day) {
                drafts += placeTripPhotos(&rng, at: PlacePlaces.lisbon, day: day, trip: "lisbon")
            } else {
                drafts += placeDailyPhotos(&rng, at: PlacePlaces.berlin, day: day)
            }
        }
        return SyntheticPlaceScenario(
            scenario: placeScenario(name: "second-place-visits", drafts: drafts),
            frequentGroups: [["v1", "v2", "v3", "v4"]]
        )
    }

    private static func twoVisitsOnly(seed: UInt64) -> SyntheticPlaceScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [PlaceDraft] = []
        let visits: [(days: Range<Int>, name: String)] = [
            (28..<35, "v1"),
            (200..<203, "v2"),
        ]
        // The Lisbon trip from the scenario above stays; only the two later
        // Dresden visits are gone, so the place has just two separate visits.
        let lisbonDays = 150..<154
        var visitByDay: [Int: String] = [:]
        for visit in visits {
            for day in visit.days { visitByDay[day] = visit.name }
        }
        for day in 0..<365 {
            if let visit = visitByDay[day] {
                drafts += placeTripPhotos(&rng, at: PlacePlaces.dresden, day: day, trip: visit)
            } else if lisbonDays.contains(day) {
                drafts += placeTripPhotos(&rng, at: PlacePlaces.lisbon, day: day, trip: "lisbon")
            } else {
                drafts += placeDailyPhotos(&rng, at: PlacePlaces.berlin, day: day)
            }
        }
        return SyntheticPlaceScenario(
            scenario: placeScenario(name: "two-visits-only", drafts: drafts),
            frequentGroups: []
        )
    }

    private static func monthlyDresden(seed: UInt64) -> SyntheticPlaceScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [PlaceDraft] = []
        var tripByDay: [Int: String] = [:]
        var names: [String] = []
        for index in 0...12 {
            let name = String(format: "dresden-%02d", index + 1)
            names.append(name)
            tripByDay[28 * index + 20] = name
            tripByDay[28 * index + 21] = name
        }
        for day in 0..<365 {
            if let trip = tripByDay[day] {
                drafts += placeTripPhotos(&rng, at: PlacePlaces.dresden, day: day, trip: trip)
            } else {
                drafts += placeDailyPhotos(&rng, at: PlacePlaces.berlin, day: day)
            }
        }
        return SyntheticPlaceScenario(
            scenario: placeScenario(name: "monthly-dresden", drafts: drafts),
            frequentGroups: [names]
        )
    }

    private static func passThrough(seed: UInt64) -> SyntheticPlaceScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [PlaceDraft] = []
        let visits: [(days: Range<Int>, name: String)] = [
            (40..<43, "v1"),
            (130..<134, "v2"),
            (250..<253, "v3"),
        ]
        // One night in Dresden, then Prague, Vienna and Budapest, still one road trip.
        let roadTrip: [(days: Range<Int>, place: GeoPoint)] = [
            (180..<181, PlacePlaces.dresden),
            (181..<183, PlacePlaces.prague),
            (183..<185, PlacePlaces.vienna),
            (185..<187, PlacePlaces.budapest),
        ]
        var visitByDay: [Int: String] = [:]
        for visit in visits {
            for day in visit.days { visitByDay[day] = visit.name }
        }
        var roadByDay: [Int: GeoPoint] = [:]
        for stop in roadTrip {
            for day in stop.days { roadByDay[day] = stop.place }
        }
        for day in 0..<365 {
            if let visit = visitByDay[day] {
                drafts += placeTripPhotos(&rng, at: PlacePlaces.dresden, day: day, trip: visit)
            } else if let place = roadByDay[day] {
                drafts += placeTripPhotos(&rng, at: place, day: day, trip: "road")
            } else {
                drafts += placeDailyPhotos(&rng, at: PlacePlaces.berlin, day: day)
            }
        }
        return SyntheticPlaceScenario(
            scenario: placeScenario(name: "pass-through", drafts: drafts),
            frequentGroups: [["v1", "v2", "v3"]]
        )
    }

    private static func frequentFarPlace(seed: UInt64) -> SyntheticPlaceScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [PlaceDraft] = []
        let visits: [(days: Range<Int>, name: String)] = [
            (60..<67, "ny1"),
            (170..<177, "ny2"),
            (290..<297, "ny3"),
        ]
        var visitByDay: [Int: String] = [:]
        for visit in visits {
            for day in visit.days { visitByDay[day] = visit.name }
        }
        for day in 0..<365 {
            if let visit = visitByDay[day] {
                drafts += placeTripPhotos(&rng, at: PlacePlaces.newYork, day: day, trip: visit)
            } else {
                drafts += placeDailyPhotos(&rng, at: PlacePlaces.berlin, day: day)
            }
        }
        return SyntheticPlaceScenario(
            scenario: placeScenario(name: "frequent-far-place", drafts: drafts),
            frequentGroups: [["ny1", "ny2", "ny3"]]
        )
    }

    // MARK: - Photos

    /// One photo before the scenario sorts it and gives it an id.
    private struct PlaceDraft {
        let date: Date
        let coordinate: GeoPoint?
        let perceptualHash: UInt64
        let truthTrip: String?
        let truthStack: String?
    }

    private static func placeDailyPhotos(
        _ rng: inout SeededRandom,
        at place: GeoPoint,
        day: Int,
        photoDayProbability: Double = 0.7
    ) -> [PlaceDraft] {
        guard rng.chance(photoDayProbability) else { return [] }
        return placeDailyPhotos(&rng, at: place, day: day, count: rng.int(in: 1...8))
    }

    /// A fixed number of daily-life photos, for scenarios that pin one day.
    private static func placeDailyPhotos(
        _ rng: inout SeededRandom,
        at place: GeoPoint,
        day: Int,
        count: Int,
        noLocationProbability: Double = 0.1
    ) -> [PlaceDraft] {
        var photos: [PlaceDraft] = []
        for _ in 0..<count {
            let date = placeTimeOfDay(day: day, rng: &rng)
            let coordinate = rng.chance(noLocationProbability)
                ? nil
                : placeJittered(place, latitude: 0.08, longitude: 0.12, rng: &rng)
            photos.append(PlaceDraft(
                date: date,
                coordinate: coordinate,
                perceptualHash: rng.next(),
                truthTrip: nil,
                truthStack: nil
            ))
        }
        return photos
    }

    private static func placeTripPhotos(
        _ rng: inout SeededRandom,
        at place: GeoPoint,
        day: Int,
        trip: String,
        noLocationProbability: Double = 0.05
    ) -> [PlaceDraft] {
        let count = rng.int(in: 5...25)
        var photos: [PlaceDraft] = []
        for _ in 0..<count {
            let date = placeTimeOfDay(day: day, rng: &rng)
            let coordinate = rng.chance(noLocationProbability)
                ? nil
                : placeJittered(place, latitude: 0.05, longitude: 0.07, rng: &rng)
            photos.append(PlaceDraft(
                date: date,
                coordinate: coordinate,
                perceptualHash: rng.next(),
                truthTrip: trip,
                truthStack: nil
            ))
        }
        return photos
    }

    private static func placeTimeOfDay(day: Int, rng: inout SeededRandom) -> Date {
        let seconds = rng.double(in: 8 * 3_600..<22 * 3_600)
        return baseDate.addingTimeInterval(Double(day) * 86_400 + seconds)
    }

    private static func placeJittered(
        _ place: GeoPoint,
        latitude: Double,
        longitude: Double,
        rng: inout SeededRandom
    ) -> GeoPoint {
        GeoPoint(
            latitude: place.latitude + rng.double(in: -latitude..<latitude),
            longitude: place.longitude + rng.double(in: -longitude..<longitude)
        )
    }

    // MARK: - Assembly

    /// Sorts by date (then by the order made) and assigns ids.
    private static func placeScenario(name: String, drafts: [PlaceDraft]) -> SyntheticScenario {
        let ordered = drafts.enumerated().sorted { (left: (offset: Int, element: PlaceDraft), right: (offset: Int, element: PlaceDraft)) -> Bool in
            if left.element.date != right.element.date { return left.element.date < right.element.date }
            return left.offset < right.offset
        }
        let photos = ordered.enumerated().map { (index: Int, entry: (offset: Int, element: PlaceDraft)) -> SyntheticPhoto in
            SyntheticPhoto(
                id: String(format: "%@-%04d", name, index),
                date: entry.element.date,
                coordinate: entry.element.coordinate,
                perceptualHash: entry.element.perceptualHash,
                truthTrip: entry.element.truthTrip,
                truthStack: entry.element.truthStack
            )
        }
        return SyntheticScenario(name: name, photos: photos)
    }
}

// MARK: - Places

private enum PlacePlaces {
    static let berlin = GeoPoint(latitude: 52.52, longitude: 13.40)
    static let dresden = GeoPoint(latitude: 51.05, longitude: 13.74)
    static let lisbon = GeoPoint(latitude: 38.72, longitude: -9.14)
    static let tokyo = GeoPoint(latitude: 35.68, longitude: 139.70)
    static let kyoto = GeoPoint(latitude: 35.01, longitude: 135.77)
    static let osaka = GeoPoint(latitude: 34.69, longitude: 135.50)
    static let hiroshima = GeoPoint(latitude: 34.39, longitude: 132.46)
    static let fukuoka = GeoPoint(latitude: 33.59, longitude: 130.40)
    static let sapporo = GeoPoint(latitude: 43.06, longitude: 141.35)
    static let prague = GeoPoint(latitude: 50.08, longitude: 14.44)
    static let vienna = GeoPoint(latitude: 48.21, longitude: 16.37)
    static let budapest = GeoPoint(latitude: 47.50, longitude: 19.04)
    static let newYork = GeoPoint(latitude: 40.71, longitude: -74.01)
}

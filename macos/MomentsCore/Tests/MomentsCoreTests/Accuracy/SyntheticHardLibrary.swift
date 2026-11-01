import Foundation
@testable import MomentsCore

/// Harder synthetic libraries with known trips, built in the same style as
/// `SyntheticLibrary.scenarios(seed:)`. They add the cases the easy catalogue
/// never shows: a cruise that stops at a different port every day with sea
/// days in between, a road trip across eleven cities, a long layover, a single
/// far day trip, a sparse long trip with a 300 km move after a quiet gap,
/// screenshots taken on a trip, and thirteen short weekend trips over a year.
extension SyntheticLibrary {
    static func hardScenarios(seed: UInt64 = 1) -> [SyntheticScenario] {
        [
            cruise(seed: seed &+ 100 &+ 1),
            roadTrip(seed: seed &+ 100 &+ 2),
            layover(seed: seed &+ 100 &+ 3),
            dayTripFar(seed: seed &+ 100 &+ 4),
            sparseLongTrip(seed: seed &+ 100 &+ 5),
            screenshotsOnTrip(seed: seed &+ 100 &+ 6),
            monthlyWeekends(seed: seed &+ 100 &+ 7),
        ]
    }

    // MARK: - Scenarios

    private static func cruise(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [HardPhotoDraft] = []
        for day in 0..<150 where !(100..<110).contains(day) {
            drafts += hardDailyPhotos(&rng, at: HardPlaces.berlin, day: day)
        }
        // The ports are scheduled one per day, in this order; on the sea days
        // the ship stays at sea and nobody takes a photo.
        let ports: [GeoPoint] = [
            HardPlaces.barcelona,
            HardPlaces.marseille,
            HardPlaces.genoa,
            HardPlaces.livorno,
            HardPlaces.civitavecchia,
            HardPlaces.naples,
            HardPlaces.palermo,
            HardPlaces.valletta,
            HardPlaces.tunis,
            HardPlaces.cagliari,
        ]
        for (offset, port) in ports.enumerated() {
            let day = 100 + offset
            if day == 103 || day == 107 { continue }
            drafts += hardTripPhotos(&rng, at: port, day: day, trip: "cruise")
        }
        return hardScenario(name: "cruise", drafts: drafts)
    }

    private static func roadTrip(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [HardPhotoDraft] = []
        for day in 0..<150 where !(60..<72).contains(day) {
            drafts += hardDailyPhotos(&rng, at: HardPlaces.berlin, day: day)
        }
        // Every day has its own city; day 65 is a rest day with no photos.
        let stops: [(day: Int, place: GeoPoint)] = [
            (60, HardPlaces.prague),
            (61, HardPlaces.vienna),
            (62, HardPlaces.budapest),
            (63, HardPlaces.zagreb),
            (64, HardPlaces.ljubljana),
            (66, HardPlaces.venice),
            (67, HardPlaces.verona),
            (68, HardPlaces.innsbruck),
            (69, HardPlaces.munich),
            (70, HardPlaces.nuremberg),
            (71, HardPlaces.leipzig),
        ]
        for stop in stops {
            drafts += hardTripPhotos(&rng, at: stop.place, day: stop.day, trip: "roadtrip")
        }
        return hardScenario(name: "road-trip", drafts: drafts)
    }

    private static func layover(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [HardPhotoDraft] = []
        for day in 0..<120 where !(60..<68).contains(day) {
            drafts += hardDailyPhotos(&rng, at: HardPlaces.berlin, day: day)
        }
        // Three early-morning shots in Dubai before the plane leaves.
        drafts += hardTripPhotos(
            &rng,
            at: HardPlaces.dubai,
            day: 60,
            trip: "tokyo",
            count: 3,
            hours: 2..<5,
            noLocationProbability: 0
        )
        for day in 60..<68 {
            // Tokyo starts after the connection on day 60 and ends early on the
            // last day, when the next layover starts.
            let hours: Range<Double>
            switch day {
            case 60: hours = 12..<22
            case 67: hours = 8..<18
            default: hours = 8..<22
            }
            drafts += hardTripPhotos(&rng, at: HardPlaces.tokyo, day: day, trip: "tokyo", hours: hours)
        }
        // Two more Dubai shots on the way home, after the Tokyo photos.
        drafts += hardTripPhotos(
            &rng,
            at: HardPlaces.dubai,
            day: 67,
            trip: "tokyo",
            count: 2,
            hours: 21..<23,
            noLocationProbability: 0
        )
        return hardScenario(name: "layover", drafts: drafts)
    }

    private static func dayTripFar(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [HardPhotoDraft] = []
        for day in 0..<90 where day != 40 {
            drafts += hardDailyPhotos(&rng, at: HardPlaces.berlin, day: day)
        }
        drafts += hardTripPhotos(
            &rng,
            at: HardPlaces.hamburg,
            day: 40,
            trip: "hamburg-day",
            count: 25,
            hours: 9..<20,
            noLocationProbability: 0
        )
        return hardScenario(name: "day-trip-far", drafts: drafts)
    }

    private static func sparseLongTrip(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [HardPhotoDraft] = []
        for day in 0..<150 where !(90..<111).contains(day) {
            drafts += hardDailyPhotos(&rng, at: HardPlaces.berlin, day: day)
        }
        // Tokyo, then Kyoto, then Osaka, but photos only on a few days. The
        // Tokyo-to-Kyoto move crosses a three-day gap of more than 300 km.
        let photoDays = [90, 91, 95, 99, 100, 102, 106, 108, 110]
        for day in photoDays {
            let place: GeoPoint
            if day < 97 {
                place = HardPlaces.tokyo
            } else if day < 104 {
                place = HardPlaces.kyoto
            } else {
                place = HardPlaces.osaka
            }
            drafts += hardTripPhotos(&rng, at: place, day: day, trip: "japan")
        }
        return hardScenario(name: "sparse-long-trip", drafts: drafts)
    }

    private static func screenshotsOnTrip(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [HardPhotoDraft] = []
        for day in 0..<120 where !(50..<55).contains(day) {
            drafts += hardDailyPhotos(&rng, at: HardPlaces.berlin, day: day)
        }
        for day in 50..<55 {
            // The camera's photos all have a location, so the only trip photos
            // without one are the two screenshots taken each day.
            let located = hardTripPhotos(&rng, at: HardPlaces.paris, day: day, trip: "paris", noLocationProbability: 0)
            drafts += located
            let dayStart = baseDate.addingTimeInterval(Double(day) * 86_400)
            for _ in 0..<2 {
                let anchor = located[rng.int(in: 0...(located.count - 1))]
                let offset = rng.double(in: -2 * 3_600..<2 * 3_600)
                // Stay on the same day, which keeps it within two hours of the anchor.
                let earliest = max(dayStart, anchor.date.addingTimeInterval(-2 * 3_600))
                let latest = min(dayStart.addingTimeInterval(86_400 - 1), anchor.date.addingTimeInterval(2 * 3_600))
                let date = min(max(anchor.date.addingTimeInterval(offset), earliest), latest)
                drafts.append(HardPhotoDraft(
                    date: date,
                    coordinate: nil,
                    perceptualHash: rng.next(),
                    truthTrip: "paris",
                    truthStack: nil
                ))
            }
        }
        return hardScenario(name: "screenshots-on-trip", drafts: drafts)
    }

    private static func monthlyWeekends(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [HardPhotoDraft] = []
        var tripByDay: [Int: String] = [:]
        for index in 0...12 {
            let name = String(format: "dresden-%02d", index + 1)
            tripByDay[28 * index + 20] = name
            tripByDay[28 * index + 21] = name
        }
        for day in 0..<365 {
            if let trip = tripByDay[day] {
                drafts += hardTripPhotos(&rng, at: HardPlaces.dresden, day: day, trip: trip)
            } else {
                drafts += hardDailyPhotos(&rng, at: HardPlaces.berlin, day: day)
            }
        }
        return hardScenario(name: "monthly-weekends", drafts: drafts)
    }

    // MARK: - Photos

    /// One photo before the scenario sorts it and gives it an id.
    private struct HardPhotoDraft {
        let date: Date
        let coordinate: GeoPoint?
        let perceptualHash: UInt64
        let truthTrip: String?
        let truthStack: String?
    }

    private static func hardDailyPhotos(_ rng: inout SeededRandom, at place: GeoPoint, day: Int) -> [HardPhotoDraft] {
        guard rng.chance(0.7) else { return [] }
        return hardDailyPhotos(&rng, at: place, day: day, count: rng.int(in: 1...8))
    }

    /// A fixed number of daily-life photos, for scenarios that pin one day.
    private static func hardDailyPhotos(
        _ rng: inout SeededRandom,
        at place: GeoPoint,
        day: Int,
        count: Int,
        noLocationProbability: Double = 0.1
    ) -> [HardPhotoDraft] {
        var photos: [HardPhotoDraft] = []
        for _ in 0..<count {
            let date = hardTimeOfDay(day: day, rng: &rng)
            let coordinate = rng.chance(noLocationProbability)
                ? nil
                : hardJittered(place, latitude: 0.08, longitude: 0.12, rng: &rng)
            photos.append(HardPhotoDraft(
                date: date,
                coordinate: coordinate,
                perceptualHash: rng.next(),
                truthTrip: nil,
                truthStack: nil
            ))
        }
        return photos
    }

    private static func hardTripPhotos(
        _ rng: inout SeededRandom,
        at place: GeoPoint,
        day: Int,
        trip: String,
        count: Int? = nil,
        hours: Range<Double> = 8..<22,
        noLocationProbability: Double = 0.05
    ) -> [HardPhotoDraft] {
        let photoCount = count ?? rng.int(in: 5...25)
        var photos: [HardPhotoDraft] = []
        for _ in 0..<photoCount {
            let date = hardTimeOfDay(day: day, hours: hours, rng: &rng)
            let coordinate = rng.chance(noLocationProbability)
                ? nil
                : hardJittered(place, latitude: 0.05, longitude: 0.07, rng: &rng)
            photos.append(HardPhotoDraft(
                date: date,
                coordinate: coordinate,
                perceptualHash: rng.next(),
                truthTrip: trip,
                truthStack: nil
            ))
        }
        return photos
    }

    private static func hardTimeOfDay(day: Int, hours: Range<Double> = 8..<22, rng: inout SeededRandom) -> Date {
        let seconds = rng.double(in: (hours.lowerBound * 3_600)..<(hours.upperBound * 3_600))
        return baseDate.addingTimeInterval(Double(day) * 86_400 + seconds)
    }

    private static func hardJittered(
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
    private static func hardScenario(name: String, drafts: [HardPhotoDraft]) -> SyntheticScenario {
        let ordered = drafts.enumerated().sorted { left, right in
            if left.element.date != right.element.date { return left.element.date < right.element.date }
            return left.offset < right.offset
        }
        let photos = ordered.enumerated().map { index, entry in
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

private enum HardPlaces {
    static let berlin = GeoPoint(latitude: 52.52, longitude: 13.40)
    static let dresden = GeoPoint(latitude: 51.05, longitude: 13.74)
    static let hamburg = GeoPoint(latitude: 53.55, longitude: 9.99)
    static let prague = GeoPoint(latitude: 50.08, longitude: 14.44)
    static let vienna = GeoPoint(latitude: 48.21, longitude: 16.37)
    static let budapest = GeoPoint(latitude: 47.50, longitude: 19.04)
    static let zagreb = GeoPoint(latitude: 45.81, longitude: 15.98)
    static let ljubljana = GeoPoint(latitude: 46.06, longitude: 14.51)
    static let venice = GeoPoint(latitude: 45.44, longitude: 12.32)
    static let verona = GeoPoint(latitude: 45.44, longitude: 10.99)
    static let innsbruck = GeoPoint(latitude: 47.27, longitude: 11.40)
    static let munich = GeoPoint(latitude: 48.14, longitude: 11.58)
    static let nuremberg = GeoPoint(latitude: 49.45, longitude: 11.08)
    static let leipzig = GeoPoint(latitude: 51.34, longitude: 12.37)
    static let paris = GeoPoint(latitude: 48.85, longitude: 2.35)
    static let tokyo = GeoPoint(latitude: 35.68, longitude: 139.70)
    static let kyoto = GeoPoint(latitude: 35.01, longitude: 135.77)
    static let osaka = GeoPoint(latitude: 34.69, longitude: 135.50)
    static let dubai = GeoPoint(latitude: 25.25, longitude: 55.36)

    // Western Mediterranean cruise ports, in sailing order.
    static let barcelona = GeoPoint(latitude: 41.38, longitude: 2.17)
    static let marseille = GeoPoint(latitude: 43.30, longitude: 5.37)
    static let genoa = GeoPoint(latitude: 44.41, longitude: 8.93)
    static let livorno = GeoPoint(latitude: 43.55, longitude: 10.31)
    static let civitavecchia = GeoPoint(latitude: 42.09, longitude: 11.80)
    static let naples = GeoPoint(latitude: 40.85, longitude: 14.27)
    static let palermo = GeoPoint(latitude: 38.12, longitude: 13.36)
    static let valletta = GeoPoint(latitude: 35.90, longitude: 14.51)
    static let tunis = GeoPoint(latitude: 36.81, longitude: 10.18)
    static let cagliari = GeoPoint(latitude: 39.22, longitude: 9.12)
}

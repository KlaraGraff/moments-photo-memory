import Foundation
@testable import MomentsCore

/// Libraries of someone who works away from their home town and moves from
/// one work site to the next, with the truth the owner gave: going back to
/// the home town, the journey there, a move to a new work site and a few days
/// at a former work site are daily life; only holidays elsewhere are trips.
extension SyntheticLibrary {
    static func workAbroadScenarios(seed: UInt64 = 1) -> [SyntheticScenario] {
        [
            homeTownHoliday(seed: seed &+ 400 &+ 1),
            workSites(seed: seed &+ 400 &+ 2),
        ]
    }

    /// A year at home in the home town, then a year at a work site abroad
    /// with three weeks back home. Every flight between the two has a layover
    /// with a few photos. One trip each year: Beijing, then Marrakech.
    private static func homeTownHoliday(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [WorkDraft] = []
        let holiday = 550..<571
        for day in 0..<730 {
            switch day {
            case 100..<105:
                drafts += workPhotos(&rng, at: WorkPlaces.beijing, day: day, count: 4...15, trip: "beijing")
            case 420..<423:
                drafts += workPhotos(&rng, at: WorkPlaces.marrakech, day: day, count: 4...15, trip: "marrakech")
            case 364, 549, 571:
                // The layover on the way: a few photos in an afternoon.
                drafts += workPhotos(&rng, at: WorkPlaces.dubai, day: day, count: 3...8, trip: nil, hours: 12..<17)
            case holiday:
                drafts += workPhotos(&rng, at: WorkPlaces.shanghai, day: day, count: 3...15, trip: nil)
            case 0..<364:
                if rng.chance(0.4) { drafts += workPhotos(&rng, at: WorkPlaces.shanghai, day: day, count: 1...6, trip: nil) }
            default:
                if rng.chance(0.7) { drafts += workPhotos(&rng, at: WorkPlaces.kenitra, day: day, count: 3...20, trip: nil) }
            }
        }
        return workScenario(name: "home-town-holiday", drafts: drafts)
    }

    /// Four work sites in a year, each photographed most days, and three
    /// days back at a former site. The one trip is a holiday in Seville.
    private static func workSites(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [WorkDraft] = []
        for day in 0..<365 {
            let site: GeoPoint
            switch day {
            case 260..<265:
                drafts += workPhotos(&rng, at: WorkPlaces.seville, day: day, count: 4...15, trip: "seville")
                continue
            case 300..<303:
                // A visit to the second site, where they worked before.
                drafts += workPhotos(&rng, at: WorkPlaces.jorfLasfar, day: day, count: 3...12, trip: nil)
                continue
            case 0..<120: site = WorkPlaces.kenitra
            case 120..<190: site = WorkPlaces.jorfLasfar
            case 190..<230: site = WorkPlaces.tangier
            default: site = WorkPlaces.laayoune
            }
            if rng.chance(0.75) { drafts += workPhotos(&rng, at: site, day: day, count: 3...20, trip: nil) }
        }
        return workScenario(name: "work-sites", drafts: drafts)
    }

    private struct WorkDraft {
        let date: Date
        let coordinate: GeoPoint?
        let trip: String?
    }

    private static func workPhotos(
        _ rng: inout SeededRandom,
        at place: GeoPoint,
        day: Int,
        count: ClosedRange<Int>,
        trip: String?,
        hours: Range<Double> = 8..<22
    ) -> [WorkDraft] {
        (0..<rng.int(in: count)).map { _ in
            let seconds = rng.double(in: (hours.lowerBound * 3_600)..<(hours.upperBound * 3_600))
            let coordinate: GeoPoint? = rng.chance(0.05) ? nil : GeoPoint(
                latitude: place.latitude + rng.double(in: -0.04..<0.04),
                longitude: place.longitude + rng.double(in: -0.05..<0.05)
            )
            return WorkDraft(date: baseDate.addingTimeInterval(Double(day) * 86_400 + seconds), coordinate: coordinate, trip: trip)
        }
    }

    private static func workScenario(name: String, drafts: [WorkDraft]) -> SyntheticScenario {
        let ordered = drafts.enumerated().sorted { left, right in
            left.element.date == right.element.date ? left.offset < right.offset : left.element.date < right.element.date
        }
        var rng = SeededRandom(seed: 99)
        let photos = ordered.enumerated().map { index, entry in
            SyntheticPhoto(
                id: String(format: "%@-%05d", name, index),
                date: entry.element.date,
                coordinate: entry.element.coordinate,
                perceptualHash: rng.next(),
                truthTrip: entry.element.trip,
                truthStack: nil
            )
        }
        return SyntheticScenario(name: name, photos: photos)
    }
}

private enum WorkPlaces {
    static let shanghai = GeoPoint(latitude: 31.23, longitude: 121.47)
    static let beijing = GeoPoint(latitude: 39.90, longitude: 116.40)
    static let dubai = GeoPoint(latitude: 25.25, longitude: 55.36)
    static let kenitra = GeoPoint(latitude: 34.26, longitude: -6.58)
    static let marrakech = GeoPoint(latitude: 31.63, longitude: -8.01)
    static let jorfLasfar = GeoPoint(latitude: 33.11, longitude: -8.63)
    static let tangier = GeoPoint(latitude: 35.76, longitude: -5.83)
    static let laayoune = GeoPoint(latitude: 27.15, longitude: -13.20)
    static let seville = GeoPoint(latitude: 37.39, longitude: -5.98)
}

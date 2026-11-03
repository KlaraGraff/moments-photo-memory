import Foundation
@testable import MomentsCore

/// The long-stay catalogue: three 365-day libraries where someone stays three
/// months in one place away from home. The truth follows what was done there,
/// not the length of the stay: `exchange-semester` (weekday photos rare,
/// weekends dense) and `work-posting` (sparse days) are daily life of a long
/// stay, `slow-travel` (photos almost daily and dense) is one long trip.
extension SyntheticLibrary {
    static func longStayScenarios(seed: UInt64 = 1) -> [SyntheticScenario] {
        [
            exchangeSemester(seed: seed &+ 300 &+ 1),
            workPosting(seed: seed &+ 300 &+ 2),
            slowTravel(seed: seed &+ 300 &+ 3),
        ]
    }

    // MARK: - Scenarios

    /// 90 days in Paris. Weekdays have almost no photos, weekends are dense
    /// and three weekends are outings to Prague, Vienna and Copenhagen.
    /// Truth: the Paris days are daily life, the three outings are trips.
    private static func exchangeSemester(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [LongStayDraft] = []
        let stayDays = 120..<210
        let outings: [(days: Range<Int>, name: String, place: GeoPoint)] = [
            (148..<151, "prague", LongStayPlaces.prague),
            (176..<179, "vienna", LongStayPlaces.vienna),
            (197..<200, "copenhagen", LongStayPlaces.copenhagen),
        ]
        var outingByDay: [Int: (name: String, place: GeoPoint)] = [:]
        for outing in outings {
            for day in outing.days { outingByDay[day] = (name: outing.name, place: outing.place) }
        }
        for day in 0..<365 {
            if let outing = outingByDay[day] {
                drafts += longStayTripPhotos(&rng, at: outing.place, day: day, trip: outing.name)
            } else if stayDays.contains(day) {
                if longStayIsWeekend(day) {
                    drafts += longStayPhotos(
                        &rng,
                        at: LongStayPlaces.paris,
                        day: day,
                        photoDayProbability: 1,
                        count: 8...20
                    )
                } else {
                    drafts += longStayPhotos(
                        &rng,
                        at: LongStayPlaces.paris,
                        day: day,
                        photoDayProbability: 0.2,
                        count: 1...3
                    )
                }
            } else {
                drafts += longStayHomePhotos(&rng, at: LongStayPlaces.berlin, day: day)
            }
        }
        return longStayScenario(name: "exchange-semester", drafts: drafts)
    }

    /// 90 days in Singapore with photos on only a few days, one trip to Bali.
    /// Truth: the Singapore days are daily life, Bali is a trip.
    private static func workPosting(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [LongStayDraft] = []
        let stayDays = 100..<190
        let baliDays = 145..<149
        for day in 0..<365 {
            if baliDays.contains(day) {
                drafts += longStayTripPhotos(&rng, at: LongStayPlaces.bali, day: day, trip: "bali")
            } else if stayDays.contains(day) {
                drafts += longStayPhotos(
                    &rng,
                    at: LongStayPlaces.singapore,
                    day: day,
                    photoDayProbability: 0.25,
                    count: 5...15
                )
            } else {
                drafts += longStayHomePhotos(&rng, at: LongStayPlaces.berlin, day: day)
            }
        }
        return longStayScenario(name: "work-posting", drafts: drafts)
    }

    /// 90 days in Chiang Mai with photos almost every day and dense, plus two
    /// short trips to Pai and Chiang Rai. Truth: all of it is ONE trip.
    private static func slowTravel(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [LongStayDraft] = []
        let stayDays = 120..<210
        let paiDays = 140..<143
        let chiangRaiDays = 170..<173
        for day in 0..<365 {
            if paiDays.contains(day) {
                drafts += longStayTripPhotos(&rng, at: LongStayPlaces.pai, day: day, trip: "slow-travel")
            } else if chiangRaiDays.contains(day) {
                drafts += longStayTripPhotos(&rng, at: LongStayPlaces.chiangRai, day: day, trip: "slow-travel")
            } else if stayDays.contains(day) {
                drafts += longStayPhotos(
                    &rng,
                    at: LongStayPlaces.chiangMai,
                    day: day,
                    photoDayProbability: 0.85,
                    count: 5...15,
                    truthTrip: "slow-travel"
                )
            } else {
                drafts += longStayHomePhotos(&rng, at: LongStayPlaces.berlin, day: day)
            }
        }
        return longStayScenario(name: "slow-travel", drafts: drafts)
    }

    // MARK: - Photos

    /// One photo before the scenario sorts it and gives it an id.
    private struct LongStayDraft {
        let date: Date
        let coordinate: GeoPoint?
        let perceptualHash: UInt64
        let truthTrip: String?
        let truthStack: String?
    }

    /// Daily-life photos at home: a busy library, so one stay away stays the
    /// smaller part of the year.
    private static func longStayHomePhotos(
        _ rng: inout SeededRandom,
        at place: GeoPoint,
        day: Int
    ) -> [LongStayDraft] {
        longStayPhotos(&rng, at: place, day: day, photoDayProbability: 0.9, count: 1...8)
    }

    /// Photos of a stay away: on a `photoDayProbability` day, `count` photos.
    private static func longStayPhotos(
        _ rng: inout SeededRandom,
        at place: GeoPoint,
        day: Int,
        photoDayProbability: Double,
        count: ClosedRange<Int>,
        truthTrip: String? = nil,
        noLocationProbability: Double = 0.1
    ) -> [LongStayDraft] {
        guard rng.chance(photoDayProbability) else { return [] }
        let photoCount: Int = rng.int(in: count)
        var photos: [LongStayDraft] = []
        for _ in 0..<photoCount {
            let date: Date = longStayTimeOfDay(day: day, rng: &rng)
            let coordinate: GeoPoint? = rng.chance(noLocationProbability)
                ? nil
                : longStayJittered(place, latitude: 0.05, longitude: 0.07, rng: &rng)
            photos.append(LongStayDraft(
                date: date,
                coordinate: coordinate,
                perceptualHash: rng.next(),
                truthTrip: truthTrip,
                truthStack: nil
            ))
        }
        return photos
    }

    /// Photos of an outing: dense, every day of the trip.
    private static func longStayTripPhotos(
        _ rng: inout SeededRandom,
        at place: GeoPoint,
        day: Int,
        trip: String,
        noLocationProbability: Double = 0.05
    ) -> [LongStayDraft] {
        let photoCount: Int = rng.int(in: 8...20)
        var photos: [LongStayDraft] = []
        for _ in 0..<photoCount {
            let date: Date = longStayTimeOfDay(day: day, rng: &rng)
            let coordinate: GeoPoint? = rng.chance(noLocationProbability)
                ? nil
                : longStayJittered(place, latitude: 0.05, longitude: 0.07, rng: &rng)
            photos.append(LongStayDraft(
                date: date,
                coordinate: coordinate,
                perceptualHash: rng.next(),
                truthTrip: trip,
                truthStack: nil
            ))
        }
        return photos
    }

    private static func longStayTimeOfDay(day: Int, rng: inout SeededRandom) -> Date {
        let seconds: Double = rng.double(in: 8 * 3_600..<22 * 3_600)
        return baseDate.addingTimeInterval(Double(day) * 86_400 + seconds)
    }

    private static func longStayJittered(
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

    /// `baseDate` is a Sunday; day 6 of every week is the Saturday.
    private static func longStayIsWeekend(_ day: Int) -> Bool {
        day % 7 == 0 || day % 7 == 6
    }

    // MARK: - Assembly

    /// Sorts by date (then by the order made) and assigns ids.
    private static func longStayScenario(name: String, drafts: [LongStayDraft]) -> SyntheticScenario {
        let ordered: [(offset: Int, element: LongStayDraft)] = drafts.enumerated().sorted {
            (left: (offset: Int, element: LongStayDraft), right: (offset: Int, element: LongStayDraft)) -> Bool in
            if left.element.date != right.element.date { return left.element.date < right.element.date }
            return left.offset < right.offset
        }
        let photos: [SyntheticPhoto] = ordered.enumerated().map {
            (index: Int, entry: (offset: Int, element: LongStayDraft)) -> SyntheticPhoto in
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

private enum LongStayPlaces {
    static let berlin = GeoPoint(latitude: 52.52, longitude: 13.40)
    static let paris = GeoPoint(latitude: 48.86, longitude: 2.35)
    static let prague = GeoPoint(latitude: 50.08, longitude: 14.44)
    static let vienna = GeoPoint(latitude: 48.21, longitude: 16.37)
    static let copenhagen = GeoPoint(latitude: 55.68, longitude: 12.57)
    static let singapore = GeoPoint(latitude: 1.35, longitude: 103.82)
    static let bali = GeoPoint(latitude: -8.65, longitude: 115.22)
    static let chiangMai = GeoPoint(latitude: 18.79, longitude: 98.98)
    static let pai = GeoPoint(latitude: 19.36, longitude: 98.44)
    static let chiangRai = GeoPoint(latitude: 19.91, longitude: 99.83)
}

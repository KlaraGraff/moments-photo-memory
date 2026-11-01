import Foundation
@testable import MomentsCore

/// SplitMix64: small, fast and the same on every platform.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// Uniform integer in the closed range.
    mutating func int(in range: ClosedRange<Int>) -> Int {
        precondition(range.lowerBound <= range.upperBound)
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        let limit = UInt64.max - UInt64.max % width
        var value = next()
        while value >= limit { value = next() }
        return range.lowerBound + Int(value % width)
    }

    /// Uniform double in the half-open range.
    mutating func double(in range: Range<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }

    /// True with the given probability.
    mutating func chance(_ probability: Double) -> Bool {
        unit() < probability
    }
}

struct SyntheticPhoto: Equatable {
    let id: String
    let date: Date
    let coordinate: GeoPoint?
    let perceptualHash: UInt64
    /// Ground truth: the trip this photo belongs to; nil for daily life.
    let truthTrip: String?
    /// Ground truth: the burst this photo belongs to; nil when it is not in a burst.
    let truthStack: String?

    var stop: PhotoStop { PhotoStop(id: id, date: date, coordinate: coordinate) }
    var stackPhoto: StackPhoto { StackPhoto(id: id, captureDate: date, perceptualHash: perceptualHash) }
}

struct SyntheticScenario {
    let name: String
    /// Sorted by date; ids are "<name>-0000", "<name>-0001", … in that order.
    let photos: [SyntheticPhoto]

    /// Ground truth trips: photo ids per trip, each in date order, trips in date order.
    var truthTrips: [[String]] { Self.groups(in: photos, by: \.truthTrip) }

    /// Ground truth bursts: photo ids per burst, in date order.
    var truthStacks: [[String]] { Self.groups(in: photos, by: \.truthStack) }

    private static func groups(in photos: [SyntheticPhoto], by key: KeyPath<SyntheticPhoto, String?>) -> [[String]] {
        var order: [String] = []
        var grouped: [String: [String]] = [:]
        for photo in photos {
            guard let name = photo[keyPath: key] else { continue }
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(photo.id)
        }
        return order.map { grouped[$0] ?? [] }
    }
}

enum SyntheticLibrary {
    static let baseDate = Date(timeIntervalSince1970: 1_672_531_200) // 2023-01-01 00:00 UTC

    /// The fixed catalogue, always the same for the same seed.
    static func scenarios(seed: UInt64 = 1) -> [SyntheticScenario] {
        [
            weekendTrip(seed: seed &+ 1),
            longTrip(seed: seed &+ 2),
            nearbyOuting(seed: seed &+ 3),
            backToBack(seed: seed &+ 4),
            cameraWithoutGPS(seed: seed &+ 5),
            movedCity(seed: seed &+ 6),
            singleTripFolder(seed: seed &+ 7),
            bursts(seed: seed &+ 8),
            antimeridianTrip(seed: seed &+ 9),
            twoHomes(seed: seed &+ 10),
        ]
    }

    // MARK: - Scenarios

    private static func weekendTrip(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [PhotoDraft] = []
        for day in 0..<120 where !(60..<62).contains(day) {
            drafts += dailyPhotos(&rng, at: berlin, day: day)
        }
        for day in 60..<62 {
            drafts += tripPhotos(&rng, at: dresden, day: day, trip: "dresden")
        }
        return scenario(name: "weekend-trip", drafts: drafts)
    }

    private static func longTrip(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [PhotoDraft] = []
        for day in 0..<200 where !(100..<112).contains(day) {
            drafts += dailyPhotos(&rng, at: berlin, day: day)
        }
        for day in 100..<104 { drafts += tripPhotos(&rng, at: rome, day: day, trip: "italy") }
        for day in 104..<108 { drafts += tripPhotos(&rng, at: florence, day: day, trip: "italy") }
        for day in 108..<112 { drafts += tripPhotos(&rng, at: venice, day: day, trip: "italy") }
        return scenario(name: "long-trip", drafts: drafts)
    }

    private static func nearbyOuting(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [PhotoDraft] = []
        for day in 0..<120 {
            if day == 50 {
                // The outing's shots all have a location: there are exactly 30 of them.
                drafts += dailyPhotos(&rng, at: potsdam, day: day, count: 30, noLocationProbability: 0)
            } else {
                drafts += dailyPhotos(&rng, at: berlin, day: day)
            }
        }
        return scenario(name: "nearby-outing", drafts: drafts)
    }

    private static func backToBack(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [PhotoDraft] = []
        for day in 0..<150 where !(70..<80).contains(day) {
            drafts += dailyPhotos(&rng, at: berlin, day: day)
        }
        for day in 70..<75 { drafts += tripPhotos(&rng, at: paris, day: day, trip: "paris") }
        drafts += dailyPhotos(&rng, at: berlin, day: 75, count: 6)
        for day in 76..<80 { drafts += tripPhotos(&rng, at: london, day: day, trip: "london") }
        return scenario(name: "back-to-back", drafts: drafts)
    }

    private static func cameraWithoutGPS(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [PhotoDraft] = []
        for day in 0..<150 where !(80..<86).contains(day) {
            drafts += dailyPhotos(&rng, at: berlin, day: day)
        }
        for day in 80..<86 {
            drafts += tripPhotos(&rng, at: lisbon, day: day, trip: "lisbon", noLocationProbability: 0.7)
        }
        return scenario(name: "camera-without-gps", drafts: drafts)
    }

    private static func movedCity(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [PhotoDraft] = []
        for day in 0..<240 {
            drafts += dailyPhotos(&rng, at: berlin, day: day)
        }
        for day in 240..<480 where !(400..<405).contains(day) {
            drafts += dailyPhotos(&rng, at: munich, day: day)
        }
        for day in 400..<405 {
            drafts += tripPhotos(&rng, at: vienna, day: day, trip: "vienna")
        }
        return scenario(name: "moved-city", drafts: drafts)
    }

    private static func singleTripFolder(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [PhotoDraft] = []
        for day in 0..<7 {
            drafts += tripPhotos(&rng, at: tokyo, day: day, trip: "tokyo")
        }
        return scenario(name: "single-trip-folder", drafts: drafts)
    }

    private static func bursts(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [PhotoDraft] = []
        for day in 0..<90 {
            drafts += dailyPhotos(&rng, at: berlin, day: day)
        }
        addBursts(&rng, to: &drafts)
        addQuickPairs(&rng, to: &drafts)
        return scenario(name: "bursts", drafts: drafts)
    }

    private static func antimeridianTrip(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [PhotoDraft] = []
        for day in 0..<150 where !(90..<96).contains(day) {
            drafts += dailyPhotos(&rng, at: auckland, day: day)
        }
        for day in 90..<93 { drafts += tripPhotos(&rng, at: suva, day: day, trip: "fiji") }
        for day in 93..<96 { drafts += tripPhotos(&rng, at: taveuni, day: day, trip: "fiji") }
        return scenario(name: "antimeridian-trip", drafts: drafts)
    }

    private static func twoHomes(seed: UInt64) -> SyntheticScenario {
        var rng = SeededRandom(seed: seed)
        var drafts: [PhotoDraft] = []
        for day in 0..<210 where !(150..<155).contains(day) {
            let home = day % 7 < 5 ? berlin : hamburg
            drafts += dailyPhotos(&rng, at: home, day: day)
        }
        for day in 150..<155 {
            drafts += tripPhotos(&rng, at: prague, day: day, trip: "prague")
        }
        return scenario(name: "two-homes", drafts: drafts)
    }

    // MARK: - Photos

    /// One photo before the scenario sorts it and gives it an id.
    private struct PhotoDraft {
        let date: Date
        let coordinate: GeoPoint?
        let perceptualHash: UInt64
        let truthTrip: String?
        let truthStack: String?
    }

    private static func dailyPhotos(_ rng: inout SeededRandom, at place: GeoPoint, day: Int) -> [PhotoDraft] {
        guard rng.chance(0.7) else { return [] }
        return dailyPhotos(&rng, at: place, day: day, count: rng.int(in: 1...8))
    }

    /// A fixed number of daily-life photos, for scenarios that pin one day.
    private static func dailyPhotos(
        _ rng: inout SeededRandom,
        at place: GeoPoint,
        day: Int,
        count: Int,
        noLocationProbability: Double = 0.1
    ) -> [PhotoDraft] {
        var photos: [PhotoDraft] = []
        for _ in 0..<count {
            let date = timeOfDay(day: day, rng: &rng)
            let coordinate = rng.chance(noLocationProbability)
                ? nil
                : jittered(place, latitude: 0.08, longitude: 0.12, rng: &rng)
            photos.append(PhotoDraft(
                date: date,
                coordinate: coordinate,
                perceptualHash: rng.next(),
                truthTrip: nil,
                truthStack: nil
            ))
        }
        return photos
    }

    private static func tripPhotos(
        _ rng: inout SeededRandom,
        at place: GeoPoint,
        day: Int,
        trip: String,
        noLocationProbability: Double = 0.05
    ) -> [PhotoDraft] {
        let count = rng.int(in: 5...25)
        var photos: [PhotoDraft] = []
        for _ in 0..<count {
            let date = timeOfDay(day: day, rng: &rng)
            let coordinate = rng.chance(noLocationProbability)
                ? nil
                : jittered(place, latitude: 0.05, longitude: 0.07, rng: &rng)
            photos.append(PhotoDraft(
                date: date,
                coordinate: coordinate,
                perceptualHash: rng.next(),
                truthTrip: trip,
                truthStack: nil
            ))
        }
        return photos
    }

    private static func timeOfDay(day: Int, rng: inout SeededRandom) -> Date {
        let seconds = rng.double(in: 8 * 3_600..<22 * 3_600)
        return baseDate.addingTimeInterval(Double(day) * 86_400 + seconds)
    }

    private static func jittered(
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

    // MARK: - Bursts

    private static func addBursts(_ rng: inout SeededRandom, to drafts: inout [PhotoDraft]) {
        for index in 1...30 {
            let name = String(format: "burst-%02d", index)
            let count = rng.int(in: 3...8)
            var offsets: [TimeInterval] = [0]
            var cursor = 0.0
            for _ in 1..<count {
                cursor += rng.double(in: 0.3..<2.0)
                offsets.append(cursor)
            }
            let start = freeStart(&rng, days: 0..<90, offsets: offsets, photos: drafts)
            let baseHash = rng.next()
            for offset in offsets {
                var hash = baseHash
                let flips = rng.int(in: 0...4)
                for _ in 0..<flips {
                    let bit = rng.int(in: 0...63)
                    hash ^= UInt64(1) << UInt64(bit)
                }
                let coordinate = jittered(berlin, latitude: 0.08, longitude: 0.12, rng: &rng)
                drafts.append(PhotoDraft(
                    date: start.addingTimeInterval(offset),
                    coordinate: coordinate,
                    perceptualHash: hash,
                    truthTrip: nil,
                    truthStack: name
                ))
            }
        }
    }

    private static func addQuickPairs(_ rng: inout SeededRandom, to drafts: inout [PhotoDraft]) {
        let offsets: [TimeInterval] = [0, 2]
        for _ in 1...30 {
            let start = freeStart(&rng, days: 0..<90, offsets: offsets, photos: drafts)
            for offset in offsets {
                let coordinate = jittered(berlin, latitude: 0.08, longitude: 0.12, rng: &rng)
                drafts.append(PhotoDraft(
                    date: start.addingTimeInterval(offset),
                    coordinate: coordinate,
                    perceptualHash: rng.next(),
                    truthTrip: nil,
                    truthStack: nil
                ))
            }
        }
    }

    /// A start time with no existing photo within 60 s of any shot.
    private static func freeStart(
        _ rng: inout SeededRandom,
        days: Range<Int>,
        offsets: [TimeInterval],
        photos: [PhotoDraft]
    ) -> Date {
        while true {
            let day = rng.int(in: days.lowerBound...(days.upperBound - 1))
            let date = timeOfDay(day: day, rng: &rng)
            let occupied = photos.contains { photo in
                offsets.contains { offset in
                    abs(photo.date.timeIntervalSince(date.addingTimeInterval(offset))) < 60
                }
            }
            if !occupied { return date }
        }
    }

    // MARK: - Assembly

    /// Sorts by date (then by the order made) and assigns ids.
    private static func scenario(name: String, drafts: [PhotoDraft]) -> SyntheticScenario {
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

    // MARK: - Cities

    private static let berlin = GeoPoint(latitude: 52.52, longitude: 13.40)
    private static let dresden = GeoPoint(latitude: 51.05, longitude: 13.74)
    private static let rome = GeoPoint(latitude: 41.90, longitude: 12.50)
    private static let florence = GeoPoint(latitude: 43.77, longitude: 11.26)
    private static let venice = GeoPoint(latitude: 45.44, longitude: 12.32)
    private static let potsdam = GeoPoint(latitude: 52.40, longitude: 13.06)
    private static let paris = GeoPoint(latitude: 48.85, longitude: 2.35)
    private static let london = GeoPoint(latitude: 51.51, longitude: -0.13)
    private static let lisbon = GeoPoint(latitude: 38.72, longitude: -9.14)
    private static let munich = GeoPoint(latitude: 48.14, longitude: 11.58)
    private static let vienna = GeoPoint(latitude: 48.21, longitude: 16.37)
    private static let tokyo = GeoPoint(latitude: 35.68, longitude: 139.70)
    private static let auckland = GeoPoint(latitude: -36.85, longitude: 174.76)
    private static let suva = GeoPoint(latitude: -18.14, longitude: 178.44)
    private static let taveuni = GeoPoint(latitude: -16.85, longitude: -179.97)
    private static let hamburg = GeoPoint(latitude: 53.55, longitude: 9.99)
    private static let prague = GeoPoint(latitude: 50.08, longitude: 14.44)
}

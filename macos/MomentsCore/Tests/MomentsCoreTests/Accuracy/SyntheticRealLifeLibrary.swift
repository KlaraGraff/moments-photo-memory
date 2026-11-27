import Foundation
@testable import MomentsCore

/// What a real phone library holds that the exam libraries leave out.
enum RealLifeIngredient: String, CaseIterable {
    /// Few photos at home: most days at home have none.
    case sparseHome = "sparse-home"
    /// Away from home on about half of the photo days.
    case heavyTraveler = "heavy-traveler"
    /// Two trips with one to three photo-less days at home between them.
    case backToBack = "back-to-back"
    /// Trips 60–250 km from home, the ones a weekend allows.
    case nearbyTrips = "nearby-trips"
    /// Day trips 60–200 km away, out and back the same day.
    case dayTrips = "day-trips"
    /// Home far from UTC, so local days and UTC days differ.
    case farFromUTC = "far-from-utc"
    /// One trip through countries far apart, with a travel day without photos
    /// between the legs.
    case longLegs = "long-legs"
    /// One trip with two or three days without photos in the middle, as on a
    /// cruise or a family visit.
    case quietTripDays = "quiet-trip-days"
}

/// A randomized year of a phone library, built from everyday habits: the
/// truth trips are the stretches spent more than 60 km from home.
struct SyntheticRealLifeLibrary {
    let scenario: SyntheticScenario
    let ingredients: Set<RealLifeIngredient>
}

extension SyntheticLibrary {
    /// `count` libraries named `life-<seed>-<nn>`.
    static func realLifeLibraries(seed: UInt64, count: Int = 40) -> [SyntheticRealLifeLibrary] {
        (0..<count).map { (index: Int) -> SyntheticRealLifeLibrary in
            var builder = RealLifeBuilder(seed: seed &* 7_919 &+ UInt64(index) &+ 3)
            return builder.build(name: "life-" + String(seed) + "-" + String(format: "%02d", index))
        }
    }
}

private struct RealLifeBuilder {
    private struct Day {
        var place: GeoPoint
        var trip: String?
        /// Photos that day; 0 for a day without photos.
        var photos: Int
    }

    private static let dayCount = 365
    private static let homes: [GeoPoint] = [
        GeoPoint(latitude: 31.23, longitude: 121.47),
        GeoPoint(latitude: 52.52, longitude: 13.40),
        GeoPoint(latitude: 33.57, longitude: -7.59),
        GeoPoint(latitude: 40.71, longitude: -74.01),
        GeoPoint(latitude: 37.77, longitude: -122.42),
        GeoPoint(latitude: 22.54, longitude: 114.06),
    ]

    private var rng: SeededRandom
    private var days: [Day]
    private var reserved: [Bool]
    private var ingredients = Set<RealLifeIngredient>()
    private let home: GeoPoint
    private let homePhotoDayChance: Double
    private let gpsLoss: Double
    /// Hours east of UTC.
    private let utcOffsetHours: Int
    private var tripNumber = 0

    init(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        let home = Self.homes[rng.int(in: 0...(Self.homes.count - 1))]
        let offsets = [8, 1, 0, -5, -8, 8]
        let offset = offsets[Self.homes.firstIndex(of: home) ?? 0]
        let sparse = rng.chance(0.4)
        self.homePhotoDayChance = sparse ? rng.double(in: 0.06..<0.2) : rng.double(in: 0.25..<0.7)
        self.gpsLoss = rng.double(in: 0.0..<0.15)
        self.home = home
        self.utcOffsetHours = offset
        self.rng = rng
        self.days = []
        self.reserved = Array(repeating: false, count: Self.dayCount)
        for _ in 0..<Self.dayCount {
            let photos = self.rng.chance(homePhotoDayChance) ? self.rng.int(in: 1...6) : 0
            days.append(Day(place: home, trip: nil, photos: photos))
        }
        if sparse { ingredients.insert(.sparseHome) }
        if abs(offset) >= 5 { ingredients.insert(.farFromUTC) }
    }

    mutating func build(name: String) -> SyntheticRealLifeLibrary {
        if rng.chance(0.25) {
            ingredients.insert(.heavyTraveler)
            var tries = 0
            while awayShare() < 0.45 && tries < 200 {
                tries += 1
                placeTrip(length: rng.int(in: 3...12), km: 300...6_000)
            }
        }
        if rng.chance(0.4) {
            ingredients.insert(.backToBack)
            for _ in 0..<rng.int(in: 1...2) { placeBackToBack() }
        }
        if rng.chance(0.5) {
            ingredients.insert(.nearbyTrips)
            for _ in 0..<rng.int(in: 2...5) { placeTrip(length: rng.int(in: 2...3), km: 60...250) }
        }
        if rng.chance(0.4) {
            ingredients.insert(.dayTrips)
            for _ in 0..<rng.int(in: 2...4) { placeTrip(length: 1, km: 60...200) }
        }
        if rng.chance(0.35) {
            ingredients.insert(.longLegs)
            placeLongLegs()
        }
        if rng.chance(0.35) {
            ingredients.insert(.quietTripDays)
            placeQuietTrip()
        }
        for _ in 0..<rng.int(in: 1...4) { placeTrip(length: rng.int(in: 3...14), km: 300...9_000) }
        return SyntheticRealLifeLibrary(scenario: makeScenario(name: name), ingredients: ingredients)
    }

    private func awayShare() -> Double {
        let photoDays = days.filter { $0.photos > 0 }
        guard !photoDays.isEmpty else { return 0 }
        return Double(photoDays.filter { $0.trip != nil }.count) / Double(photoDays.count)
    }

    private mutating func placeBackToBack() {
        let first = rng.int(in: 2...5)
        let between = rng.int(in: 1...3)
        let second = rng.int(in: 2...5)
        guard let start = takeWindow(length: first + between + second) else { return }
        let firstPlace = destination(km: 150...1_500)
        // The second trip goes elsewhere, as near to the first as the way home is.
        let secondPlace = destination(km: 150...1_500)
        fill(start: start, length: first, places: [firstPlace])
        for day in (start + first)..<(start + first + between) {
            days[day].photos = 0
        }
        fill(start: start + first + between, length: second, places: [secondPlace])
    }

    private mutating func placeLongLegs() {
        let legs = rng.int(in: 2...3)
        let legDays = (0..<legs).map { _ in rng.int(in: 2...4) }
        let length = legDays.reduce(0, +) + legs - 1
        guard let start = takeWindow(length: length) else { return }
        tripNumber += 1
        let name = String(format: "trip-%02d", tripNumber)
        var place = destination(km: 800...6_000)
        var day = start
        for (index, count) in legDays.enumerated() {
            if index > 0 {
                // The travel day: no photos, then the next country.
                days[day] = Day(place: place, trip: name, photos: 0)
                day += 1
                place = Self.offset(place, km: rng.double(in: 1_000..<5_000), bearing: rng.double(in: 0..<360))
                if place.distance(to: home) < 300_000 { place = Self.offset(home, km: 2_000, bearing: rng.double(in: 0..<360)) }
            }
            for _ in 0..<count {
                days[day] = Day(place: place, trip: name, photos: rng.int(in: 3...20))
                day += 1
            }
        }
    }

    private mutating func placeQuietTrip() {
        let before = rng.int(in: 2...4)
        let quiet = rng.int(in: 2...3)
        let after = rng.int(in: 2...4)
        guard let start = takeWindow(length: before + quiet + after) else { return }
        tripNumber += 1
        let name = String(format: "trip-%02d", tripNumber)
        let first = destination(km: 400...6_000)
        // The quiet days end at the same place or a port a little further on.
        let second = rng.chance(0.5) ? first : Self.offset(first, km: rng.double(in: 100..<500), bearing: rng.double(in: 0..<360))
        for offset in 0..<(before + quiet + after) {
            let photos = offset < before || offset >= before + quiet ? rng.int(in: 3...20) : 0
            days[start + offset] = Day(place: offset < before + quiet ? first : second, trip: name, photos: photos)
        }
    }

    private mutating func placeTrip(length: Int, km: ClosedRange<Double>) {
        guard let start = takeWindow(length: length) else { return }
        let legs = length >= 4 ? rng.int(in: 1...3) : 1
        var places = [destination(km: km)]
        while places.count < legs {
            places.append(Self.offset(places[places.count - 1], km: rng.double(in: 80..<400), bearing: rng.double(in: 0..<360)))
        }
        fill(start: start, length: length, places: places)
    }

    private mutating func fill(start: Int, length: Int, places: [GeoPoint]) {
        tripNumber += 1
        let name = String(format: "trip-%02d", tripNumber)
        for offset in 0..<length {
            let leg = min(places.count - 1, offset * places.count / max(1, length))
            let photos: Int
            if length == 1 {
                photos = rng.int(in: 6...15)
            } else {
                photos = rng.chance(0.85) || offset == 0 || offset == length - 1 ? rng.int(in: 3...20) : 0
            }
            days[start + offset] = Day(place: places[leg], trip: name, photos: photos)
        }
    }

    private mutating func takeWindow(length: Int) -> Int? {
        var starts: [Int] = []
        for start in 2...(Self.dayCount - length - 2) {
            let range = (start - 1)...(start + length)
            if range.allSatisfy({ !reserved[$0] }) { starts.append(start) }
        }
        guard !starts.isEmpty else { return nil }
        let start = starts[rng.int(in: 0...(starts.count - 1))]
        for day in start..<(start + length) { reserved[day] = true }
        return start
    }

    private mutating func destination(km: ClosedRange<Double>) -> GeoPoint {
        Self.offset(home, km: rng.double(in: km.lowerBound..<km.upperBound), bearing: rng.double(in: 0..<360))
    }

    private static func offset(_ point: GeoPoint, km: Double, bearing: Double) -> GeoPoint {
        let radians = bearing * .pi / 180
        let latitude = point.latitude + km / 111.0 * cos(radians)
        let scale = max(0.2, cos(point.latitude * .pi / 180))
        var longitude = point.longitude + km / (111.0 * scale) * sin(radians)
        if longitude > 180 { longitude -= 360 }
        if longitude < -180 { longitude += 360 }
        return GeoPoint(latitude: max(-80, min(80, latitude)), longitude: longitude)
    }

    private mutating func makeScenario(name: String) -> SyntheticScenario {
        var photos: [(date: Date, coordinate: GeoPoint?, trip: String?)] = []
        for (index, day) in days.enumerated() where day.photos > 0 {
            for _ in 0..<day.photos {
                // Local 07:00 to 00:30, a few after midnight.
                let localSeconds = rng.double(in: 7 * 3_600..<(24.5 * 3_600))
                let utc = Double(index) * 86_400 + localSeconds - Double(utcOffsetHours) * 3_600
                let spread = day.trip == nil ? 0.08 : 0.05
                let coordinate: GeoPoint? = rng.chance(gpsLoss) ? nil : GeoPoint(
                    latitude: day.place.latitude + rng.double(in: -spread..<spread),
                    longitude: day.place.longitude + rng.double(in: -spread..<spread)
                )
                photos.append((SyntheticLibrary.baseDate.addingTimeInterval(utc), coordinate, day.trip))
            }
        }
        photos.sort { $0.date < $1.date }
        let made = photos.enumerated().map { (index, photo) in
            SyntheticPhoto(
                id: String(format: "%@-%05d", name, index),
                date: photo.date,
                coordinate: photo.coordinate,
                perceptualHash: rng.next(),
                truthTrip: photo.trip,
                truthStack: nil
            )
        }
        return SyntheticScenario(name: name, photos: made)
    }
}

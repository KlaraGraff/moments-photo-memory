import Foundation
@testable import MomentsCore

/// One randomized exam library: the photos a route sees, the home the year was
/// built around, and which ingredients went into it (for the self-check and
/// the report). The truth lives in `placeScenario`, in the same shape as the
/// E1 place catalogue.
struct SyntheticExamLibrary {
    let placeScenario: SyntheticPlaceScenario
    let home: GeoPoint
    let ingredients: Set<ExamIngredient>
    /// A library without any truth trip is an explicit quiet year.
    let isQuietYear: Bool

    /// The home days placed inside a truth trip (layovers), and the days that
    /// hold a GPS-less burst. Both are recorded exactly, so the self-check
    /// does not have to guess them from the photos.
    let homeLayoverDays: [Int]
    let gpslessBurstDays: [Int]
    /// The long stay's day window (start and length), when the library has one.
    let longStayWindow: (start: Int, length: Int)?
    /// The slow travel's day window (start and length), when it has one.
    let slowTravelWindow: (start: Int, length: Int)?
    /// The long stay's city and the frequent place's city, when present.
    let longStayCity: GeoPoint?
    let frequentPlaceCity: GeoPoint?
    /// The library's daily photo-day probability and GPS-loss probability,
    /// for the run report.
    let dailyDayProbability: Double
    let gpsLossProbability: Double

    var scenario: SyntheticScenario { placeScenario.scenario }
    var frequentGroups: [[String]] { placeScenario.frequentGroups }
}

/// The ingredients the exam mixes. A library holds each one with the
/// probability the package asks for; the names are stable for the report.
enum ExamIngredient: String, CaseIterable {
    case normalTrip = "normal-trip"
    case frequentPlace = "frequent-place"
    case frequentPlaceTwoVisits = "frequent-place-two-visits"
    case roadTripThroughFrequentPlace = "road-trip-through-frequent-place"
    case longFarTrip = "long-far-trip"
    case longStay = "long-stay"
    case longStayOuting = "long-stay-outing"
    case slowTravel = "slow-travel"
    case homeDayLayover = "home-day-layover"
    case gpslessBurst = "gpsless-burst"

    /// The ingredients that must produce a truth trip. A library with none of
    /// them is a quiet year.
    static let tripIngredients: Set<ExamIngredient> = [
        .normalTrip,
        .frequentPlace,
        .frequentPlaceTwoVisits,
        .longFarTrip,
        .slowTravel,
        .longStayOuting,
    ]
}

extension SyntheticLibrary {
    /// Forty randomized libraries with known answers, named `exam-<seed>-<nn>`.
    /// The truth follows only the owner's rules (see the exam report).
    static func examScenarios(seed: UInt64) -> [SyntheticPlaceScenario] {
        examLibraries(seed: seed).map { (library: SyntheticExamLibrary) -> SyntheticPlaceScenario in
            library.placeScenario
        }
    }

    /// The same forty libraries with their ingredient tags, for the self-check
    /// and the run report.
    static func examLibraries(seed: UInt64) -> [SyntheticExamLibrary] {
        (0..<40).map { (index: Int) -> SyntheticExamLibrary in
            examLibrary(seed: seed, index: index)
        }
    }

    private static func examLibrary(seed: UInt64, index: Int) -> SyntheticExamLibrary {
        let librarySeed: UInt64 = seed &* 1_000 &+ UInt64(index) &+ 17
        var builder = ExamBuilder(seed: librarySeed)
        builder.placeLongStay()
        builder.placeSlowTravel()
        builder.placeLongFarTrip()
        builder.placeFrequentPlace()
        builder.placeRoadTripThroughFrequentPlace()
        builder.placeNormalTrips()
        builder.placeHomeDayLayover()
        builder.placeGPSlessBurst()
        let name = "exam-" + String(seed) + "-" + String(format: "%02d", index)
        return builder.finish(name: name)
    }
}

// MARK: - Day plans

/// What one day of the year holds before the photos are made.
private struct ExamDayPlan {
    let place: GeoPoint
    let trip: String?
    var rule: ExamPhotoRule
    /// The photos of a GPS-less burst day keep their location, so the only
    /// photos without one that day are exactly the burst.
    var gpsLossFree: Bool
    var gpslessBurst: Int

    init(
        place: GeoPoint,
        trip: String?,
        rule: ExamPhotoRule,
        gpsLossFree: Bool = false,
        gpslessBurst: Int = 0
    ) {
        self.place = place
        self.trip = trip
        self.rule = rule
        self.gpsLossFree = gpsLossFree
        self.gpslessBurst = gpslessBurst
    }
}

private enum ExamPhotoRule: Equatable {
    /// Home daily life: a photo day with the library's own probability, 1–8 photos.
    case daily
    /// A pinned home day (layover, GPS-less burst day): always a photo day, 2–6 photos.
    case homeAlways
    /// A day of a truth trip: always a photo day, 3–16 photos.
    case tripDay
    /// A day of a long stay (living there): 1–4 photos on a photo day.
    case longStay(photoDay: Bool)
    /// A day of slow travel: 8–20 photos on a photo day.
    case slowTravel(photoDay: Bool)
}

/// One photo before the scenario sorts it and gives it an id.
private struct ExamDraft {
    let date: Date
    let coordinate: GeoPoint?
    let perceptualHash: UInt64
    let truthTrip: String?
    let truthStack: String?
}

/// One truth trip placed in the year, for the layover and burst ingredients.
private struct ExamTripWindow {
    let name: String
    let start: Int
    let length: Int
}

// MARK: - Builder

/// Builds one exam year. Each ingredient has its own `place…` function; they
/// all reserve their days through `takeWindow`, so ingredients never overlap.
private struct ExamBuilder {
    private static let dayCount = 365

    private var rng: SeededRandom
    private let home: GeoPoint
    private let dailyDayProbability: Double
    private let gpsLossProbability: Double
    private var plans: [ExamDayPlan]
    private var reserved: [Bool]
    private var ingredients: Set<ExamIngredient> = []
    private var frequentGroups: [[String]] = []
    private var frequentPlaceCity: GeoPoint?
    private var tripWindows: [ExamTripWindow] = []
    private var normalTripWindows: [ExamTripWindow] = []
    private var homeLayoverDays: [Int] = []
    private var gpslessBurstDays: [Int] = []
    private var longStayWindow: (start: Int, length: Int)?
    private var slowTravelWindow: (start: Int, length: Int)?
    private var longStayCity: GeoPoint?
    /// Far cities already used by an ingredient. A city is visited by one
    /// ingredient only, so a second trip can never turn a place into an
    /// accidental frequent place in the answer key.
    private var usedCities: Set<GeoPoint> = []
    /// The ingredient coins, drawn up front so each probability is exactly the
    /// one the package names and the order of ingredients cannot change it.
    private let wantsLongStay: Bool
    private let wantsSlowTravel: Bool
    private let wantsLongFarTrip: Bool
    private let wantsFrequentPlace: Bool
    private let wantsTwoVisitsOnly: Bool
    private let wantsRoadTripThroughFrequentPlace: Bool
    private let wantsLayover: Bool
    private let wantsGPSlessBurst: Bool

    init(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        let homes: [GeoPoint] = ExamCities.homes
        let home: GeoPoint = homes[rng.int(in: 0...(homes.count - 1))]
        let dailyDayProbability: Double = rng.double(in: 0.2..<0.8)
        let gpsLossProbability: Double = rng.double(in: 0.0..<0.3)
        self.rng = rng
        self.home = home
        self.dailyDayProbability = dailyDayProbability
        self.gpsLossProbability = gpsLossProbability
        self.wantsLongStay = rng.chance(0.2)
        self.wantsSlowTravel = rng.chance(0.15)
        self.wantsLongFarTrip = rng.chance(0.3)
        self.wantsFrequentPlace = rng.chance(0.4)
        self.wantsTwoVisitsOnly = rng.chance(0.25)
        self.wantsRoadTripThroughFrequentPlace = rng.chance(0.25)
        self.wantsLayover = rng.chance(0.3)
        self.wantsGPSlessBurst = rng.chance(0.3)
        self.plans = Array(repeating: ExamDayPlan(place: home, trip: nil, rule: .daily), count: Self.dayCount)
        self.reserved = Array(repeating: false, count: Self.dayCount)
    }

    // MARK: Long stay (living there)

    /// 60–120 days in one city more than 300 km away, weekday photo days rare
    /// and weekends common: daily life, not a trip. Outings from it are trips.
    mutating func placeLongStay() {
        guard wantsLongStay else { return }
        let length = rng.int(in: 60...120)
        guard let city = pickCity(around: home, km: 301...9_000) else { return }
        guard let start = takeWindow(length: length, margin: 3) else { return }
        for day in start..<(start + length) {
            plans[day] = ExamDayPlan(place: city, trip: nil, rule: .longStay(photoDay: false))
        }
        ingredients.insert(.longStay)
        longStayWindow = (start: start, length: length)
        longStayCity = city
        placeOutings(stayStart: start, stayLength: length, stayCity: city)
        // The photo days are set after the outings, so the weekday and weekend
        // rates are counted over the days actually spent at the stay city.
        let photoDays = longStayPhotoDays(start: start, length: length)
        for day in start..<(start + length) where plans[day].trip == nil {
            plans[day].rule = .longStay(photoDay: photoDays.contains(day))
        }
    }

    /// Weekdays stay under 25 % photo days, weekends above 60 %.
    private mutating func longStayPhotoDays(start: Int, length: Int) -> Set<Int> {
        var weekdays: [Int] = []
        var weekends: [Int] = []
        for day in start..<(start + length) where plans[day].trip == nil {
            if ExamCalendar.isWeekend(day) {
                weekends.append(day)
            } else {
                weekdays.append(day)
            }
        }
        let weekdayCount = Int((Double(weekdays.count) * 0.15).rounded(.down))
        let weekendCount = Int((Double(weekends.count) * 0.75).rounded(.up))
        var chosen = Set(pickDays(from: weekdays, count: weekdayCount))
        chosen.formUnion(pickDays(from: weekends, count: weekendCount))
        return chosen
    }

    /// One to three outings of two to four days, at least 150 km from the stay
    /// city; each outing is one truth trip.
    private mutating func placeOutings(stayStart: Int, stayLength: Int, stayCity: GeoPoint) {
        guard stayLength > 8 else { return }
        var taken = Array(repeating: false, count: stayLength)
        let outingCount = rng.int(in: 1...3)
        var made = 0
        for number in 1...outingCount {
            let outingLength = rng.int(in: 2...4)
            guard let offset = outingOffset(length: outingLength, taken: taken) else { break }
            guard let city = pickCityAway(fromHomeAnd: stayCity, stayKm: 150...2_000) else { break }
            for day in offset..<(offset + outingLength) {
                taken[day] = true
            }
            let name = String(format: "outing-%02d", number)
            for day in offset..<(offset + outingLength) {
                plans[stayStart + day] = ExamDayPlan(place: city, trip: name, rule: .tripDay)
            }
            tripWindows.append(ExamTripWindow(name: name, start: stayStart + offset, length: outingLength))
            made += 1
        }
        if made > 0 {
            ingredients.insert(.longStayOuting)
        }
    }

    private mutating func outingOffset(length: Int, taken: [Bool]) -> Int? {
        guard taken.count >= length + 3 else { return nil }
        var candidates: [Int] = []
        for offset in 1...(taken.count - length - 1) {
            let lower = max(0, offset - 2)
            let upper = min(taken.count - 1, offset + length + 1)
            var blocked = false
            for day in lower...upper where taken[day] {
                blocked = true
            }
            if !blocked {
                candidates.append(offset)
            }
        }
        guard !candidates.isEmpty else { return nil }
        return candidates[rng.int(in: 0...(candidates.count - 1))]
    }

    // MARK: Slow travel

    /// 60–120 days in one city, a photo on more than 80 % of the days with
    /// 8–20 photos each: one truth trip for the whole stay.
    mutating func placeSlowTravel() {
        guard wantsSlowTravel else { return }
        let length = rng.int(in: 60...120)
        guard let city = pickCity(around: home, km: 300...9_000) else { return }
        guard let start = takeWindow(length: length, margin: 3) else { return }
        let skipCount = max(1, length / 10)
        // The first and last day always have photos, so the trip's own day span
        // is the stay length.
        let skipped = Set(pickDays(from: Array(1..<(length - 1)), count: skipCount))
        for offset in 0..<length {
            let rule = ExamPhotoRule.slowTravel(photoDay: !skipped.contains(offset))
            plans[start + offset] = ExamDayPlan(place: city, trip: "slow-travel", rule: rule)
        }
        tripWindows.append(ExamTripWindow(name: "slow-travel", start: start, length: length))
        slowTravelWindow = (start: start, length: length)
        ingredients.insert(.slowTravel)
    }

    // MARK: Long far trip

    /// 30–60 days away, moving through two or three cities first and then
    /// staying in one city: one truth trip for all of it.
    mutating func placeLongFarTrip() {
        guard wantsLongFarTrip else { return }
        let length = rng.int(in: 30...60)
        let legCount = rng.int(in: 2...3)
        let cities = pickCities(around: home, km: 300...9_000, count: legCount + 1)
        guard cities.count == legCount + 1 else { return }
        guard let start = takeWindow(length: length, margin: 3) else { return }
        var day = start
        var legIndex = 0
        var budget = min(length - 20, rng.int(in: 5...12))
        while budget >= 2 && legIndex < legCount {
            let days = min(budget, rng.int(in: 2...4))
            for offset in 0..<days {
                plans[day + offset] = ExamDayPlan(place: cities[legIndex], trip: "long-far", rule: .tripDay)
            }
            day += days
            budget -= days
            legIndex += 1
        }
        while day < start + length {
            plans[day] = ExamDayPlan(place: cities[legIndex], trip: "long-far", rule: .tripDay)
            day += 1
        }
        tripWindows.append(ExamTripWindow(name: "long-far", start: start, length: length))
        ingredients.insert(.longFarTrip)
    }

    // MARK: Frequent place

    /// A place 120–400 km from home visited three to six separate times; each
    /// visit is a truth trip and the visits together are one frequent group.
    /// With p=0.25 the place gets exactly two visits and no group.
    mutating func placeFrequentPlace() {
        guard wantsFrequentPlace else { return }
        guard let city = pickCity(around: home, km: 120...400) else { return }
        let visitCount = wantsTwoVisitsOnly ? 2 : rng.int(in: 3...6)
        let lengths: [Int] = (1...visitCount).map { (_: Int) -> Int in rng.int(in: 3...7) }
        guard let visits = placeVisits(city: city, lengths: lengths) else { return }
        frequentPlaceCity = city
        let orderedNames: [String] = visits.sorted {
            (left: ExamTripWindow, right: ExamTripWindow) -> Bool in left.start < right.start
        }.map { (visit: ExamTripWindow) -> String in visit.name }
        // The truth follows the visits that really fit: three or more separate
        // visits are one frequent group, two are the counterexample, one is a
        // single ordinary trip. Two visits are drawn with p=0.25 of the
        // frequent-place libraries; when a full year leaves no room for all of
        // them the whole ingredient is dropped (see `placeVisits`).
        if orderedNames.count >= 3 {
            frequentGroups = [orderedNames]
            ingredients.insert(.frequentPlace)
        } else if orderedNames.count == 2 {
            ingredients.insert(.frequentPlaceTwoVisits)
        }
    }

    /// Places every visit of a frequent place; leaves the year untouched when
    /// the visits do not all fit, so an ingredient is either complete or absent.
    private mutating func placeVisits(city: GeoPoint, lengths: [Int]) -> [ExamTripWindow]? {
        let savedPlans = plans
        let savedReserved = reserved
        let savedWindows = tripWindows
        for _ in 0..<6 {
            var visits: [ExamTripWindow] = []
            var failed = false
            for (index, length) in lengths.enumerated() {
                guard let start = takeWindow(length: length, margin: 3) else {
                    failed = true
                    break
                }
                let name = String(format: "frequent-%02d", index + 1)
                for day in start..<(start + length) {
                    plans[day] = ExamDayPlan(place: city, trip: name, rule: .tripDay)
                }
                visits.append(ExamTripWindow(name: name, start: start, length: length))
            }
            if !failed && visits.count == lengths.count {
                tripWindows += visits
                return visits
            }
            plans = savedPlans
            reserved = savedReserved
            tripWindows = savedWindows
        }
        return nil
    }

    /// A road trip with one night at the frequent place. The night is part of
    /// the road trip, not a separate visit to the frequent place.
    mutating func placeRoadTripThroughFrequentPlace() {
        guard let place = frequentPlaceCity, wantsRoadTripThroughFrequentPlace else { return }
        let nearPlace = candidates(around: place, km: 50...1_500)
        let awayFromHome = nearPlace.filter { (city: GeoPoint) -> Bool in
            home.distance(to: city) > 100_000 && !usedCities.contains(city)
        }
        let companions = pickMany(from: awayFromHome, count: 2)
        guard companions.count == 2 else { return }
        usedCities.formUnion(companions)
        let length = rng.int(in: 5...8)
        guard let start = takeWindow(length: length, margin: 3) else { return }
        var day = start
        for _ in 0..<2 {
            plans[day] = ExamDayPlan(place: companions[0], trip: "road-trip", rule: .tripDay)
            day += 1
        }
        plans[day] = ExamDayPlan(place: place, trip: "road-trip", rule: .tripDay)
        day += 1
        while day < start + length {
            plans[day] = ExamDayPlan(place: companions[1], trip: "road-trip", rule: .tripDay)
            day += 1
        }
        tripWindows.append(ExamTripWindow(name: "road-trip", start: start, length: length))
        ingredients.insert(.roadTripThroughFrequentPlace)
    }

    // MARK: Normal trips

    /// Zero to three trips of two to fourteen days, 300–9,000 km away, with
    /// one to three cities; each trip is one truth trip.
    mutating func placeNormalTrips() {
        let count = rng.int(in: 0...3)
        guard count > 0 else { return }
        var made = 0
        for number in 1...count {
            let length = rng.int(in: 2...14)
            let cityCount = min(rng.int(in: 1...3), length)
            let cities = pickCities(around: home, km: 300...9_000, count: cityCount)
            guard cities.count == cityCount else { continue }
            guard let start = takeWindow(length: length, margin: 3) else { continue }
            let name = String(format: "trip-%02d", number)
            placeLegs(cities: cities, length: length, start: start, trip: name)
            let window = ExamTripWindow(name: name, start: start, length: length)
            normalTripWindows.append(window)
            tripWindows.append(window)
            made += 1
        }
        if made > 0 {
            ingredients.insert(.normalTrip)
        }
    }

    private mutating func placeLegs(cities: [GeoPoint], length: Int, start: Int, trip: String) {
        var remaining = length
        var day = start
        for (index, city) in cities.enumerated() {
            let citiesLeft = cities.count - index
            let days = max(1, remaining / citiesLeft)
            for offset in 0..<days {
                plans[day + offset] = ExamDayPlan(place: city, trip: trip, rule: .tripDay)
            }
            day += days
            remaining -= days
        }
    }

    // MARK: Layover and GPS-less burst

    /// One home day inside a normal trip of eight days or more: the trip stays
    /// one truth trip and the home-day photos are daily life.
    mutating func placeHomeDayLayover() {
        guard wantsLayover else { return }
        let eligible = normalTripWindows.filter { (window: ExamTripWindow) -> Bool in
            window.length >= 8
        }
        guard !eligible.isEmpty else { return }
        let window = eligible[rng.int(in: 0...(eligible.count - 1))]
        let offset = rng.int(in: 1...(window.length - 2))
        let day = window.start + offset
        plans[day] = ExamDayPlan(place: home, trip: nil, rule: .homeAlways)
        homeLayoverDays.append(day)
        ingredients.insert(.homeDayLayover)
    }

    /// One burst of one to four photos without a location on a home day one
    /// to three days after a trip; the burst is daily life.
    mutating func placeGPSlessBurst() {
        guard wantsGPSlessBurst else { return }
        var candidates: [Int] = []
        for window in tripWindows {
            let end = window.start + window.length - 1
            for offset in 1...3 {
                let day = end + offset
                guard day < Self.dayCount else { continue }
                let plan = plans[day]
                if plan.trip == nil && plan.place == home && plan.rule == .daily {
                    candidates.append(day)
                }
            }
        }
        guard !candidates.isEmpty else { return }
        let day = candidates[rng.int(in: 0...(candidates.count - 1))]
        plans[day] = ExamDayPlan(
            place: home,
            trip: nil,
            rule: .homeAlways,
            gpsLossFree: true,
            gpslessBurst: rng.int(in: 1...4)
        )
        gpslessBurstDays.append(day)
        ingredients.insert(.gpslessBurst)
    }

    // MARK: Photos

    mutating func finish(name: String) -> SyntheticExamLibrary {
        var drafts: [ExamDraft] = []
        for day in 0..<Self.dayCount {
            drafts += photos(for: plans[day], day: day)
        }
        let scenario = Self.assemble(name: name, drafts: drafts)
        let placeScenario = SyntheticPlaceScenario(scenario: scenario, frequentGroups: frequentGroups)
        // A quiet year is a year no trip ingredient was placed in. It is set
        // from the ingredients, not from the photos, so the self-check can
        // catch a placed ingredient that produced no truth trip.
        let tripIngredients: Set<ExamIngredient> = [
            .normalTrip,
            .frequentPlace,
            .frequentPlaceTwoVisits,
            .longFarTrip,
            .slowTravel,
            .longStayOuting,
        ]
        return SyntheticExamLibrary(
            placeScenario: placeScenario,
            home: home,
            ingredients: ingredients,
            isQuietYear: ingredients.isDisjoint(with: tripIngredients),
            homeLayoverDays: homeLayoverDays,
            gpslessBurstDays: gpslessBurstDays,
            longStayWindow: longStayWindow,
            slowTravelWindow: slowTravelWindow,
            longStayCity: longStayCity,
            frequentPlaceCity: frequentPlaceCity,
            dailyDayProbability: dailyDayProbability,
            gpsLossProbability: gpsLossProbability
        )
    }


    private mutating func photos(for plan: ExamDayPlan, day: Int) -> [ExamDraft] {
        var drafts: [ExamDraft] = []
        let count = photoCount(for: plan.rule)
        if count > 0 {
            drafts += locatedPhotos(count: count, plan: plan, day: day)
        }
        if plan.gpslessBurst > 0 {
            drafts += burstPhotos(count: plan.gpslessBurst, day: day)
        }
        return drafts
    }

    private mutating func photoCount(for rule: ExamPhotoRule) -> Int {
        switch rule {
        case .daily:
            return rng.chance(dailyDayProbability) ? rng.int(in: 1...8) : 0
        case .homeAlways:
            return rng.int(in: 2...6)
        case .tripDay:
            return rng.int(in: 3...16)
        case .longStay(let photoDay):
            return photoDay ? rng.int(in: 1...4) : 0
        case .slowTravel(let photoDay):
            return photoDay ? rng.int(in: 8...20) : 0
        }
    }

    /// Photos around the day's place. Every photo can lose its location, but a
    /// day never ends up without one located photo, so its truth is anchored.
    private mutating func locatedPhotos(count: Int, plan: ExamDayPlan, day: Int) -> [ExamDraft] {
        var coordinates: [GeoPoint?] = []
        coordinates.reserveCapacity(count)
        for _ in 0..<count {
            let losesGPS: Bool = !plan.gpsLossFree && rng.chance(gpsLossProbability)
            coordinates.append(losesGPS ? nil : jittered(plan.place))
        }
        if coordinates.allSatisfy({ (coordinate: GeoPoint?) -> Bool in coordinate == nil }) {
            coordinates[0] = jittered(plan.place)
        }
        var drafts: [ExamDraft] = []
        for coordinate in coordinates {
            drafts.append(ExamDraft(
                date: timeOfDay(day: day),
                coordinate: coordinate,
                perceptualHash: rng.next(),
                truthTrip: plan.trip,
                truthStack: nil
            ))
        }
        return drafts
    }

    /// A tight burst of photos without a location, all on the same day.
    private mutating func burstPhotos(count: Int, day: Int) -> [ExamDraft] {
        let start = timeOfDay(day: day)
        var drafts: [ExamDraft] = []
        var offset = 0.0
        for _ in 0..<count {
            drafts.append(ExamDraft(
                date: start.addingTimeInterval(offset),
                coordinate: nil,
                perceptualHash: rng.next(),
                truthTrip: nil,
                truthStack: nil
            ))
            offset += rng.double(in: 0.3..<2.0)
        }
        return drafts
    }

    private mutating func timeOfDay(day: Int) -> Date {
        let seconds = rng.double(in: 28_800.0..<79_200.0)
        return SyntheticLibrary.baseDate.addingTimeInterval(Double(day) * 86_400 + seconds)
    }

    private mutating func jittered(_ place: GeoPoint) -> GeoPoint {
        let latitude = rng.double(in: -0.05..<0.05)
        let longitude = rng.double(in: -0.07..<0.07)
        return GeoPoint(latitude: place.latitude + latitude, longitude: place.longitude + longitude)
    }

    // MARK: Placement helpers

    /// A free run of days, with a margin of untouched days on both sides, then
    /// marks the run as used.
    private mutating func takeWindow(length: Int, margin: Int) -> Int? {
        guard length > 0, length <= Self.dayCount else { return nil }
        var starts: [Int] = []
        for start in 0...(Self.dayCount - length) where isFree(start: start, length: length, margin: margin) {
            starts.append(start)
        }
        guard !starts.isEmpty else { return nil }
        let start = starts[rng.int(in: 0...(starts.count - 1))]
        for day in start..<(start + length) {
            reserved[day] = true
        }
        return start
    }

    private func isFree(start: Int, length: Int, margin: Int) -> Bool {
        let lower = max(0, start - margin)
        let upper = min(Self.dayCount - 1, start + length - 1 + margin)
        for day in lower...upper where reserved[day] {
            return false
        }
        return true
    }

    private func candidates(around origin: GeoPoint, km: ClosedRange<Double>) -> [GeoPoint] {
        ExamCities.all.filter { (city: GeoPoint) -> Bool in
            let distance = origin.distance(to: city) / 1_000
            return km.contains(distance)
        }
    }

    private mutating func pickCity(around origin: GeoPoint, km: ClosedRange<Double>) -> GeoPoint? {
        pickCities(around: origin, km: km, count: 1).first
    }

    /// A city at least `stayKm` from `origin` and more than 50 km from home:
    /// an outing is a trip, never a day back home.
    private mutating func pickCityAway(fromHomeAnd origin: GeoPoint, stayKm: ClosedRange<Double>) -> GeoPoint? {
        let unused = candidates(around: origin, km: stayKm).filter { (city: GeoPoint) -> Bool in
            !usedCities.contains(city) && home.distance(to: city) > 50_000
        }
        let picked = pickMany(from: unused, count: 1)
        usedCities.formUnion(picked)
        return picked.first
    }

    /// Far cities for a new ingredient: never one this library already used,
    /// so the answer key cannot grow an accidental frequent place.
    private mutating func pickCities(around origin: GeoPoint, km: ClosedRange<Double>, count: Int) -> [GeoPoint] {
        let unused = candidates(around: origin, km: km).filter { (city: GeoPoint) -> Bool in
            !usedCities.contains(city)
        }
        let picked = pickMany(from: unused, count: count)
        usedCities.formUnion(picked)
        return picked
    }

    private mutating func pickMany(from values: [GeoPoint], count: Int) -> [GeoPoint] {
        var pool = values
        var picked: [GeoPoint] = []
        while picked.count < count && !pool.isEmpty {
            picked.append(pool.remove(at: rng.int(in: 0...(pool.count - 1))))
        }
        return picked
    }

    private mutating func pickDays(from days: [Int], count: Int) -> [Int] {
        var pool = days
        var picked: [Int] = []
        while picked.count < count && !pool.isEmpty {
            picked.append(pool.remove(at: rng.int(in: 0...(pool.count - 1))))
        }
        return picked
    }

    // MARK: Assembly

    /// Sorts by date (then by the order made) and assigns ids.
    private static func assemble(name: String, drafts: [ExamDraft]) -> SyntheticScenario {
        let ordered = drafts.enumerated().sorted {
            (left: (offset: Int, element: ExamDraft), right: (offset: Int, element: ExamDraft)) -> Bool in
            if left.element.date != right.element.date {
                return left.element.date < right.element.date
            }
            return left.offset < right.offset
        }
        let photos = ordered.enumerated().map {
            (index: Int, entry: (offset: Int, element: ExamDraft)) -> SyntheticPhoto in
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

// MARK: - Calendar

private enum ExamCalendar {
    /// The catalogue's base date is 2023-01-01, a Sunday, so day 0 is Sunday
    /// and day 6 is Saturday.
    static func isWeekend(_ day: Int) -> Bool {
        let weekday = day % 7
        return weekday == 0 || weekday == 6
    }
}

// MARK: - Places

/// Public city coordinates only; all exam data is synthetic.
private enum ExamCities {
    static let homes: [GeoPoint] = [
        GeoPoint(latitude: 52.52, longitude: 13.40),   // Berlin
        GeoPoint(latitude: 40.42, longitude: -3.70),   // Madrid
        GeoPoint(latitude: 41.88, longitude: -87.63),  // Chicago
        GeoPoint(latitude: 37.57, longitude: 126.98),  // Seoul
        GeoPoint(latitude: -33.87, longitude: 151.21), // Sydney
        GeoPoint(latitude: 43.65, longitude: -79.38),  // Toronto
    ]

    static let all: [GeoPoint] = [
        GeoPoint(latitude: 52.52, longitude: 13.40),
        GeoPoint(latitude: 40.42, longitude: -3.70),
        GeoPoint(latitude: 41.88, longitude: -87.63),
        GeoPoint(latitude: 37.57, longitude: 126.98),
        GeoPoint(latitude: -33.87, longitude: 151.21),
        GeoPoint(latitude: 43.65, longitude: -79.38),
        GeoPoint(latitude: 51.51, longitude: -0.13),
        GeoPoint(latitude: 48.85, longitude: 2.35),
        GeoPoint(latitude: 41.90, longitude: 12.50),
        GeoPoint(latitude: 43.77, longitude: 11.26),
        GeoPoint(latitude: 45.44, longitude: 12.32),
        GeoPoint(latitude: 45.46, longitude: 9.19),
        GeoPoint(latitude: 40.85, longitude: 14.27),
        GeoPoint(latitude: 41.38, longitude: 2.17),
        GeoPoint(latitude: 39.47, longitude: -0.38),
        GeoPoint(latitude: 37.39, longitude: -5.98),
        GeoPoint(latitude: 38.72, longitude: -9.14),
        GeoPoint(latitude: 41.15, longitude: -8.61),
        GeoPoint(latitude: 52.37, longitude: 4.90),
        GeoPoint(latitude: 50.85, longitude: 4.35),
        GeoPoint(latitude: 55.68, longitude: 12.57),
        GeoPoint(latitude: 59.33, longitude: 18.07),
        GeoPoint(latitude: 59.91, longitude: 10.75),
        GeoPoint(latitude: 60.17, longitude: 24.94),
        GeoPoint(latitude: 64.15, longitude: -21.94),
        GeoPoint(latitude: 53.35, longitude: -6.26),
        GeoPoint(latitude: 55.95, longitude: -3.19),
        GeoPoint(latitude: 48.21, longitude: 16.37),
        GeoPoint(latitude: 50.08, longitude: 14.44),
        GeoPoint(latitude: 47.50, longitude: 19.04),
        GeoPoint(latitude: 52.23, longitude: 21.01),
        GeoPoint(latitude: 50.06, longitude: 19.94),
        GeoPoint(latitude: 48.14, longitude: 11.58),
        GeoPoint(latitude: 53.55, longitude: 9.99),
        GeoPoint(latitude: 51.05, longitude: 13.74),
        GeoPoint(latitude: 51.34, longitude: 12.37),
        GeoPoint(latitude: 47.37, longitude: 8.54),
        GeoPoint(latitude: 46.20, longitude: 6.14),
        GeoPoint(latitude: 37.98, longitude: 23.73),
        GeoPoint(latitude: 41.01, longitude: 28.98),
        GeoPoint(latitude: 55.76, longitude: 37.62),
        GeoPoint(latitude: 50.45, longitude: 30.52),
        GeoPoint(latitude: 44.43, longitude: 26.10),
        GeoPoint(latitude: 42.70, longitude: 23.32),
        GeoPoint(latitude: 45.81, longitude: 15.98),
        GeoPoint(latitude: 46.06, longitude: 14.51),
        GeoPoint(latitude: 43.86, longitude: 18.41),
        GeoPoint(latitude: 44.79, longitude: 20.45),
        GeoPoint(latitude: 54.69, longitude: 25.28),
        GeoPoint(latitude: 56.95, longitude: 24.11),
        GeoPoint(latitude: 59.44, longitude: 24.75),
        GeoPoint(latitude: 31.63, longitude: -7.99),
        GeoPoint(latitude: 30.04, longitude: 31.24),
        GeoPoint(latitude: -33.92, longitude: 18.42),
        GeoPoint(latitude: -1.29, longitude: 36.82),
        GeoPoint(latitude: 6.52, longitude: 3.38),
        GeoPoint(latitude: 33.57, longitude: -7.59),
        GeoPoint(latitude: 36.81, longitude: 10.18),
        GeoPoint(latitude: 25.25, longitude: 55.36),
        GeoPoint(latitude: 24.45, longitude: 54.38),
        GeoPoint(latitude: 19.08, longitude: 72.88),
        GeoPoint(latitude: 28.61, longitude: 77.21),
        GeoPoint(latitude: 12.97, longitude: 77.59),
        GeoPoint(latitude: 13.76, longitude: 100.50),
        GeoPoint(latitude: 18.79, longitude: 98.99),
        GeoPoint(latitude: 1.35, longitude: 103.82),
        GeoPoint(latitude: 3.14, longitude: 101.69),
        GeoPoint(latitude: 22.32, longitude: 114.17),
        GeoPoint(latitude: 31.23, longitude: 121.47),
        GeoPoint(latitude: 39.90, longitude: 116.41),
        GeoPoint(latitude: 35.18, longitude: 129.08),
        GeoPoint(latitude: 35.68, longitude: 139.70),
        GeoPoint(latitude: 35.01, longitude: 135.77),
        GeoPoint(latitude: 34.69, longitude: 135.50),
        GeoPoint(latitude: 43.06, longitude: 141.35),
        GeoPoint(latitude: 25.03, longitude: 121.57),
        GeoPoint(latitude: 14.60, longitude: 120.98),
        GeoPoint(latitude: 40.71, longitude: -74.01),
        GeoPoint(latitude: 42.36, longitude: -71.06),
        GeoPoint(latitude: 38.91, longitude: -77.04),
        GeoPoint(latitude: 45.50, longitude: -73.57),
        GeoPoint(latitude: 49.28, longitude: -123.12),
        GeoPoint(latitude: 37.77, longitude: -122.42),
        GeoPoint(latitude: 34.05, longitude: -118.24),
        GeoPoint(latitude: 47.61, longitude: -122.33),
        GeoPoint(latitude: 39.74, longitude: -104.99),
        GeoPoint(latitude: 30.27, longitude: -97.74),
        GeoPoint(latitude: 25.76, longitude: -80.19),
        GeoPoint(latitude: 19.43, longitude: -99.13),
        GeoPoint(latitude: 23.11, longitude: -82.37),
        GeoPoint(latitude: 4.71, longitude: -74.07),
        GeoPoint(latitude: -12.05, longitude: -77.04),
        GeoPoint(latitude: -33.45, longitude: -70.67),
        GeoPoint(latitude: -34.60, longitude: -58.38),
        GeoPoint(latitude: -22.91, longitude: -43.17),
        GeoPoint(latitude: -23.55, longitude: -46.63),
        GeoPoint(latitude: -37.81, longitude: 144.96),
        GeoPoint(latitude: -27.47, longitude: 153.03),
        GeoPoint(latitude: -31.95, longitude: 115.86),
        GeoPoint(latitude: -36.85, longitude: 174.76),
        GeoPoint(latitude: -41.29, longitude: 174.78),
        GeoPoint(latitude: -35.28, longitude: 149.13),
        GeoPoint(latitude: -32.93, longitude: 151.78),
        // Cities around the six homes, 100–500 km out, so every home can
        // draw a frequent place in the 120–400 km band.
        // Berlin:
        GeoPoint(latitude: 52.12, longitude: 11.63),   // Magdeburg
        GeoPoint(latitude: 53.08, longitude: 8.80),    // Bremen
        GeoPoint(latitude: 50.98, longitude: 11.03),   // Erfurt
        GeoPoint(latitude: 51.23, longitude: 6.78),    // Düsseldorf
        GeoPoint(latitude: 52.26, longitude: 10.52),   // Braunschweig
        GeoPoint(latitude: 54.09, longitude: 12.10),   // Rostock
        GeoPoint(latitude: 53.43, longitude: 14.55),   // Szczecin
        GeoPoint(latitude: 52.41, longitude: 16.93),   // Poznań
        GeoPoint(latitude: 51.11, longitude: 17.03),   // Wrocław
        GeoPoint(latitude: 49.45, longitude: 11.08),   // Nuremberg
        GeoPoint(latitude: 50.11, longitude: 8.68),    // Frankfurt
        GeoPoint(latitude: 53.55, longitude: 10.00),   // Hamburg
        // Madrid:
        GeoPoint(latitude: 41.65, longitude: -4.72),   // Valladolid
        GeoPoint(latitude: 40.96, longitude: -5.66),   // Salamanca
        GeoPoint(latitude: 41.65, longitude: -0.88),   // Zaragoza
        GeoPoint(latitude: 39.86, longitude: -4.03),   // Toledo
        GeoPoint(latitude: 38.99, longitude: -1.86),   // Albacete
        GeoPoint(latitude: 42.34, longitude: -3.70),   // Burgos
        GeoPoint(latitude: 42.46, longitude: -2.45),   // Logroño
        GeoPoint(latitude: 39.47, longitude: -6.37),   // Cáceres
        GeoPoint(latitude: 42.60, longitude: -5.57),   // León
        GeoPoint(latitude: 37.99, longitude: -1.13),   // Murcia
        GeoPoint(latitude: 43.26, longitude: -2.93),   // Bilbao
        GeoPoint(latitude: 43.46, longitude: -3.81),   // Santander
        // Chicago:
        GeoPoint(latitude: 43.04, longitude: -87.91),  // Milwaukee
        GeoPoint(latitude: 43.07, longitude: -89.40),  // Madison
        GeoPoint(latitude: 39.77, longitude: -86.16),  // Indianapolis
        GeoPoint(latitude: 42.96, longitude: -85.67),  // Grand Rapids
        GeoPoint(latitude: 42.33, longitude: -83.05),  // Detroit
        GeoPoint(latitude: 41.88, longitude: -87.63),  // Chicago
        GeoPoint(latitude: 43.07, longitude: -89.40),  // Madison
        GeoPoint(latitude: 44.98, longitude: -93.27),  // Minneapolis
        GeoPoint(latitude: 39.10, longitude: -94.58),  // Kansas City
        GeoPoint(latitude: 38.63, longitude: -90.20),  // St. Louis
        GeoPoint(latitude: 41.26, longitude: -95.93),  // Omaha
        GeoPoint(latitude: 42.50, longitude: -90.66),  // Dubuque
        // Toronto:
        GeoPoint(latitude: 42.89, longitude: -78.88),  // Buffalo
        GeoPoint(latitude: 43.16, longitude: -77.61),  // Rochester
        GeoPoint(latitude: 43.05, longitude: -76.15),  // Syracuse
        GeoPoint(latitude: 45.42, longitude: -75.70),  // Ottawa
        GeoPoint(latitude: 42.99, longitude: -81.25),  // London, ON
        GeoPoint(latitude: 44.23, longitude: -76.49),  // Kingston
        GeoPoint(latitude: 43.65, longitude: -79.38),  // Toronto
        GeoPoint(latitude: 42.33, longitude: -83.05),  // Detroit
        GeoPoint(latitude: 40.44, longitude: -79.99),  // Pittsburgh
        GeoPoint(latitude: 42.65, longitude: -73.76),  // Albany
        GeoPoint(latitude: 45.50, longitude: -73.57),  // Montreal
        GeoPoint(latitude: 42.31, longitude: -83.18),  // Dearborn
        // Seoul:
        GeoPoint(latitude: 36.35, longitude: 127.38),  // Daejeon
        GeoPoint(latitude: 35.16, longitude: 126.85),  // Gwangju
        GeoPoint(latitude: 35.87, longitude: 128.60),  // Daegu
        GeoPoint(latitude: 35.18, longitude: 129.08),  // Busan
        GeoPoint(latitude: 35.82, longitude: 127.15),  // Jeonju
        GeoPoint(latitude: 37.75, longitude: 128.88),  // Gangneung
        GeoPoint(latitude: 35.54, longitude: 129.31),  // Ulsan
        GeoPoint(latitude: 36.02, longitude: 129.34),  // Pohang
        GeoPoint(latitude: 34.81, longitude: 126.39),  // Mokpo
        GeoPoint(latitude: 37.88, longitude: 127.73),  // Chuncheon
        GeoPoint(latitude: 36.64, longitude: 127.49),  // Cheongju
        GeoPoint(latitude: 35.23, longitude: 128.68),  // Changwon
        // Sydney:
        GeoPoint(latitude: -32.93, longitude: 151.78), // Newcastle
        GeoPoint(latitude: -34.42, longitude: 150.89), // Wollongong
        GeoPoint(latitude: -35.28, longitude: 149.13), // Canberra
        GeoPoint(latitude: -33.28, longitude: 149.10), // Orange
        GeoPoint(latitude: -33.42, longitude: 149.58), // Bathurst
        GeoPoint(latitude: -31.43, longitude: 152.91), // Port Macquarie
        GeoPoint(latitude: -35.11, longitude: 147.37), // Wagga Wagga
        GeoPoint(latitude: -33.87, longitude: 151.21), // Sydney
        GeoPoint(latitude: -32.25, longitude: 150.89), // Muswellbrook
        GeoPoint(latitude: -34.75, longitude: 149.72), // Goulburn
        GeoPoint(latitude: -33.02, longitude: 151.60), // Lake Macquarie
        GeoPoint(latitude: -34.90, longitude: 150.60), // Nowra
    ]
}

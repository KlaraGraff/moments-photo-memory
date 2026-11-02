import Foundation
import XCTest
@testable import MomentsCore

/// The hidden exam: forty randomized labelled libraries per seed, built from
/// the owner's rules only. This test asserts nothing about the scores; it
/// checks the answer key and prints a scoreboard so routes can be compared.
final class ExamScoreboardTests: XCTestCase {
    private static let seeds: [UInt64] = [1001, 1002, 1003]
    private static var didReportMissingFrequentPlaces = false

    // MARK: - Answer key

    func testExamAnswerKeyIsWellFormed() {
        for seed in Self.seeds {
            let libraries: [SyntheticExamLibrary] = SyntheticLibrary.examLibraries(seed: seed)
            XCTAssertEqual(libraries.count, 40, "exam-\(seed) library count")
            let expectedNames: [String] = (0..<40).map { (index: Int) -> String in
                "exam-" + String(seed) + "-" + String(format: "%02d", index)
            }
            XCTAssertEqual(
                libraries.map { (library: SyntheticExamLibrary) -> String in library.scenario.name },
                expectedNames,
                "exam-\(seed) names"
            )
            for library in libraries {
                examSelfCheck(library)
            }
        }

        // The ingredient table for the run report: how many of the 120
        // libraries contain each ingredient.
        let all: [SyntheticExamLibrary] = Self.seeds.flatMap { (seed: UInt64) -> [SyntheticExamLibrary] in
            SyntheticLibrary.examLibraries(seed: seed)
        }
        for ingredient in ExamIngredient.allCases {
            let count: Int = all.filter { (library: SyntheticExamLibrary) -> Bool in
                library.ingredients.contains(ingredient)
            }.count
            print("EXAM ingredient \(ingredient.rawValue) libraries=\(count) of \(all.count)")
        }
        let quiet: Int = all.filter { (library: SyntheticExamLibrary) -> Bool in library.isQuietYear }.count
        print("EXAM ingredient quiet-year libraries=\(quiet) of \(all.count)")
    }

    /// Every library has a truth trip or is an explicit quiet year, no two
    /// truth trips overlap in time, and frequent groups only name real trips.
    private func examSelfCheck(_ library: SyntheticExamLibrary) {
        let scenario: SyntheticScenario = library.scenario
        let name: String = scenario.name

        // 1. Truth trips: one group per name, and a quiet year is explicit.
        let tripNames: [String] = examTripNames(in: scenario)
        XCTAssertEqual(Set(tripNames).count, tripNames.count, "\(name) duplicate trip name")
        XCTAssertFalse(scenario.photos.isEmpty, "\(name) has no photos")
        XCTAssertEqual(
            library.isQuietYear,
            scenario.truthTrips.isEmpty,
            "\(name) quiet year must match the truth trips"
        )
        if library.isQuietYear {
            XCTAssertTrue(scenario.truthTrips.isEmpty, "\(name) quiet year has trips")
        } else {
            XCTAssertGreaterThanOrEqual(scenario.truthTrips.count, 1, "\(name) needs a truth trip")
        }
        for trip in scenario.truthTrips {
            XCTAssertFalse(trip.isEmpty, "\(name) an empty truth trip")
        }

        // 2. No two truth trips overlap in time (inclusive days).
        let ranges: [ExamTripRange] = scenario.truthTrips.compactMap {
            (trip: [String]) -> ExamTripRange? in
            let days: [Int] = trip.compactMap { (id: String) -> Int? in
                guard let photo: SyntheticPhoto = examPhoto(id: id, in: scenario) else { return nil }
                return examDay(of: photo.date)
            }
            guard let first: Int = days.min(), let last: Int = days.max() else { return nil }
            let tripName: String = examPhoto(id: trip[0], in: scenario)?.truthTrip ?? "?"
            return ExamTripRange(name: tripName, first: first, last: last)
        }
        for (index, left) in ranges.enumerated() {
            for right in ranges[(index + 1)...] {
                let overlaps: Bool = left.first <= right.last && right.first <= left.last
                XCTAssertFalse(overlaps, "\(name) \(left.name) overlaps \(right.name)")
            }
        }

        // 3. Frequent groups name only existing truth trips, three or more.
        let tripNameSet: Set<String> = Set(tripNames)
        for group in library.frequentGroups {
            XCTAssertGreaterThanOrEqual(group.count, 3, "\(name) a frequent group needs three visits")
            XCTAssertEqual(Set(group).count, group.count, "\(name) frequent group repeats a trip")
            XCTAssertTrue(tripNameSet.isSuperset(of: group), "\(name) frequent group names a missing trip")
        }
        let groupedNames: [String] = library.frequentGroups.flatMap { (group: [String]) -> [String] in group }
        XCTAssertEqual(Set(groupedNames).count, groupedNames.count, "\(name) a trip is in two frequent groups")

        // 4. Photos: unique ids, date order, and every photo inside the year.
        let ids: [String] = scenario.photos.map { (photo: SyntheticPhoto) -> String in photo.id }
        XCTAssertEqual(Set(ids).count, ids.count, "\(name) duplicate photo id")
        let dates: [Date] = scenario.photos.map { (photo: SyntheticPhoto) -> Date in photo.date }
        XCTAssertEqual(dates, dates.sorted(), "\(name) photos are not in date order")
        for day in dates.map({ (date: Date) -> Int in examDay(of: date) }) {
            XCTAssertTrue((0..<365).contains(day), "\(name) photo outside the year")
        }

        // 5. Every declared ingredient is really in the photos, and the
        // quiet-year flag agrees with the ingredients.
        XCTAssertEqual(
            library.isQuietYear,
            library.ingredients.isDisjoint(with: ExamIngredient.tripIngredients),
            "\(name) quiet year and trip ingredients disagree"
        )
        examCheckIngredients(library)
    }

    /// Checks each declared ingredient against the truth trips and the
    /// recorded layout, rule by rule.
    private func examCheckIngredients(_ library: SyntheticExamLibrary) {
        let scenario: SyntheticScenario = library.scenario
        let name: String = scenario.name
        let trips: [String] = examTripNames(in: scenario)
        let tripDaySets: [String: Set<Int>] = examTripDays(in: scenario)

        if library.ingredients.contains(.normalTrip) {
            XCTAssertTrue(trips.contains { (trip: String) -> Bool in trip.hasPrefix("trip-") }, "\(name) normal trip")
        }
        if library.ingredients.contains(.frequentPlace) || library.ingredients.contains(.frequentPlaceTwoVisits) {
            guard let place = library.frequentPlaceCity else {
                XCTFail("\(name) frequent place has no city")
                return
            }
            let km: Double = library.home.distance(to: place) / 1_000
            XCTAssertGreaterThan(km, 50, "\(name) frequent place is further than 50 km from home")
        }
        if library.ingredients.contains(.frequentPlace) {
            XCTAssertEqual(library.frequentGroups.count, 1, "\(name) one frequent group")
            let frequentTrips: [String] = trips.filter { (trip: String) -> Bool in trip.hasPrefix("frequent-") }
            XCTAssertEqual(library.frequentGroups.first, frequentTrips, "\(name) frequent group is every visit in date order")
        }
        if library.ingredients.contains(.frequentPlaceTwoVisits) {
            let visits: Int = trips.filter { (trip: String) -> Bool in trip.hasPrefix("frequent-") }.count
            XCTAssertEqual(visits, 2, "\(name) exactly two visits")
            XCTAssertTrue(library.frequentGroups.isEmpty, "\(name) two visits make no group")
        }
        if library.ingredients.contains(.roadTripThroughFrequentPlace) {
            XCTAssertTrue(trips.contains("road-trip"), "\(name) road trip")
        }
        if library.ingredients.contains(.longFarTrip) {
            XCTAssertTrue(trips.contains("long-far"), "\(name) long far trip")
            let span: Int = examSpan(tripDaySets["long-far"])
            XCTAssertTrue((30...60).contains(span), "\(name) long far trip is 30–60 days, was \(span)")
        }
        if library.ingredients.contains(.slowTravel) {
            guard let stay = library.slowTravelWindow else {
                XCTFail("\(name) slow travel has no window")
                return
            }
            XCTAssertTrue((60...120).contains(stay.length), "\(name) slow travel is 60–120 days")
        }
        if library.ingredients.contains(.longStayOuting) {
            let outings: [String] = trips.filter { (trip: String) -> Bool in trip.hasPrefix("outing-") }
            XCTAssertTrue((1...3).contains(outings.count), "\(name) one to three outings")
            for outing in outings {
                let days: Set<Int> = tripDaySets[outing] ?? []
                XCTAssertTrue((2...4).contains(days.count), "\(name) an outing is 2–4 days")
                XCTAssertTrue(examIsAway(trip: outing, library: library), "\(name) an outing is 150+ km from the stay and away from home")
            }
        }
        if library.ingredients.contains(.longStay) {
            guard let stay = library.longStayWindow else {
                XCTFail("\(name) long stay has no window")
                return
            }
            XCTAssertTrue((60...120).contains(stay.length), "\(name) long stay is 60–120 days")
            if let city = library.longStayCity {
                let km: Double = library.home.distance(to: city) / 1_000
                XCTAssertGreaterThan(km, 300, "\(name) long stay is more than 300 km from home")
            } else {
                XCTFail("\(name) long stay has no city")
            }
            examCheckLongStayRates(library, stay: stay)
        }
        for day in library.homeLayoverDays {
            let inTrip: Bool = tripDaySets.values.contains { (days: Set<Int>) -> Bool in
                guard let first: Int = days.min(), let last: Int = days.max() else { return false }
                return day > first && day < last && !days.contains(day)
            }
            XCTAssertTrue(inTrip, "\(name) layover day \(day) is inside a trip")
        }
        for day in library.gpslessBurstDays {
            let sameDay: [SyntheticPhoto] = scenario.photos.filter { (photo: SyntheticPhoto) -> Bool in
                examDay(of: photo.date) == day && photo.coordinate == nil && photo.truthTrip == nil
            }
            XCTAssertTrue((1...4).contains(sameDay.count), "\(name) GPS-less burst has 1–4 photos")
            let homePhotos: [SyntheticPhoto] = scenario.photos.filter { (photo: SyntheticPhoto) -> Bool in
                guard let coordinate: GeoPoint = photo.coordinate else { return false }
                return coordinate.distance(to: library.home) < 50_000
            }
            XCTAssertFalse(homePhotos.isEmpty, "\(name) the library has a home")
        }
    }

    /// The long stay's photo-day rates: weekdays stay rare, weekends common,
    /// and every photo day has 1–4 photos.
    private func examCheckLongStayRates(_ library: SyntheticExamLibrary, stay: (start: Int, length: Int)) {
        let name: String = library.scenario.name
        var photoDays: Set<Int> = []
        var weekdayDays: Set<Int> = []
        var weekendDays: Set<Int> = []
        var photosPerDay: [Int: Int] = [:]
        for day in stay.start..<(stay.start + stay.length) {
            let weekday: Int = (day % 7)
            if weekday == 0 || weekday == 6 {
                weekendDays.insert(day)
            } else {
                weekdayDays.insert(day)
            }
        }
        for photo in library.scenario.photos where photo.truthTrip == nil {
            let day: Int = examDay(of: photo.date)
            guard day >= stay.start && day < stay.start + stay.length else { continue }
            guard photo.coordinate != nil else { continue }
            photoDays.insert(day)
            photosPerDay[day, default: 0] += 1
        }
        let weekdayRate: Double = weekdayDays.isEmpty ? 0 : Double(photoDays.intersection(weekdayDays).count) / Double(weekdayDays.count)
        let weekendRate: Double = weekendDays.isEmpty ? 0 : Double(photoDays.intersection(weekendDays).count) / Double(weekendDays.count)
        XCTAssertLessThan(weekdayRate, 0.25, "\(name) long stay weekdays stay rare")
        XCTAssertGreaterThan(weekendRate, 0.6, "\(name) long stay weekends are common")
        for count in photosPerDay.values {
            XCTAssertTrue((1...4).contains(count), "\(name) long stay has 1–4 photos per photo day")
        }
    }

    /// Whether every located photo of the trip is 150+ km from the stay city
    /// and more than 50 km from home.
    private func examIsAway(trip: String, library: SyntheticExamLibrary) -> Bool {
        guard let stay = library.longStayCity else { return false }
        let photos: [SyntheticPhoto] = library.scenario.photos.filter { (photo: SyntheticPhoto) -> Bool in
            photo.truthTrip == trip
        }
        let located: [SyntheticPhoto] = photos.filter { (photo: SyntheticPhoto) -> Bool in photo.coordinate != nil }
        guard !located.isEmpty else { return false }
        return located.allSatisfy { (photo: SyntheticPhoto) -> Bool in
            guard let coordinate: GeoPoint = photo.coordinate else { return false }
            return coordinate.distance(to: stay) > 150_000 && coordinate.distance(to: library.home) > 50_000
        }
    }

    /// Inclusive span from the first to the last day in the set.
    private func examSpan(_ days: Set<Int>?) -> Int {
        guard let days, let first: Int = days.min(), let last: Int = days.max() else { return 0 }
        return last - first + 1
    }

    private func examTripDays(in scenario: SyntheticScenario) -> [String: Set<Int>] {
        var days: [String: Set<Int>] = [:]
        for photo in scenario.photos {
            guard let trip: String = photo.truthTrip else { continue }
            days[trip, default: []].insert(examDay(of: photo.date))
        }
        return days
    }

    private func examTripNames(in scenario: SyntheticScenario) -> [String] {
        var names: [String] = []
        for photo in scenario.photos {
            guard let trip: String = photo.truthTrip else { continue }
            if !names.contains(trip) { names.append(trip) }
        }
        return names
    }

    private func examPhoto(id: String, in scenario: SyntheticScenario) -> SyntheticPhoto? {
        scenario.photos.first { (photo: SyntheticPhoto) -> Bool in photo.id == id }
    }

    private func examDay(of date: Date) -> Int {
        Int((date.timeIntervalSince(SyntheticLibrary.baseDate) / 86_400).rounded(.down))
    }

    // MARK: - Scoreboard

    /// Prints, per seed, the mean trip pair F1, the mean trip-or-daily-life
    /// agreement and the mean frequent-place F1, the five worst libraries by
    /// agreement, and one total line. It asserts nothing about the scores.
    func testExamScoreboard() {
        var allTrip: [Double] = []
        var allAgreement: [Double] = []
        var allFrequent: [Double] = []

        for seed in Self.seeds {
            let libraries: [SyntheticExamLibrary] = SyntheticLibrary.examLibraries(seed: seed)
            var tripScores: [Double] = []
            var agreements: [Double] = []
            var frequentScores: [Double] = []
            var worst: [ExamWorstEntry] = []

            for library in libraries {
                let scenario: SyntheticScenario = library.scenario
                let ids: [String] = scenario.photos.map { (photo: SyntheticPhoto) -> String in photo.id }
                let stops: [PhotoStop] = scenario.photos.map { (photo: SyntheticPhoto) -> PhotoStop in photo.stop }
                let result: TripSegmenter.Result = TripSegmenter().segment(stops)
                let trips: [[String]] = result.trips
                let tripF1: Double = AccuracyScoring.pairwise(
                    predicted: trips,
                    truth: scenario.truthTrips,
                    universe: ids
                ).f1
                let agreement: Double = AccuracyScoring.membershipAgreement(
                    predicted: trips,
                    truth: scenario.truthTrips,
                    universe: ids
                )
                let predictedFrequent: [[String]] = examPredictedFrequentIDs(result: result, orderedStops: stops)
                let truthFrequent: [[String]] = library.placeScenario.truthFrequentPhotoGroups()
                let frequentF1: Double = AccuracyScoring.pairwise(
                    predicted: predictedFrequent,
                    truth: truthFrequent,
                    universe: ids
                ).f1

                tripScores.append(tripF1)
                agreements.append(agreement)
                frequentScores.append(frequentF1)
                worst.append(ExamWorstEntry(name: scenario.name, agreement: agreement, trips: tripF1))
            }

            let count: Double = Double(max(libraries.count, 1))
            let meanTrip: Double = tripScores.reduce(0, +) / count
            let meanAgreement: Double = agreements.reduce(0, +) / count
            let meanFrequent: Double = frequentScores.reduce(0, +) / count
            allTrip += tripScores
            allAgreement += agreements
            allFrequent += frequentScores

            print(String(
                format: "SCORE exam-%llu trips=%.4f agreement=%.4f frequent=%.4f",
                seed,
                meanTrip,
                meanAgreement,
                meanFrequent
            ))
            let orderedWorst: [ExamWorstEntry] = worst.sorted {
                (left: ExamWorstEntry, right: ExamWorstEntry) -> Bool in
                if left.agreement != right.agreement { return left.agreement < right.agreement }
                return left.name < right.name
            }
            for entry in orderedWorst.prefix(5) {
                print(String(
                    format: "SCORE worst exam-%llu %@ agreement=%.4f trips=%.4f",
                    seed,
                    entry.name,
                    entry.agreement,
                    entry.trips
                ))
            }
        }

        let totalCount: Double = Double(max(allTrip.count, 1))
        print(String(
            format: "SCORE exam total trips=%.4f agreement=%.4f frequent=%.4f",
            allTrip.reduce(0, +) / totalCount,
            allAgreement.reduce(0, +) / totalCount,
            allFrequent.reduce(0, +) / totalCount
        ))
    }

    /// The frequent places a route reports, read through `Mirror` so this test
    /// compiles with and without a `frequentPlaces` child on `Result`. The
    /// child holds photo indices; they are mapped back to ids in photo order.
    private func examPredictedFrequentIDs(result: TripSegmenter.Result, orderedStops: [PhotoStop]) -> [[String]] {
        let ordered: [PhotoStop] = orderedStops.sorted {
            (left: PhotoStop, right: PhotoStop) -> Bool in
            left.date == right.date ? left.id < right.id : left.date < right.date
        }
        var groups: [[Int]] = []
        var foundChild = false
        for child in Mirror(reflecting: result).children where child.label == "frequentPlaces" {
            foundChild = true
            if let indices: [[Int]] = child.value as? [[Int]] {
                groups = indices
            }
        }
        if !foundChild && !Self.didReportMissingFrequentPlaces {
            Self.didReportMissingFrequentPlaces = true
            print("EXAM frequentPlaces: Result has no such child, predicted frequent groups are empty")
        }
        let ids: [[String]] = groups.map { (group: [Int]) -> [String] in
            group.compactMap { (index: Int) -> String? in
                ordered.indices.contains(index) ? ordered[index].id : nil
            }
        }
        return ids
    }
}

/// One truth trip's inclusive day range, for the overlap check.
private struct ExamTripRange {
    let name: String
    let first: Int
    let last: Int
}

/// One library's score, for sorting the worst list.
private struct ExamWorstEntry {
    let name: String
    let agreement: Double
    let trips: Double
}

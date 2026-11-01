import Foundation
import MomentsCore
import XCTest
@testable import Moments

final class TimelineBuilderScaleTests: XCTestCase {
    func testFiveThousandPhotosBuildQuickly() {
        var generator = SeededGenerator(seed: 0x5EED_1234)
        let calendar = utcCalendar()

        // 36 made-up destinations spread over the world, 40 trips between them.
        let destinations: [(latitude: Double, longitude: Double)] = (0..<36).map { index in
            (
                latitude: -60 + Double(index) * 3.4,
                longitude: -170 + Double(index) * 9.4
            )
        }
        let tripDestination = (0..<40).map { $0 % destinations.count }
        let home = (latitude: 12.0, longitude: 20.0)

        var items: [TimelineItemSnapshot] = []
        items.reserveCapacity(5_000)
        for index in 0..<5_000 {
            let dayOffset = generator.int(900)
            let startOfDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_515_000_000))
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: startOfDay)!
            let date = day.addingTimeInterval(Double(generator.int(24 * 60)) * 60)

            let roll = generator.unit()
            var coordinate: (latitude: Double, longitude: Double)?
            if roll < 0.15 {
                coordinate = nil
            } else if roll < 0.75 {
                coordinate = (
                    home.latitude + generator.double(in: -0.15...0.15),
                    home.longitude + generator.double(in: -0.15...0.15)
                )
            } else {
                let destination = destinations[tripDestination[generator.int(40)]]
                coordinate = (
                    destination.latitude + generator.double(in: -0.3...0.3),
                    destination.longitude + generator.double(in: -0.3...0.3)
                )
            }

            let placeHint = generator.unit() < 0.5 ? "Spot \(generator.int(500))" : nil
            items.append(
                TimelineItemSnapshot(
                    id: "photo-\(index)",
                    title: "Photo \(index)",
                    date: date,
                    latitude: coordinate?.latitude,
                    longitude: coordinate?.longitude,
                    kindRaw: MediaKind.photo.rawValue,
                    tripID: nil,
                    placeHint: placeHint,
                    memories: [],
                    dayKey: nil
                )
            )
        }

        let started = Date()
        let document = TimelineBuilder(calendar: calendar).build(items: items, trips: [])
        let seconds = Date().timeIntervalSince(started)
        print("5,000-photo build took \(seconds) seconds")

        XCTAssertLessThan(seconds, 5)
        XCTAssertEqual(
            document.trips.flatMap(\.days).flatMap(\.places).map(\.photoCount).reduce(0, +),
            5_000
        )
    }

    func testClusterNameUsesTheFirstStopWithAHint() {
        let items = [
            snapshot("one", date: date("2025-04-01T09:00:00Z"), latitude: 10, longitude: 10, place: nil),
            snapshot("two", date: date("2025-04-01T09:30:00Z"), latitude: 10, longitude: 10, place: ""),
            snapshot("three", date: date("2025-04-01T10:00:00Z"), latitude: 10, longitude: 10, place: "Harbour")
        ]

        let document = TimelineBuilder(calendar: utcCalendar()).build(items: items, trips: [])
        let places = document.trips.flatMap(\.days).flatMap(\.places)

        XCTAssertEqual(places.count, 1, "Three photos at one spot on one day are one place")
        XCTAssertEqual(places.first?.name, "Harbour", "The first stop with a non-empty hint names the place")
    }

    func testTravelEventPointsAtThePlaceWhereTheMoveEnds() {
        let items = [
            snapshot("a-1", date: date("2025-05-01T09:00:00Z"), latitude: 48, longitude: 0, place: "A"),
            snapshot("a-2", date: date("2025-05-01T10:00:00Z"), latitude: 48, longitude: 0, place: "A"),
            snapshot("b-1", date: date("2025-05-02T09:00:00Z"), latitude: 48, longitude: 4, place: "B"),
            snapshot("b-2", date: date("2025-05-02T10:00:00Z"), latitude: 48, longitude: 4, place: "B")
        ]
        let trip = TimelineSourceTrip(id: "trip", name: "Trip", itemIDs: items.map(\.id))

        let document = TimelineBuilder(calendar: utcCalendar()).build(items: items, trips: [trip])
        let events = document.trips[0].days.flatMap(\.events)
        let travels = events.filter {
            if case .travel = $0 { return true }
            return false
        }

        XCTAssertEqual(travels.count, 1, "One city move gives one travel row")
        guard case let .travel(travel) = travels[0] else {
            return XCTFail("Expected a travel event")
        }
        XCTAssertEqual(travel.fromName, "A")
        XCTAssertEqual(travel.toName, "B")

        let lastDay = document.trips[0].days.last
        XCTAssertEqual(lastDay?.events.count, 2, "The travel row plus the place it ends at")
        XCTAssertTrue(lastDay?.events.first?.id == travel.id, "The travel row comes before the destination place")
        guard case let .place(destination) = lastDay?.events.last else {
            return XCTFail("Expected the destination place after the travel row")
        }
        XCTAssertEqual(destination.name, "B")
        XCTAssertTrue(destination.itemIDs.contains("b-1"), "The travel row points at the place holding the arrival photo")
    }

    private func snapshot(
        _ id: String,
        date: Date?,
        latitude: Double? = nil,
        longitude: Double? = nil,
        place: String? = nil
    ) -> TimelineItemSnapshot {
        TimelineItemSnapshot(
            id: id,
            date: date,
            latitude: latitude,
            longitude: longitude,
            placeHint: place
        )
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)!
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
}

/// A tiny deterministic generator so the scale test uses the same photos on every run.
private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// A number in `0..<1`.
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func int(_ upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }
}

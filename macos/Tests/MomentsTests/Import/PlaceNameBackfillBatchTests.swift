import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// Names each synthetic place after its rounded latitude and counts lookups.
/// No network: the answer is computed from the coordinate.
private actor BatchNamingGeocoder: ImportGeocoder {
    private(set) var calls = 0

    func reverseGeocode(coordinate: GeoPoint) async throws -> ImportGeocodeResult {
        calls += 1
        let index: Int = Int(coordinate.latitude.rounded())
        return ImportGeocodeResult(city: "City \(index)", area: "Area \(index)", timeZoneIdentifier: "Europe/Berlin")
    }
}

/// Answers the first `successes` lookups and fails every later one, like a
/// geocoder that goes offline in the middle of a run.
private actor FailingAfterGeocoder: ImportGeocoder {
    private let successes: Int
    private(set) var calls = 0

    init(successes: Int) {
        self.successes = successes
    }

    func reverseGeocode(coordinate: GeoPoint) async throws -> ImportGeocodeResult {
        calls += 1
        guard calls <= successes else { throw URLError(.notConnectedToInternet) }
        let index: Int = Int(coordinate.latitude.rounded())
        return ImportGeocodeResult(city: "City \(index)", area: "Area \(index)", timeZoneIdentifier: "Europe/Berlin")
    }
}

/// Holds the run's task so the geocoder can cancel it, which a test cannot do
/// from inside the run itself.
private final class RunHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Int, Error>?

    func set(_ task: Task<Int, Error>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    /// Cancels the run and says whether a task was there to cancel yet: the
    /// geocoder may reach its limit before the test has stored the handle.
    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        return task != nil
    }
}

/// Cancels the run once more than `cancelAfter` lookups happened, like a
/// scheduler that stops the backfill when an import starts.
private actor CancellingGeocoder: ImportGeocoder {
    private let cancelAfter: Int
    private let holder: RunHolder
    private(set) var calls = 0

    init(cancelAfter: Int, holder: RunHolder) {
        self.cancelAfter = cancelAfter
        self.holder = holder
    }

    func reverseGeocode(coordinate: GeoPoint) async throws -> ImportGeocodeResult {
        calls += 1
        if calls > cancelAfter {
            // Wait for the test to hand its task over, then cancel it.
            for _ in 0..<1_000 {
                if holder.cancel() { break }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        try Task.checkCancellation()
        let index: Int = Int(coordinate.latitude.rounded())
        return ImportGeocodeResult(city: "City \(index)", area: "Area \(index)", timeZoneIdentifier: "Europe/Berlin")
    }
}

/// A clock the test drives: every read moves time on by `step`.
private final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private let step: Duration
    private var ticks = 0

    init(step: Duration) {
        self.step = step
    }

    func next() -> ContinuousClock.Instant {
        lock.lock()
        ticks += 1
        let passed: Duration = step * ticks
        lock.unlock()
        return ContinuousClock.now + passed
    }
}

/// Counts the saves of one container. Every context in the process posts
/// `didSave`, including contexts of other containers (each test builds its
/// own), so only saves to this container count.
private final class SaveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    private let observer: NSObjectProtocol?

    init(container: ModelContainer) {
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            guard let saved = notification.object as? ModelContext else { return }
            guard saved.container === container else { return }
            self.lock.lock()
            self.storage += 1
            self.lock.unlock()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Saves used to move the whole page state once per named city, which made a
/// long backfill rebuild Chapters and Timeline dozens of times. They now arrive
/// in batches of at most `saveInterval`.
final class PlaceNameBackfillBatchTests: XCTestCase {
    func testALongIntervalSavesInBatchesInsteadOfOncePerCity() async throws {
        let perCityContainer: ModelContainer = try MomentsPersistence.makeContainer(inMemory: true)
        try seedCities(in: perCityContainer, count: 25)
        let perCityCounter = SaveCounter(container: perCityContainer)
        let perCityGeocoder = BatchNamingGeocoder()
        let perCityNamed: Int = try await runBackfill(
            container: perCityContainer,
            geocoder: perCityGeocoder,
            saveInterval: .zero,
            clock: { ContinuousClock.now }
        )
        let perCitySaves: Int = perCityCounter.count
        let perCityNames: [String] = try cityNames(in: perCityContainer)

        let batchedContainer: ModelContainer = try MomentsPersistence.makeContainer(inMemory: true)
        try seedCities(in: batchedContainer, count: 25)
        let batchedCounter = SaveCounter(container: batchedContainer)
        let batchedGeocoder = BatchNamingGeocoder()
        let batchedNamed: Int = try await runBackfill(
            container: batchedContainer,
            geocoder: batchedGeocoder,
            saveInterval: .seconds(3_600),
            clock: { ContinuousClock.now }
        )
        let batchedSaves: Int = batchedCounter.count
        let batchedNames: [String] = try cityNames(in: batchedContainer)

        XCTAssertEqual(perCityNamed, 25)
        XCTAssertEqual(batchedNamed, 25)
        XCTAssertGreaterThanOrEqual(perCitySaves, 25, "Old behaviour: one save per named city")
        XCTAssertLessThanOrEqual(
            batchedSaves,
            perCitySaves - 20,
            "A three-quarter-hour interval must not save per city: \(batchedSaves) vs \(perCitySaves)"
        )
        XCTAssertEqual(perCityNames.count, 25)
        XCTAssertEqual(batchedNames.count, 25)
        XCTAssertTrue(perCityNames.allSatisfy { !$0.isEmpty }, "Unnamed: \(perCityNames.filter(\.isEmpty))")
        XCTAssertTrue(batchedNames.allSatisfy { !$0.isEmpty }, "Unnamed: \(batchedNames.filter(\.isEmpty))")
    }

    func testAClockThatPassesTheIntervalSavesSomeCities() async throws {
        let container: ModelContainer = try MomentsPersistence.makeContainer(inMemory: true)
        try seedCities(in: container, count: 25)
        let counter = SaveCounter(container: container)
        let clock = StepClock(step: .seconds(4))
        let named: Int = try await runBackfill(
            container: container,
            geocoder: BatchNamingGeocoder(),
            saveInterval: .seconds(10),
            clock: { clock.next() }
        )
        let saves: Int = counter.count
        let names: [String] = try cityNames(in: container)

        XCTAssertEqual(named, 25)
        XCTAssertGreaterThan(saves, 0, "Some batch must reach the store")
        XCTAssertLessThan(saves, 25, "Four seconds a city against ten must not save each city")
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty }, "Unnamed: \(names.filter(\.isEmpty))")
    }

    func testCancellationKeepsTheNamesAlreadyApplied() async throws {
        let container: ModelContainer = try MomentsPersistence.makeContainer(inMemory: true)
        try seedCities(in: container, count: 25)
        let holder = RunHolder()
        let geocoder = CancellingGeocoder(cancelAfter: 5, holder: holder)
        let backfill = PlaceNameBackfill(geocoder: geocoder, geocodeCache: ImportGeocodeCache(), pace: {})
        let task = Task { try await backfill.run(container: container) }
        holder.set(task)

        do {
            _ = try await task.value
            XCTFail("A cancelled run must throw")
        } catch is CancellationError {
            // Expected: the run stops and keeps what it named.
        }
        let names: [String] = try cityNames(in: container)
        let kept: Int = names.filter { $0.hasPrefix("City ") }.count
        XCTAssertGreaterThanOrEqual(kept, 4, "A fresh context must see the cities named before the cancel: \(names)")
    }

    func testTheCitiesNamedBeforeRepeatedFailuresAreSaved() async throws {
        let container: ModelContainer = try MomentsPersistence.makeContainer(inMemory: true)
        try seedCities(in: container, count: 25)
        let geocoder = FailingAfterGeocoder(successes: 3)
        let named: Int = try await runBackfill(
            container: container,
            geocoder: geocoder,
            saveInterval: .seconds(3_600),
            clock: { ContinuousClock.now },
            maxConsecutiveFailures: 3
        )
        let names: [String] = try cityNames(in: container)
        let stored: Int = names.filter { $0.hasPrefix("City ") }.count

        XCTAssertEqual(named, 3)
        XCTAssertEqual(stored, 3, "The three named cities must reach the store: \(names)")
    }

    // MARK: - Helpers

    private func runBackfill(
        container: ModelContainer,
        geocoder: any ImportGeocoder,
        saveInterval: Duration,
        clock: @escaping @Sendable () -> ContinuousClock.Instant,
        maxConsecutiveFailures: Int = 3
    ) async throws -> Int {
        let backfill = PlaceNameBackfill(
            geocoder: geocoder,
            geocodeCache: ImportGeocodeCache(),
            pace: {},
            maxConsecutiveFailures: maxConsecutiveFailures,
            saveInterval: saveInterval,
            clock: clock
        )
        return try await backfill.run(container: container)
    }

    /// `count` unnamed synthetic cities, one far enough from the next that each
    /// gets its own lookup.
    private func seedCities(in container: ModelContainer, count: Int) throws {
        let context = ModelContext(container)
        for index in 0..<count {
            let city = Place(
                id: "batch-city-\(index)",
                name: "",
                kind: .city,
                latitude: Double(index) + 1,
                longitude: 20
            )
            context.insert(city)
        }
        try context.save()
    }

    /// Read through a fresh context, so only saved names are visible.
    private func cityNames(in container: ModelContainer) throws -> [String] {
        let city = PlaceKind.city.rawValue
        let descriptor = FetchDescriptor<Place>(predicate: #Predicate { $0.kindRaw == city })
        return try ModelContext(container).fetch(descriptor).map(\.name)
    }
}

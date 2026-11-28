import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// The Library's regroup off the main thread (`LibraryRegroupEngine` on
/// `LibraryPhotoFacts`) must give what the main-thread pass gives
/// (`LibraryFilterEngine.regroupPasses` and `sections` on the models), and
/// `LibraryPhotoFactsCache` must read again only the photos that changed.
/// All data is synthetic.
@MainActor
final class LibraryRegroupEngineTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 86_400

    /// Kept for the length of a test, so its main context stays valid.
    private var container: ModelContainer?

    private func makeContext() throws -> ModelContext {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    private struct Fixture {
        let all: [MediaItem]
        let regular: [MediaItem]
        let screenshots: [MediaItem]
        let places: [Place]
        let trips: [Trip]
        let personIDsByMediaID: [String: Set<String>]
        let stackIndex: PhotoStackIndex
    }

    /// 60 synthetic photos over three months: screenshots, videos,
    /// favorites, memories, two chapters, a place tree with a renamed
    /// place, corrections on single photos, a few photos without a date,
    /// people and one burst.
    private func makeFixture(context: ModelContext) throws -> Fixture {
        let city = Place(id: "city-1", name: "Synthetic Town", kind: .city)
        let area = Place(id: "area-1", name: "Synthetic Area", kind: .area, parent: city)
        let spot = Place(id: "spot-1", name: "Spot abc123", kind: .spot, parent: area)
        let other = Place(id: "spot-2", name: "Synthetic Beach", kind: .spot)
        let places: [Place] = [city, area, spot, other]
        for place in places { context.insert(place) }
        context.insert(PlaceOverride(placeID: other.id, nameOverride: "Renamed Beach", place: other))

        let first = Trip(id: "trip-1", name: "Synthetic Trip")
        let second = Trip(id: "trip-2", name: "Second Trip")
        context.insert(first)
        context.insert(second)

        var all: [MediaItem] = []
        var regular: [MediaItem] = []
        var screenshots: [MediaItem] = []
        var people: [String: Set<String>] = [:]
        for index in 0..<60 {
            let isScreenshot: Bool = index % 9 == 0
            let kind: MediaKind = index % 5 == 0 ? .video : .photo
            let date: Date? = index % 17 == 4 ? nil : base.addingTimeInterval(Double(index) * day * 1.5)
            let place: Place? = [spot, area, other, nil, city][index % 5]
            let trip: Trip? = (10..<18).contains(index) ? first : ((30..<34).contains(index) ? second : nil)
            let item = MediaItem(
                id: "photo-\(index)",
                captureDate: date,
                kind: kind,
                isScreenshot: isScreenshot,
                place: place,
                trip: trip
            )
            context.insert(item)
            all.append(item)
            if isScreenshot { screenshots.append(item) } else { regular.append(item) }
            if index % 4 == 1 { people[item.id, default: []].insert("person-a") }
            if index % 6 == 2 { people[item.id, default: []].insert("person-b") }
        }
        for index in stride(from: 0, to: 60, by: 3) {
            all[index].setFavorite(true, context: context)
        }
        for index in [1, 9, 12, 19, 28, 37, 44, 51] {
            context.insert(Memory(text: "Synthetic memory \(index)", mediaItem: all[index]))
        }
        for (index, name) in [(7, "Edited place"), (23, "  Family lunch  "), (41, "Synthetic Town")] {
            context.insert(PlaceOverride(mediaID: all[index].id, nameOverride: name, mediaItem: all[index]))
        }
        try context.save()

        let stack = PhotoStack(id: "stack-1", memberIDs: ["photo-20", "photo-21", "photo-22"], coverID: "photo-21", isCoverChosen: false)
        return Fixture(
            all: all,
            regular: regular,
            screenshots: screenshots,
            places: places,
            trips: [first, second],
            personIDsByMediaID: people,
            stackIndex: PhotoStackIndex([stack])
        )
    }

    private func engineInput(
        _ fixture: Fixture,
        scope: Set<String>? = nil,
        criteria: LibraryFilterCriteria,
        editingItemID: String? = nil,
        searchMatches: Set<String>? = nil
    ) -> LibraryRegroupEngine.Input {
        let formatter: DateFormatter = LibraryRegroupEngine.makeMonthFormatter()
        var places: [String: LibraryPlaceFacts] = [:]
        for place in fixture.places { places[place.id] = LibraryPlaceFacts(place: place) }
        var tripNames: [String: String] = [:]
        for trip in fixture.trips { tripNames[trip.id] = trip.effectiveName }
        return LibraryRegroupEngine.Input(
            items: fixture.regular.map { LibraryPhotoFacts(item: $0, monthFormatter: formatter) },
            screenshots: fixture.screenshots.map { LibraryPhotoFacts(item: $0, monthFormatter: formatter) },
            scopeIDs: scope,
            criteria: criteria,
            editingItemID: editingItemID,
            personIDsByMediaID: fixture.personIDsByMediaID,
            searchMatches: searchMatches,
            places: places,
            tripNames: tripNames,
            stackIndex: fixture.stackIndex,
            calendar: .current
        )
    }

    /// The engine against the main-thread pass on the same photos.
    private func assertSameAsMainThread(
        _ fixture: Fixture,
        scope: Set<String>? = nil,
        criteria: LibraryFilterCriteria,
        editingItemID: String? = nil,
        searchMatches: Set<String>? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // The page hands over its regular photos, also for the Screenshots
        // segment; the screenshots only count for the maps then.
        let scopedItems: [MediaItem] = scope.map { scope in fixture.regular.filter { scope.contains($0.id) } } ?? fixture.regular
        let passes = LibraryFilterEngine.regroupPasses(
            scopedItems: scopedItems,
            allItems: fixture.all,
            hasScope: scope != nil,
            criteria: criteria,
            editingItemID: editingItemID,
            personIDsByMediaID: fixture.personIDsByMediaID,
            searchMatches: searchMatches
        )
        let oldSections: [LibrarySection] = LibraryFilterEngine.sections(forVisibleItems: passes.visible, by: .story, sortOrder: .newestFirst)
        let oldFolded = LibraryFilterEngine.folding(oldSections, with: fixture.stackIndex)

        let input: LibraryRegroupEngine.Input = engineInput(fixture, scope: scope, criteria: criteria, editingItemID: editingItemID, searchMatches: searchMatches)
        let output = LibraryRegroupEngine.run(input)

        XCTAssertEqual(output.filteredIDs, Set(passes.filtered.map(\.id)), "filtered differs", file: file, line: line)
        XCTAssertEqual(output.visibleIDs, passes.visible.map(\.id), "visible differs", file: file, line: line)
        XCTAssertEqual(output.publishedIDs, passes.publishedIDs, "published differs", file: file, line: line)
        XCTAssertEqual(output.unfolded, oldSections, "sections differ", file: file, line: line)
        XCTAssertEqual(output.sections, oldFolded.sections, "folded sections differ", file: file, line: line)
        XCTAssertEqual(output.stackCounts, oldFolded.stackCounts, "stack counts differ", file: file, line: line)
    }

    // MARK: Same result as the main-thread pass

    func testNoFilter() throws {
        let fixture = try makeFixture(context: try makeContext())
        assertSameAsMainThread(fixture, criteria: .default)
        let output = LibraryRegroupEngine.run(engineInput(fixture, criteria: .default))
        XCTAssertTrue(output.sections.contains { $0.id == "trip:trip-1" })
        XCTAssertTrue(output.sections.contains { $0.id == "month:unknown" })
        XCTAssertEqual(output.stackCounts["photo-21"], 3)
    }

    func testFavoritesVideosAndScreenshots() throws {
        let fixture = try makeFixture(context: try makeContext())
        assertSameAsMainThread(fixture, criteria: LibraryFilterCriteria(mediaType: .favorite))
        assertSameAsMainThread(fixture, criteria: LibraryFilterCriteria(mediaType: .video))
        assertSameAsMainThread(fixture, criteria: LibraryFilterCriteria(mediaType: .screenshot))
    }

    func testScope() throws {
        let fixture = try makeFixture(context: try makeContext())
        let scope = Set(fixture.regular.prefix(15).map(\.id))
        assertSameAsMainThread(fixture, scope: scope, criteria: .default)
        assertSameAsMainThread(fixture, scope: scope, criteria: LibraryFilterCriteria(mediaType: .favorite))
    }

    func testMemoryFiltersKeepThePhotoBeingEdited() throws {
        let fixture = try makeFixture(context: try makeContext())
        var hasMemory = LibraryFilterCriteria()
        hasMemory.memoryFilter = .hasMemory
        assertSameAsMainThread(fixture, criteria: hasMemory)
        // "photo-3" has no memory, so only editing it keeps it.
        assertSameAsMainThread(fixture, criteria: hasMemory, editingItemID: "photo-3")
        let output = LibraryRegroupEngine.run(engineInput(fixture, criteria: hasMemory, editingItemID: "photo-3"))
        XCTAssertEqual(output.visibleIDs.last, "photo-3")

        var noMemory = LibraryFilterCriteria()
        noMemory.memoryFilter = .noMemory
        assertSameAsMainThread(fixture, criteria: noMemory, editingItemID: "photo-1")
    }

    func testPlaceFilterOfEveryKind() throws {
        let fixture = try makeFixture(context: try makeContext())
        let ids: [String] = [
            "city-1", "area-1", "spot-1", "spot-2",
            PlaceNames.optionPrefix + PlaceNames.key("Synthetic Town"),
            PlaceNames.optionPrefix + PlaceNames.key("Synthetic Area"),
            PlaceNames.optionPrefix + PlaceNames.key("Renamed Beach"),
            PlaceNames.optionPrefix + PlaceNames.key("Synthetic Beach"),
            PlaceNames.optionPrefix + PlaceNames.key("Family lunch"),
            PlaceNames.optionPrefix + PlaceNames.key("Edited place"),
            "override:Edited place",
            "override:Family lunch",
            "override:Synthetic Beach",
            "override:Spot abc123",
        ]
        for id in ids {
            assertSameAsMainThread(fixture, criteria: LibraryFilterCriteria(placeID: id))
        }
    }

    func testDatesTripsPeopleAndSearch() throws {
        let fixture = try makeFixture(context: try makeContext())
        assertSameAsMainThread(fixture, criteria: LibraryFilterCriteria(fromDate: base.addingTimeInterval(day * 10), toDate: base.addingTimeInterval(day * 40)))
        assertSameAsMainThread(fixture, criteria: LibraryFilterCriteria(toDate: base.addingTimeInterval(day * 20)))
        assertSameAsMainThread(fixture, criteria: LibraryFilterCriteria(tripKey: "trip-1"))
        assertSameAsMainThread(fixture, criteria: LibraryFilterCriteria(personID: "person-a"))
        let matches: Set<String> = ["photo-1", "photo-2", "photo-13", "photo-31", "photo-45", "photo-27"]
        assertSameAsMainThread(fixture, criteria: LibraryFilterCriteria(searchText: "synthetic"), searchMatches: matches)
        assertSameAsMainThread(fixture, criteria: LibraryFilterCriteria(mediaType: .favorite, searchText: "synthetic"), searchMatches: matches)
    }

    func testOnlyTheLibraryOwnFiltersRunOffTheMainThread() {
        XCTAssertTrue(LibraryRegroupEngine.canRun(criteria: .default, searchMatches: nil))
        XCTAssertFalse(LibraryRegroupEngine.canRun(criteria: LibraryFilterCriteria(searchText: "x"), searchMatches: nil))
        XCTAssertTrue(LibraryRegroupEngine.canRun(criteria: LibraryFilterCriteria(searchText: "x"), searchMatches: []))
        XCTAssertFalse(LibraryRegroupEngine.canRun(criteria: LibraryFilterCriteria(tagID: "tag"), searchMatches: nil))
    }

    // MARK: Search waits for a pause in typing

    func testOnlyOneLetterTypedWaits() {
        XCTAssertFalse(LibraryView.waitsForTyping(query: "a", previous: nil), "the first regroup never waits")
        XCTAssertTrue(LibraryView.waitsForTyping(query: "a", previous: ""))
        XCTAssertTrue(LibraryView.waitsForTyping(query: "ab", previous: "a"))
        XCTAssertTrue(LibraryView.waitsForTyping(query: "a", previous: "ab"), "a letter deleted")
        XCTAssertFalse(LibraryView.waitsForTyping(query: "", previous: "ab"), "a cleared field shows everything at once")
        XCTAssertFalse(LibraryView.waitsForTyping(query: "beach", previous: ""), "a pasted word")
        XCTAssertFalse(LibraryView.waitsForTyping(query: "ab", previous: "ab"), "another filter changed")
    }

    // MARK: The facts cache reads only what changed

    private func startStore(_ context: ModelContext) -> LibraryStore {
        let store = LibraryStore()
        store.start(context: context)
        return store
    }

    private func saveAndWait(_ context: ModelContext, _ store: LibraryStore) async throws {
        let refreshes: Int = store.refreshCount
        try context.save()
        let deadline: Date = Date().addingTimeInterval(3)
        while Date() < deadline, store.refreshCount <= refreshes {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(store.refreshCount, refreshes, "the store never applied the save")
    }

    private func facts(
        _ cache: LibraryPhotoFactsCache,
        _ store: LibraryStore,
        _ context: ModelContext
    ) async throws -> [String: LibraryPhotoFacts] {
        let memories: [Memory] = try context.fetch(FetchDescriptor<Memory>())
        let overrides: [PlaceOverride] = try context.fetch(FetchDescriptor<PlaceOverride>())
        let result = await cache.facts(store: store, memories: memories, overrides: overrides, favoritesMatter: false)
        let unwrapped = try XCTUnwrap(result)
        var byID: [String: LibraryPhotoFacts] = [:]
        for facts in unwrapped.regular + unwrapped.screenshots { byID[facts.id] = facts }
        XCTAssertEqual(unwrapped.regular.map(\.id), store.regularIDs)
        XCTAssertEqual(unwrapped.screenshots.map(\.id), store.screenshotIDs)
        return byID
    }

    func testFirstCallReadsEveryPhotoAndTheNextNone() async throws {
        let context = try makeContext()
        let fixture = try makeFixture(context: context)
        let store = startStore(context)
        let cache = LibraryPhotoFactsCache()

        let first = try await facts(cache, store, context)
        XCTAssertEqual(first.count, fixture.all.count)
        XCTAssertEqual(cache.readCount, fixture.all.count)

        _ = try await facts(cache, store, context)
        XCTAssertEqual(cache.readCount, fixture.all.count, "nothing changed, so nothing is read")
    }

    func testWritingAMemoryReadsThatPhotoOnly() async throws {
        let context = try makeContext()
        let fixture = try makeFixture(context: context)
        let store = startStore(context)
        let cache = LibraryPhotoFactsCache()
        let before = try await facts(cache, store, context)
        XCTAssertEqual(before["photo-2"]?.hasWrittenMemory, false)
        let reads: Int = cache.readCount

        context.insert(Memory(text: "Synthetic new memory", mediaItem: fixture.all[2]))
        try await saveAndWait(context, store)
        let after = try await facts(cache, store, context)
        XCTAssertEqual(cache.readCount - reads, 1)
        XCTAssertEqual(after["photo-2"]?.hasWrittenMemory, true)
    }

    func testCorrectingAPlaceOrADateReadsThatPhotoOnly() async throws {
        let context = try makeContext()
        let fixture = try makeFixture(context: context)
        let store = startStore(context)
        let cache = LibraryPhotoFactsCache()
        _ = try await facts(cache, store, context)
        var reads: Int = cache.readCount

        context.insert(PlaceOverride(mediaID: "photo-5", nameOverride: "Synthetic Corner", mediaItem: fixture.all[5]))
        try await saveAndWait(context, store)
        var after = try await facts(cache, store, context)
        XCTAssertEqual(cache.readCount - reads, 1)
        XCTAssertEqual(after["photo-5"]?.placeOverrideName, "Synthetic Corner")
        reads = cache.readCount

        let moved: Date = base.addingTimeInterval(-40 * day)
        fixture.all[8].captureDate = moved
        try await saveAndWait(context, store)
        after = try await facts(cache, store, context)
        XCTAssertEqual(cache.readCount - reads, 1)
        XCTAssertEqual(after["photo-8"]?.captureDate, fixture.all[8].effectiveCaptureDate)
        XCTAssertEqual(after["photo-8"]?.monthKey, LibraryRegroupEngine.makeMonthFormatter().string(from: fixture.all[8].effectiveCaptureDate ?? moved))
    }

    func testADeletedPhotoIsLeftOutWithoutReading() async throws {
        let context = try makeContext()
        let fixture = try makeFixture(context: context)
        let store = startStore(context)
        let cache = LibraryPhotoFactsCache()
        _ = try await facts(cache, store, context)
        let reads: Int = cache.readCount

        context.delete(fixture.all[10])
        try await saveAndWait(context, store)
        let after = try await facts(cache, store, context)
        XCTAssertNil(after["photo-10"])
        XCTAssertEqual(after.count, fixture.all.count - 1)
        XCTAssertEqual(cache.readCount, reads)
    }

    func testCachedFactsGiveTheSameGridAsFreshOnes() async throws {
        let context = try makeContext()
        let fixture = try makeFixture(context: context)
        let store = startStore(context)
        let cache = LibraryPhotoFactsCache()
        _ = try await facts(cache, store, context)
        fixture.all[14].captureDate = base.addingTimeInterval(90 * day)
        context.insert(Memory(text: "Synthetic memory 30", mediaItem: fixture.all[30]))
        try await saveAndWait(context, store)

        let memories: [Memory] = try context.fetch(FetchDescriptor<Memory>())
        let overrides: [PlaceOverride] = try context.fetch(FetchDescriptor<PlaceOverride>())
        let cached = try XCTUnwrap(await cache.facts(store: store, memories: memories, overrides: overrides, favoritesMatter: false))
        let fresh = try XCTUnwrap(await LibraryPhotoFactsCache().facts(store: store, memories: memories, overrides: overrides, favoritesMatter: false))
        XCTAssertEqual(cached.regular, fresh.regular)
        XCTAssertEqual(cached.screenshots, fresh.screenshots)
        var places: [String: LibraryPlaceFacts] = [:]
        for place in store.places { places[place.id] = LibraryPlaceFacts(place: place) }
        XCTAssertEqual(cache.places, places)
    }
}

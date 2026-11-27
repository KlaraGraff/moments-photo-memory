import Foundation
import SwiftData
import XCTest
@testable import Moments

/// The Library's search finds every kind of text written in the app, from an
/// index built once. Synthetic data, in-memory stores only.
@MainActor
final class LibrarySearchIndexTests: XCTestCase {
    /// Kept for the length of a test, so its main context stays valid.
    private var container: ModelContainer?

    override func setUp() async throws {
        LibrarySearchIndex.reset()
    }

    override func tearDown() async throws {
        LibrarySearchIndex.reset()
    }

    private func makeContext() throws -> ModelContext {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    private func makeStore(context: ModelContext) -> LibraryStore {
        let store = LibraryStore()
        store.start(context: context)
        return store
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// 17 and 18 May 2024 (noon UTC), at synthetic places.
    private struct Fixture {
        let store: LibraryStore
        let context: ModelContext
    }

    private func makeFixture() throws -> Fixture {
        let context = try makeContext()
        let may17 = Date(timeIntervalSince1970: 1_715_947_200)
        let may18 = may17.addingTimeInterval(86_400)
        let harbor = Place(id: "place-harbor", name: "Synthetic Harbor", kind: .city, latitude: 0.01, longitude: 0.01)
        let hill = Place(id: "place-hill", name: "合成山顶", kind: .city, latitude: 0.02, longitude: 0.02)
        context.insert(harbor)
        context.insert(hill)
        let trip = Trip(id: "trip-coast", name: "Coast Trip")
        context.insert(trip)
        let photos: [MediaItem] = [
            MediaItem(id: "day1-a", captureDate: may17, tripID: trip.id, localDayKey: "2024-05-17"),
            MediaItem(id: "day1-b", captureDate: may17.addingTimeInterval(600), tripID: trip.id, localDayKey: "2024-05-17"),
            MediaItem(id: "day2-a", captureDate: may18, localDayKey: "2024-05-18"),
            MediaItem(id: "other", captureDate: may18.addingTimeInterval(86_400 * 30), localDayKey: "2024-06-17"),
        ]
        for photo in photos { context.insert(photo) }
        photos[0].place = harbor
        photos[1].place = harbor
        photos[2].place = hill
        photos[0].trip = trip
        photos[1].trip = trip
        try context.save()
        return Fixture(store: makeStore(context: context), context: context)
    }

    private func found(_ query: String, in fixture: Fixture, people: [Person] = [], personIndex: [String: Set<String>] = [:]) -> [String] {
        let calendar = utcCalendar()
        let matches: Set<String>? = LibrarySearchIndex.matchingIDs(
            query: query,
            store: fixture.store,
            people: people,
            personIndex: personIndex,
            context: fixture.context,
            calendar: calendar
        )
        let criteria = LibraryFilterCriteria(searchText: query)
        return LibraryFilterEngine.filteredItems(fixture.store.items, by: criteria, calendar: calendar, searchMatches: matches)
            .map(\.id)
            .sorted()
    }

    // MARK: Acceptance: a day's memory finds that day's photos

    func testAWordFromADayMemoryFindsThatDaysPhotos() throws {
        let fixture = try makeFixture()
        fixture.context.insert(CollectionMemory(scope: .day, scopeKey: "2024-05-17", text: "Pancakes after the storm"))
        fixture.context.insert(CollectionMemory(scope: .day, scopeKey: "2024-05-18", text: "爬了三个小时的山"))
        try fixture.context.save()

        XCTAssertEqual(found("pancakes", in: fixture), ["day1-a", "day1-b"])
        XCTAssertEqual(found("STORM pancakes", in: fixture), ["day1-a", "day1-b"], "Several words, any case")
        XCTAssertEqual(found("三个小时", in: fixture), ["day2-a"])
        XCTAssertEqual(found("pancakes 三个小时", in: fixture), [])
    }

    // MARK: Every other kind of text

    func testEveryKindOfWrittenTextFindsItsPhotos() throws {
        let fixture = try makeFixture()
        let context = fixture.context
        // A trip's memory, on the trip's photos.
        context.insert(CollectionMemory(scope: .trip, scopeKey: "trip-coast", text: "First road trip"))
        // A chapter's memory, on the chapter's photos.
        let chapter = UserGroup(id: "party", name: "Synthetic Party", kind: .chapter)
        context.insert(chapter)
        context.insert(UserGroupItem(groupID: chapter.id, mediaID: "other"))
        context.insert(UserGroupItem(groupID: chapter.id, mediaID: "day2-a", excluded: true))
        context.insert(CollectionMemory(scope: .trip, scopeKey: TripsScreen.chapterID(chapter), text: "生日蛋糕"))
        // A place's note, on every photo at that place.
        context.insert(PlaceNote(placeName: "Synthetic Harbor", text: "The bakery by the lighthouse"))
        // A memory by each person, the partner's linked by id only, and a
        // comment under it.
        let mine = Memory(text: "Sunset walk", author: .me, mediaItem: fixture.store.itemsByID["day2-a"])
        context.insert(mine)
        let theirs = Memory(text: "海风是咸的", author: .partner, authorAccountID: "synthetic-partner", mediaID: "day1-a")
        context.insert(theirs)
        context.insert(Comment(memoryID: theirs.id, text: "Next time bring a kite", authorAccountID: "synthetic-partner"))
        context.insert(Comment(memoryID: mine.id, text: "下次带上望远镜"))
        // A note's original words, before the AI organized it.
        context.insert(PhotoNote(mediaID: "other", text: "new sofa, cat asleep on it", status: .done))
        try context.save()

        XCTAssertEqual(found("road trip", in: fixture), ["day1-a", "day1-b"], "Trip memory")
        XCTAssertEqual(found("生日", in: fixture), ["other"], "Chapter memory; a photo taken out of the chapter is not found")
        XCTAssertEqual(found("lighthouse bakery", in: fixture), ["day1-a", "day1-b"], "Place note")
        XCTAssertEqual(found("海风", in: fixture), ["day1-a"], "The partner's memory")
        XCTAssertEqual(found("kite", in: fixture), ["day1-a"], "A comment under the partner's memory")
        XCTAssertEqual(found("望远镜", in: fixture), ["day2-a"], "A comment under one's own memory")
        XCTAssertEqual(found("sunset", in: fixture), ["day2-a"], "One's own memory, as before")
        XCTAssertEqual(found("sofa cat", in: fixture), ["other"], "A note's original words")
        // What search already found keeps working.
        XCTAssertEqual(found("synthetic harbor", in: fixture), ["day1-a", "day1-b"], "Place name")
        XCTAssertEqual(found("coast", in: fixture), ["day1-a", "day1-b"], "Trip name")
        XCTAssertEqual(found("may 2024", in: fixture), ["day1-a", "day1-b", "day2-a"], "Month and year")
        XCTAssertEqual(found("2024年6月", in: fixture), ["other"])
        // Words from different kinds of text may be combined.
        XCTAssertEqual(found("kite lighthouse 2024", in: fixture), ["day1-a"])
    }

    func testAPersonsNameFindsTheirPhotos() throws {
        let fixture = try makeFixture()
        let alex = Person(id: "person-alex", name: "Alex Synthetic")
        let hidden = Person(id: "person-hidden", name: "Hidden Person", hidden: true)
        let personIndex: [String: Set<String>] = ["day2-a": ["person-alex", "person-hidden"]]
        XCTAssertEqual(found("alex", in: fixture, people: [alex, hidden], personIndex: personIndex), ["day2-a"])
        XCTAssertEqual(found("hidden", in: fixture, people: [alex, hidden], personIndex: personIndex), [], "Hidden people are not searched")
    }

    /// The index matches what the old per-photo search found for every
    /// query the old search could answer.
    func testTheIndexFindsWhatTheOldSearchFound() throws {
        let fixture = try makeFixture()
        let tag = Tag(displayName: "Favourite Beach")
        fixture.context.insert(tag)
        fixture.context.insert(MediaTag(mediaItem: fixture.store.itemsByID["day1-b"], tag: tag))
        fixture.context.insert(Memory(text: "Café on the corner", author: .me, mediaItem: fixture.store.itemsByID["other"]))
        try fixture.context.save()
        let calendar = utcCalendar()
        for query in ["beach", "cafe", "café", "synthetic", "coast trip", "2024-05", "May", "合成", "nothing here", "2024 favourite"] {
            let criteria = LibraryFilterCriteria(searchText: query)
            let old = LibraryFilterEngine.filteredItems(fixture.store.items, by: criteria, calendar: calendar).map(\.id).sorted()
            XCTAssertEqual(found(query, in: fixture), old, query)
        }
    }

    // MARK: Built once

    func testTheIndexIsReusedUntilSomethingIsWritten() async throws {
        let fixture = try makeFixture()
        XCTAssertEqual(found("pancakes", in: fixture), [])
        #if DEBUG
        let builds: Int = LibrarySearchIndex.buildCount
        _ = found("p", in: fixture)
        _ = found("pa", in: fixture)
        _ = found("pan", in: fixture)
        XCTAssertEqual(LibrarySearchIndex.buildCount, builds, "Typing reads the index; it is not built again")
        #endif

        let revision: Int = fixture.store.writtenTextRevision
        fixture.context.insert(CollectionMemory(scope: .day, scopeKey: "2024-05-18", text: "pancakes again"))
        try fixture.context.save()
        let moved: Bool = await waitUntil(timeout: 3) { fixture.store.writtenTextRevision != revision }
        XCTAssertTrue(moved, "Saving a day memory moves the written-text revision")
        XCTAssertEqual(found("pancakes", in: fixture), ["day2-a"], "The new memory is found")

        let commentRevision: Int = fixture.store.writtenTextRevision
        let memory = Memory(text: "x", author: .me, mediaItem: fixture.store.itemsByID["other"])
        fixture.context.insert(memory)
        try fixture.context.save()
        _ = await waitUntil(timeout: 3) { fixture.store.writtenTextRevision != commentRevision }
        let afterMemory: Int = fixture.store.writtenTextRevision
        fixture.context.insert(Comment(memoryID: memory.id, text: "a waffle comment"))
        try fixture.context.save()
        let commentMoved: Bool = await waitUntil(timeout: 3) { fixture.store.writtenTextRevision != afterMemory }
        XCTAssertTrue(commentMoved, "Saving a comment moves the written-text revision")
        XCTAssertEqual(found("waffle", in: fixture), ["other"])
    }

    // MARK: 50,000 photos

    /// Typing a word in a 50,000-photo synthetic library: the old search
    /// (every photo's fields read for every keystroke) against the index
    /// (built on the first keystroke, read on the next ones). Prints one
    /// SEARCH-BENCH line for the pull request; asserts only that both find
    /// the same photos.
    func testFiftyThousandPhotoSearchTiming() throws {
        let count = 50_000
        let context = try makeContext()
        let calendar = utcCalendar()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var places: [Place] = []
        for index in 0..<500 {
            let place = Place(id: "bench-place-\(index)", name: "Bench Place \(index)", kind: .city, latitude: Double(index % 50) * 0.001, longitude: Double(index / 50) * 0.001)
            context.insert(place)
            places.append(place)
        }
        var trips: [Trip] = []
        for index in 0..<100 {
            let trip = Trip(id: "bench-trip-\(index)", name: "Bench Trip \(index)")
            context.insert(trip)
            trips.append(trip)
        }
        var people: [Person] = []
        for index in 0..<20 {
            let person = Person(id: "bench-person-\(index)", name: "Person \(index)")
            context.insert(person)
            people.append(person)
        }
        var personIndex: [String: Set<String>] = [:]
        for index in 0..<count {
            let date = start.addingTimeInterval(Double(index) * 600)
            let id = "bench-\(index)"
            let item = MediaItem(id: id, captureDate: date, tripID: trips[index / 500].id)
            context.insert(item)
            item.place = places[index / 100]
            item.trip = trips[index / 500]
            if index % 5 == 0 {
                context.insert(Memory(text: "Synthetic memory \(index) by the water 海边", author: index % 10 == 0 ? .me : .partner, mediaItem: item))
            }
            if index % 7 == 0 { personIndex[id] = [people[index % 20].id] }
            if index % 144 == 0 {
                context.insert(CollectionMemory(scope: .day, scopeKey: PhotoNoteDay.key(for: date, calendar: calendar), text: "Day story \(index) 下雨天"))
            }
            if index % 1_000 == 0 { try context.save() }
        }
        for (index, place) in places.enumerated() where index % 10 == 0 {
            context.insert(PlaceNote(placeName: place.name, text: "Place note for \(place.name)"))
        }
        try context.save()
        let store = makeStore(context: context)
        XCTAssertEqual(store.items.count, count)
        let items: [MediaItem] = store.items
        let clock = ContinuousClock()

        // Before: what each keystroke did until now.
        func oldSearch(_ query: String) -> [String] {
            var names: [String: String] = [:]
            for person in people { if let name = person.name { names[person.id] = name } }
            var extras: [String: [String]] = [:]
            for (mediaID, ids) in personIndex { extras[mediaID] = ids.compactMap { names[$0] } }
            return LibraryFilterEngine.filteredItems(items, by: LibraryFilterCriteria(searchText: query), calendar: calendar, personIDsByMediaID: personIndex, searchExtras: extras).map(\.id)
        }
        // After: the index, then the same filter pass with its matches.
        func newSearch(_ query: String) -> [String] {
            let matches = LibrarySearchIndex.matchingIDs(query: query, store: store, people: people, personIndex: personIndex, context: context, calendar: calendar)
            return LibraryFilterEngine.filteredItems(items, by: LibraryFilterCriteria(searchText: query), calendar: calendar, personIDsByMediaID: personIndex, searchMatches: matches).map(\.id)
        }

        let missQuery = "zzqx"
        let hitQuery = "water 海边"
        var oldMiss: [String] = []
        var oldHit: [String] = []
        let oldMissTime = clock.measure { oldMiss = oldSearch(missQuery) }
        let oldHitTime = clock.measure { oldHit = oldSearch(hitQuery) }

        LibrarySearchIndex.reset()
        var newMiss: [String] = []
        var newHit: [String] = []
        var newDay: [String] = []
        let firstKeystroke = clock.measure { newMiss = newSearch(missQuery) }
        let nextMiss = clock.measure { newMiss = newSearch(missQuery) }
        let nextHit = clock.measure { newHit = newSearch(hitQuery) }
        let dayHit = clock.measure { newDay = newSearch("下雨天") }

        print("SEARCH-BENCH app photos=\(count) old-miss=\(oldMissTime) old-hit=\(oldHitTime) new-first-keystroke(index build)=\(firstKeystroke) new-miss=\(nextMiss) new-hit=\(nextHit) new-day-memory=\(dayHit)")
        XCTAssertEqual(oldMiss, [])
        XCTAssertEqual(newMiss, [])
        XCTAssertEqual(Set(newHit), Set(oldHit), "The index finds what the old search found")
        XCTAssertEqual(oldHit.count, count / 5)
        XCTAssertFalse(newDay.isEmpty, "A day memory's words find that day's photos")
    }
}

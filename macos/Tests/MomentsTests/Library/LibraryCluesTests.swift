import Foundation
import SwiftData
import XCTest
@testable import Moments

/// The clues on the photos: the row of faces, the faces on a chapter, the
/// stamps of a small map, and the words search adds for people and dates.
/// Every face, name, place and photo here is synthetic.
@MainActor
final class LibraryCluesTests: XCTestCase {
    private func face(_ id: String, photo: String, personID: String? = nil, clusterID: String? = nil) -> FaceObservation {
        FaceObservation(
            id: id,
            mediaID: photo,
            rect: (0.1, 0.1, 0.2, 0.2),
            embedding: Data(repeating: 0, count: 8 * MemoryLayout<Float>.size),
            cropData: Data([1, 2, 3]),
            quality: 0.8,
            personID: personID,
            clusterID: clusterID,
            confirmed: personID != nil,
            assignmentSource: personID != nil ? "user" : "auto"
        )
    }

    /// `count` photos named "<prefix>-1"…, each with one face of the person or group.
    private func faces(_ prefix: String, count: Int, personID: String? = nil, clusterID: String? = nil) -> [FaceObservation] {
        var result: [FaceObservation] = []
        for index in 1...count {
            result.append(face("\(prefix)-face-\(index)", photo: "\(prefix)-\(index)", personID: personID, clusterID: clusterID))
        }
        return result
    }

    private func items(for faces: [FaceObservation]) -> [String: MediaItem] {
        var result: [String: MediaItem] = [:]
        for face in faces {
            let id: String = face.mediaID
            result[id] = MediaItem(id: id)
        }
        return result
    }

    // MARK: The row of faces

    func testRowListsNamedPeopleByPhotoCountThenTheUnnamedGroup() {
        let anna = Person(id: "anna", name: "Anna")
        let ben = Person(id: "ben", name: " Ben ")
        let hiddenPerson = Person(id: "zed", name: "Zed", hidden: true)
        let nameless = Person(id: "nameless", name: nil)
        var all: [FaceObservation] = []
        all += faces("anna", count: 2, personID: "anna")
        all += faces("ben", count: 3, personID: "ben")
        all += faces("zed", count: 4, personID: "zed")
        all += faces("nameless", count: 4, personID: "nameless")
        all += faces("group", count: 5, clusterID: "cluster-big")
        var itemsByID: [String: MediaItem] = items(for: all)
        // A face in a screenshot and a face whose photo is gone count for nobody.
        all.append(face("anna-screenshot-face", photo: "screenshot-1", personID: "anna"))
        itemsByID["screenshot-1"] = MediaItem(id: "screenshot-1", isScreenshot: true)
        all.append(face("anna-gone-face", photo: "deleted-1", personID: "anna"))

        let entries: [PeopleStripEntry] = PeopleStrip.entries(
            faces: all,
            people: [anna, ben, hiddenPerson, nameless],
            itemsByID: itemsByID
        )

        let ids: [String] = entries.map { (entry: PeopleStripEntry) -> String in entry.id }
        XCTAssertEqual(ids, ["person.ben", "person.anna", "cluster.cluster-big"], "Named people by photo count, then the unnamed group; hidden and nameless people are left out")
        let counts: [Int] = entries.map { (entry: PeopleStripEntry) -> Int in entry.photoCount }
        XCTAssertEqual(counts, [3, 2, 5], "Screenshots and missing photos are not counted")
        let names: [String?] = entries.map { (entry: PeopleStripEntry) -> String? in entry.name }
        XCTAssertEqual(names, ["Ben", "Anna", nil], "Names are trimmed; a group nobody named has none")
        XCTAssertEqual(entries.last?.clusterID, "cluster-big")
        XCTAssertNil(entries.last?.personID)
        XCTAssertNotNil(entries.first?.cover, "A person with faces has a face to show")
    }

    func testSmallAndLooseGroupsDoNotAskForAName() {
        var all: [FaceObservation] = []
        all += faces("four", count: 4, clusterID: "cluster-four")
        all += faces("loose", count: 6, clusterID: "loose-1")
        all += faces("five", count: 5, clusterID: "cluster-five")

        let entries: [PeopleStripEntry] = PeopleStrip.entries(faces: all, people: [], itemsByID: items(for: all))

        let ids: [String] = entries.map { (entry: PeopleStripEntry) -> String in entry.id }
        XCTAssertEqual(ids, ["cluster.cluster-five"], "Only a group in five or more photos asks who it is")
    }

    func testAtMostSixUnnamedGroupsShowLargestFirst() {
        var all: [FaceObservation] = []
        for size in 5...11 {
            all += faces("g\(size)", count: size, clusterID: "cluster-\(size)")
        }

        let entries: [PeopleStripEntry] = PeopleStrip.entries(faces: all, people: [], itemsByID: items(for: all))

        let counts: [Int] = entries.map { (entry: PeopleStripEntry) -> Int in entry.photoCount }
        XCTAssertEqual(counts, [11, 10, 9, 8, 7, 6], "Six groups at a time, the largest first")
    }

    // MARK: Faces on a chapter

    func testPeopleInASetOfPhotosCountsOnlyThosePhotos() {
        let anna = Person(id: "anna", name: "Anna")
        let ben = Person(id: "ben", name: "Ben")
        let cara = Person(id: "cara", name: "Cara")
        let hiddenPerson = Person(id: "zed", name: "Zed", hidden: true)
        let all: [FaceObservation] = [
            face("f1", photo: "p1", personID: "anna"),
            face("f2", photo: "p2", personID: "anna"),
            face("f3", photo: "p3", personID: "anna"),
            face("f4", photo: "p1", personID: "ben"),
            face("f5", photo: "p2", personID: "ben"),
            face("f6", photo: "p1", personID: "cara"),
            face("f7", photo: "p1", personID: "zed"),
            face("f8", photo: "p1", clusterID: "cluster-1"),
        ]
        let chapter: Set<String> = ["p1", "p2"]

        let everyone: [PeopleStripEntry] = PeopleStrip.people(in: chapter, faces: all, people: [anna, ben, cara, hiddenPerson], limit: 5)
        let ids: [String] = everyone.map { (entry: PeopleStripEntry) -> String in entry.id }
        XCTAssertEqual(ids, ["person.anna", "person.ben", "person.cara"], "Named, visible people in these photos; most photos first, then by id")
        XCTAssertEqual(everyone.first?.mediaIDs, ["p1", "p2"], "Anna's third photo is outside the chapter")

        let firstTwo: [PeopleStripEntry] = PeopleStrip.people(in: chapter, faces: all, people: [anna, ben, cara], limit: 2)
        XCTAssertEqual(firstTwo.count, 2)
        let nobody: [PeopleStripEntry] = PeopleStrip.people(in: ["p9"], faces: all, people: [anna, ben, cara], limit: 5)
        XCTAssertTrue(nobody.isEmpty)
    }

    func testChapterCompanionsAreNamedPeopleThenTheGroupsTheRowAsksAbout() {
        let anna = Person(id: "anna", name: "Anna")
        let ben = Person(id: "ben", name: "Ben")
        let hiddenPerson = Person(id: "zed", name: "Zed", hidden: true)
        var all: [FaceObservation] = []
        // Anna in three photos of the first chapter, Ben in one of each.
        all += [
            face("a1", photo: "c1-1", personID: "anna"),
            face("a2", photo: "c1-2", personID: "anna"),
            face("a3", photo: "c1-3", personID: "anna"),
            face("b1", photo: "c1-1", personID: "ben"),
            face("b2", photo: "c2-1", personID: "ben"),
            face("z1", photo: "c1-1", personID: "zed"),
        ]
        // A group in five photos over the library, two of them in chapter one;
        // a group in two photos only is too small to show.
        all += faces("big", count: 3, clusterID: "cluster-big")
        all += [
            face("big-in-1", photo: "c1-2", clusterID: "cluster-big"),
            face("big-in-2", photo: "c1-3", clusterID: "cluster-big"),
            face("small-1", photo: "c1-1", clusterID: "cluster-small"),
            face("small-2", photo: "c1-2", clusterID: "cluster-small"),
            face("loose", photo: "c1-1", clusterID: "loose-1"),
        ]
        var itemsByID: [String: MediaItem] = items(for: all)
        // A face in a screenshot of the chapter counts for nobody.
        all.append(face("b-shot", photo: "c2-shot", personID: "ben"))
        itemsByID["c2-shot"] = MediaItem(id: "c2-shot", isScreenshot: true)
        let sets: [String: Set<String>] = [
            "one": ["c1-1", "c1-2", "c1-3"],
            "two": ["c2-1", "c2-shot"],
            "empty": ["c3-1"],
        ]

        let found: [String: [PeopleStripEntry]] = PeopleStrip.companions(
            in: sets,
            faces: all,
            people: [anna, ben, hiddenPerson],
            itemsByID: itemsByID,
            limit: 5
        )

        let one: [String] = (found["one"] ?? []).map { (entry: PeopleStripEntry) -> String in entry.id }
        XCTAssertEqual(one, ["person.anna", "person.ben", "cluster.cluster-big"], "Named people by photos in the chapter, then the group the row asks about; hidden people, small and loose groups are left out")
        let counts: [Int] = (found["one"] ?? []).map { (entry: PeopleStripEntry) -> Int in entry.photoCount }
        XCTAssertEqual(counts, [3, 1, 2], "Only the chapter's own photos count")
        let two: [String] = (found["two"] ?? []).map { (entry: PeopleStripEntry) -> String in entry.id }
        XCTAssertEqual(two, ["person.ben"], "Screenshots do not count")
        XCTAssertEqual(found["two"]?.first?.photoCount, 1)
        XCTAssertNil(found["empty"], "A chapter nobody is in has no faces")

        let capped: [String: [PeopleStripEntry]] = PeopleStrip.companions(in: sets, faces: all, people: [anna, ben], itemsByID: itemsByID, limit: 2)
        let cappedIDs: [String] = (capped["one"] ?? []).map { (entry: PeopleStripEntry) -> String in entry.id }
        XCTAssertEqual(cappedIDs, ["person.anna", "person.ben"], "At most `limit` faces, named people first")
    }

    // MARK: Filters

    func testStoredFiltersBecomeCriteriaAndRetiredTypesCountAsAll() {
        let criteria: LibraryFilterCriteria = LibraryFilterKeys.criteria(
            query: " tea ",
            typeRaw: LibraryMediaTypeFilter.video.rawValue,
            fromDateInterval: 100,
            toDateInterval: 0,
            placeFilterID: "place-1",
            tripFilterKey: "journeyA",
            memoryFilterRaw: LibraryMemoryFilter.hasMemory.rawValue,
            personFilterID: "anna"
        )
        XCTAssertEqual(criteria.mediaType, .video)
        XCTAssertEqual(criteria.fromDate, Date(timeIntervalSince1970: 100))
        XCTAssertNil(criteria.toDate)
        XCTAssertEqual(criteria.placeID, "place-1")
        XCTAssertEqual(criteria.tripKey, "journeyA")
        XCTAssertEqual(criteria.memoryFilter, .hasMemory)
        XCTAssertEqual(criteria.personID, "anna")
        XCTAssertEqual(criteria.searchText, "tea")
        XCTAssertTrue(criteria.isFiltered)

        for retired in [LibraryMediaTypeFilter.favorite, .screenshot] {
            let old: LibraryFilterCriteria = LibraryFilterKeys.criteria(
                query: "",
                typeRaw: retired.rawValue,
                fromDateInterval: 0,
                toDateInterval: 0,
                placeFilterID: "",
                tripFilterKey: "",
                memoryFilterRaw: "",
                personFilterID: ""
            )
            XCTAssertFalse(old.isFiltered, "A saved \(retired) choice the chips no longer offer must not hide photos")
        }
    }

    func testLargeMapShowsItsPhotosNarrowedByTheFilters() {
        XCTAssertNil(MapScreen.shownIDs(scope: nil, filtered: nil), "No scope and no filter: every photo")
        XCTAssertEqual(MapScreen.shownIDs(scope: ["a", "b"], filtered: nil), ["a", "b"])
        XCTAssertEqual(MapScreen.shownIDs(scope: nil, filtered: ["b", "c"]), ["b", "c"])
        XCTAssertEqual(MapScreen.shownIDs(scope: ["a", "b"], filtered: ["b", "c"]), ["b"])
    }

    func testOtherPagesFollowTheFiltersOnlyWhileOneIsOn() {
        let selection = SelectionModel()
        selection.visibleItemIDs = ["a"]
        XCTAssertNil(selection.filteredItemIDs, "The Library publishes every photo it shows; without a filter nothing is narrowed")
        XCTAssertTrue(selection.isOnMap("b"))
        selection.libraryFiltersActive = true
        XCTAssertEqual(selection.filteredItemIDs, ["a"])
        XCTAssertFalse(selection.isOnMap("b"))
        XCTAssertTrue(selection.isOnMap("a"))
    }

    /// The face a person picked to stand for them shows in the row of faces
    /// and on a chapter, not the sharpest one.
    func testThePickedKeyFaceStandsForThePersonInTheRowAndOnAChapter() throws {
        let suiteName: String = "LibraryCluesTests.keyFace.\(UUID().uuidString)"
        let decisions: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { decisions.removePersistentDomain(forName: suiteName) }
        let anna = Person(id: "anna", name: "Anna")
        let sharp: FaceObservation = face("anna-sharp", photo: "p1", personID: "anna")
        sharp.quality = 0.95
        let picked: FaceObservation = face("anna-picked", photo: "p2", personID: "anna")
        picked.quality = 0.3
        let all: [FaceObservation] = [sharp, picked]
        let itemsByID: [String: MediaItem] = items(for: all)

        let before: [PeopleStripEntry] = PeopleStrip.entries(faces: all, people: [anna], itemsByID: itemsByID, decisions: decisions)
        XCTAssertEqual(before.first?.cover?.id, "anna-sharp", "With no choice the sharpest face stands for her")

        PeopleStoreActions.setKeyFace("anna-picked", for: "anna", defaults: decisions)
        let row: [PeopleStripEntry] = PeopleStrip.entries(faces: all, people: [anna], itemsByID: itemsByID, decisions: decisions)
        XCTAssertEqual(row.first?.cover?.id, "anna-picked", "The row of faces shows the picked face")
        let chapter: [PeopleStripEntry] = PeopleStrip.people(in: ["p1", "p2"], faces: all, people: [anna], limit: 5, decisions: decisions)
        XCTAssertEqual(chapter.first?.cover?.id, "anna-picked", "A chapter's faces show the picked face")
    }

    /// A group nobody has named yet keeps the face picked for it, too.
    func testThePickedKeyFaceStandsForAnUnnamedGroup() throws {
        let suiteName: String = "LibraryCluesTests.groupKeyFace.\(UUID().uuidString)"
        let decisions: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { decisions.removePersistentDomain(forName: suiteName) }
        let all: [FaceObservation] = faces("group", count: 5, clusterID: "cluster-big")
        all[0].quality = 0.95
        let itemsByID: [String: MediaItem] = items(for: all)

        let before: [PeopleStripEntry] = PeopleStrip.entries(faces: all, people: [], itemsByID: itemsByID, decisions: decisions)
        XCTAssertEqual(before.first?.cover?.id, "group-face-1", "With no choice the sharpest face stands for the group")

        PeopleStoreActions.setKeyFace("group-face-4", for: PeopleStoreActions.groupKey("cluster-big"), defaults: decisions)
        let after: [PeopleStripEntry] = PeopleStrip.entries(faces: all, people: [], itemsByID: itemsByID, decisions: decisions)
        XCTAssertEqual(after.first?.cover?.id, "group-face-4", "The row of faces shows the face picked for the group")
    }

    /// A person shows the same face on every chapter as in the row of faces,
    /// even on a chapter without that photo, so nobody looks like a stranger.
    func testAPersonShowsTheSameFaceOnEveryChapter() {
        let anna = Person(id: "anna", name: "Anna")
        let sharp: FaceObservation = face("anna-sharp", photo: "p1", personID: "anna")
        sharp.quality = 0.95
        let blurry: FaceObservation = face("anna-blurry", photo: "p2", personID: "anna")
        blurry.quality = 0.2
        let group: [FaceObservation] = (0..<6).map { (index: Int) -> FaceObservation in
            let observation: FaceObservation = face("c\(index)", photo: "q\(index)", clusterID: "c1")
            observation.quality = Double(index) / 10
            return observation
        }
        let all: [FaceObservation] = [sharp, blurry] + group
        let itemsByID: [String: MediaItem] = items(for: all)
        let row: [PeopleStripEntry] = PeopleStrip.entries(faces: all, people: [anna], itemsByID: itemsByID)
        let rowCovers: [String: String] = Dictionary(uniqueKeysWithValues: row.map { (entry: PeopleStripEntry) -> (String, String) in (entry.id, entry.cover?.id ?? "") })

        let sets: [String: Set<String>] = ["a": ["p1"], "b": ["p2", "q0", "q1"]]
        let found: [String: [PeopleStripEntry]] = PeopleStrip.companions(in: sets, faces: all, people: [anna], itemsByID: itemsByID, limit: 5)
        for (chapter, entries) in found {
            for entry in entries {
                XCTAssertEqual(entry.cover?.id, rowCovers[entry.id], "\(entry.id) shows another face on chapter \(chapter)")
            }
        }
        XCTAssertEqual(found["b"]?.first?.cover?.id, "anna-sharp", "The blurry face of this chapter stood in for Anna")
        let chapter: [PeopleStripEntry] = PeopleStrip.people(in: ["p2"], faces: all, people: [anna], limit: 5)
        XCTAssertEqual(chapter.first?.cover?.id, "anna-sharp")
    }

    // MARK: The small map

    func testSmallMapHasOneStampPerAreaFullestFirst() {
        let photos: [MediaItem] = [
            MediaItem(id: "a1", latitude: 48.10, longitude: 11.50),
            MediaItem(id: "a2", latitude: 48.12, longitude: 11.52),
            MediaItem(id: "a3", latitude: 48.14, longitude: 11.54),
            MediaItem(id: "b1", latitude: 35.70, longitude: 139.70),
            MediaItem(id: "nowhere"),
        ]

        let stops: [TripRouteStop] = MiniMapStops.make(photos)

        XCTAssertEqual(stops.count, 2, "Photos close together share a stamp; a photo without a place has none")
        let first: TripRouteStop = stops[0]
        XCTAssertEqual(first.latitude, 48.12, accuracy: 0.0001, "The stamp sits at the middle of its photos")
        XCTAssertEqual(first.longitude, 11.52, accuracy: 0.0001)
        XCTAssertEqual(stops[1].latitude, 35.70, accuracy: 0.0001)

        let onlyOne: [TripRouteStop] = MiniMapStops.make(photos, limit: 1)
        XCTAssertEqual(onlyOne.count, 1)
        XCTAssertEqual(onlyOne[0].latitude, 48.12, accuracy: 0.0001, "The fullest area is kept")
        XCTAssertTrue(MiniMapStops.make([MediaItem(id: "nowhere")]).isEmpty)
    }

    // MARK: Search

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    func testSearchFindsAPhotoByYearMonthAndPerson() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        // 17 May 2024, noon UTC.
        let taken = Date(timeIntervalSince1970: 1_715_947_200)
        let item = MediaItem(id: "may-photo", captureDate: taken)
        let undated = MediaItem(id: "undated-photo")
        context.insert(item)
        context.insert(undated)
        try context.save()
        let calendar: Calendar = utcCalendar()

        let words: [String] = LibraryFilterEngine.dateWords(of: item, calendar: calendar)
        XCTAssertEqual(words, ["2024", "2024-05", "2024年5月", "May 2024"])
        XCTAssertTrue(LibraryFilterEngine.dateWords(of: undated, calendar: calendar).isEmpty)

        let extras: [String: [String]] = ["may-photo": ["Alex"]]
        func found(_ text: String, _ photo: MediaItem) -> Bool {
            LibraryFilterEngine.matches(photo, criteria: LibraryFilterCriteria(searchText: text), calendar: calendar, searchExtras: extras)
        }
        XCTAssertTrue(found("2024", item), "The year finds the photo")
        XCTAssertTrue(found("2024-05", item))
        XCTAssertTrue(found("2024年5月", item))
        XCTAssertTrue(found("may 2024", item), "Month and year, in any case")
        XCTAssertTrue(found("alex", item), "A person's name finds their photo")
        XCTAssertTrue(found("alex 2024", item), "Each word may match a different clue")
        XCTAssertFalse(found("2023", item))
        XCTAssertFalse(found("alex 2023", item), "Every word has to match")
        XCTAssertFalse(found("2024", undated), "A photo without a date is not found by year")
        XCTAssertFalse(found("alex", undated))
    }
}

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

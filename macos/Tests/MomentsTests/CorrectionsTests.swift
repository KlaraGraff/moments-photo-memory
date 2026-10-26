import Foundation
import SwiftData
import XCTest
@testable import Moments

/// Correcting what the automatic organizing got wrong: dates and time zones,
/// place names and duplicate places, and who a face is. Every correction can
/// be undone exactly.
@MainActor
final class CorrectionsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let hour: TimeInterval = 60 * 60

    /// Held for the whole test: a ModelContext whose container is released crashes.
    private var container: ModelContainer?

    private func makeContext() throws -> ModelContext {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    // MARK: Date and time

    func testAdjustingSeveralPhotosSetsTheEarliestAndKeepsTheSpacing() throws {
        let context = try makeContext()
        let first = MediaItem(id: "a", captureDate: base)
        let second = MediaItem(id: "b", captureDate: base.addingTimeInterval(2 * hour))
        let third = MediaItem(id: "c", captureDate: base.addingTimeInterval(26 * hour))
        [first, second, third].forEach(context.insert)

        // The camera's clock was a year and a day behind.
        let target = base.addingTimeInterval((365 + 1) * 24 * hour)
        DateTimeAdjustment.apply(to: [third, first, second], referenceDate: target, timeZone: nil)

        XCTAssertEqual(first.effectiveCaptureDate, target)
        XCTAssertEqual(second.effectiveCaptureDate, target.addingTimeInterval(2 * hour))
        XCTAssertEqual(third.effectiveCaptureDate, target.addingTimeInterval(26 * hour))
        // The camera's own time stays to go back to.
        XCTAssertEqual(first.captureDate, base)
        XCTAssertEqual(first.timeConfidence, .userCorrected)
    }

    func testAChangedTimeZoneKeepsTheClockTimeAndSetsTheDay() throws {
        let context = try makeContext()
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let photo = MediaItem(id: "a", captureDate: base, timeZoneIdentifier: shanghai.identifier)
        context.insert(photo)

        let sameClockInTokyo = DateTimeAdjustment.keepingClockTime(base, from: shanghai, to: tokyo)
        XCTAssertEqual(sameClockInTokyo, base.addingTimeInterval(-hour))
        DateTimeAdjustment.apply(to: [photo], referenceDate: sameClockInTokyo, timeZone: tokyo)

        XCTAssertEqual(photo.timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(photo.effectiveCaptureDate, sameClockInTokyo)
        XCTAssertEqual(PhotoDateEditor.timeText(photo.effectiveCaptureDate!, in: photo.captureTimeZone),
                       PhotoDateEditor.timeText(base, in: shanghai))
        XCTAssertEqual(photo.localDayKey, DateTimeAdjustment.dayKey(for: sameClockInTokyo, in: tokyo))
    }

    func testOnlyAZoneChangeStillCountsAsTheUsersCorrection() throws {
        let context = try makeContext()
        let photo = MediaItem(id: "a", captureDate: base, timeZoneIdentifier: "Asia/Shanghai")
        context.insert(photo)
        // Same moment, new zone: the camera's clock was on home time.
        DateTimeAdjustment.apply(to: [photo], referenceDate: base, timeZone: TimeZone(identifier: "Asia/Tokyo"))
        // Imports leave the time zone and day of a corrected photo alone.
        XCTAssertNotNil(photo.userCorrectedCaptureDateUTC)
        XCTAssertEqual(photo.timeZoneIdentifier, "Asia/Tokyo")
    }

    func testAZoneFromAnEarlierCorrectionStaysProtected() throws {
        let context = try makeContext()
        let photo = MediaItem(id: "a", captureDate: base, timeZoneIdentifier: "Asia/Shanghai")
        context.insert(photo)
        DateTimeAdjustment.apply(to: [photo], referenceDate: base.addingTimeInterval(hour), timeZone: TimeZone(identifier: "Asia/Tokyo"))
        // Back to the camera's moment, still in Tokyo: the zone is still the person's.
        DateTimeAdjustment.apply(to: [photo], referenceDate: base, timeZone: nil)
        XCTAssertNotNil(photo.userCorrectedCaptureDateUTC)
        XCTAssertEqual(photo.timeZoneIdentifier, "Asia/Tokyo")
    }

    func testUseOriginalGoesBackToTheCamerasZone() throws {
        let context = try makeContext()
        let photo = MediaItem(id: "a", captureDate: base, localTimeZoneOffsetMinutes: 120, timeZoneIdentifier: "Asia/Tokyo")
        context.insert(photo)
        DateTimeAdjustment.apply(to: [photo], referenceDate: base.addingTimeInterval(hour), timeZone: nil)
        DateTimeAdjustment.revert([photo])
        XCTAssertNil(photo.userCorrectedCaptureDateUTC)
        XCTAssertEqual(photo.captureTimeZone.secondsFromGMT(for: base), 120 * 60)
    }

    func testAdjustingBackToTheCameraTimeDropsTheCorrection() throws {
        let context = try makeContext()
        let photo = MediaItem(id: "a", captureDate: base)
        context.insert(photo)
        DateTimeAdjustment.apply(to: [photo], referenceDate: base.addingTimeInterval(hour), timeZone: nil)
        DateTimeAdjustment.apply(to: [photo], referenceDate: base, timeZone: nil)
        XCTAssertNil(photo.userCorrectedCaptureDateUTC)
        XCTAssertEqual(photo.timeConfidence, .exact)
    }

    func testMovingPhotosMovesTheirTripAndUndoPutsEverythingBack() throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "Coast", startDate: base, endDate: base.addingTimeInterval(hour))
        context.insert(trip)
        let first = MediaItem(id: "a", captureDate: base, trip: trip, timeZoneIdentifier: "Europe/Berlin")
        let second = MediaItem(id: "b", captureDate: base.addingTimeInterval(hour), trip: trip)
        [first, second].forEach(context.insert)
        try context.save()
        let dayBefore = first.localDayKey

        let later = base.addingTimeInterval(30 * 24 * hour)
        let snapshot = DateTimeAdjustment.apply(to: [first, second], referenceDate: later, timeZone: TimeZone(identifier: "Asia/Tokyo"))
        try context.save()
        XCTAssertEqual(trip.startDate, later)
        XCTAssertEqual(trip.endDate, later.addingTimeInterval(hour))
        XCTAssertEqual(trip.orderedItems.map(\.id), ["a", "b"])

        DateTimeAdjustment.restore(snapshot, context: context)
        XCTAssertEqual(first.effectiveCaptureDate, base)
        XCTAssertNil(second.userCorrectedCaptureDateUTC)
        XCTAssertEqual(first.timeZoneIdentifier, "Europe/Berlin")
        XCTAssertEqual(first.localDayKey, dayBefore)
        XCTAssertEqual(trip.startDate, base)
        XCTAssertEqual(trip.endDate, base.addingTimeInterval(hour))
    }

    func testUseOriginalTimesRevertsOnlyCorrectedPhotos() throws {
        let context = try makeContext()
        let corrected = MediaItem(id: "a", captureDate: base, userCorrectedCaptureDateUTC: base.addingTimeInterval(hour), timeConfidenceRaw: ImportTimeConfidence.userCorrected.rawValue)
        let untouched = MediaItem(id: "b", captureDate: base)
        [corrected, untouched].forEach(context.insert)
        let snapshot = DateTimeAdjustment.revert([corrected, untouched])
        XCTAssertEqual(snapshot.items.map(\.id), ["a"])
        XCTAssertEqual(corrected.effectiveCaptureDate, base)
    }

    func testCorrectedTimesOrderTheTimelineAndTheMap() throws {
        let context = try makeContext()
        let early = MediaItem(id: "early", captureDate: base)
        let late = MediaItem(id: "late", captureDate: base.addingTimeInterval(hour))
        [early, late].forEach(context.insert)
        DateTimeAdjustment.apply(to: [early], referenceDate: base.addingTimeInterval(2 * hour), timeZone: nil)

        XCTAssertEqual(TimelineItemSnapshot(item: early).date, base.addingTimeInterval(2 * hour))
        let stops = PlacesViewModel().photoStops(from: [early, late], visibleItemIDs: nil)
        XCTAssertEqual(stops.map(\.id), ["late", "early"])
    }

    // MARK: Places

    func testPlacesWithTheSameNameAreOnePlaceInTheFilter() throws {
        let context = try makeContext()
        let kyoto = Place(id: "p1", name: "Kyoto", kind: .city)
        let kyotoAgain = Place(id: "p2", name: "kyoto ", kind: .city)
        [kyoto, kyotoAgain].forEach(context.insert)
        let a = MediaItem(id: "a", captureDate: base, place: kyoto)
        let b = MediaItem(id: "b", captureDate: base, place: kyotoAgain)
        [a, b].forEach(context.insert)

        let groups = PlaceNames.groups(for: [a, b])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].itemIDs), ["a", "b"])
        var criteria = LibraryFilterCriteria()
        criteria.placeID = groups[0].id
        XCTAssertEqual(LibraryFilterEngine.filteredItems([a, b], by: criteria).map(\.id).sorted(), ["a", "b"])
    }

    func testRenamingAPlaceRenamesItEverywhereAndImportsKeepTheName() throws {
        let context = try makeContext()
        let city = Place(id: "city", name: "Kyōto-shi", kind: .city)
        let spot = Place(id: "s-1a2b3c", name: "Spot 1a2b3c", kind: .spot, parent: city)
        [city, spot].forEach(context.insert)
        let a = MediaItem(id: "a", captureDate: base, place: spot)
        let b = MediaItem(id: "b", captureDate: base, place: city)
        [a, b].forEach(context.insert)
        try context.save()

        let key = PlaceNames.key("Kyōto-shi")
        let changes = PlaceNames.rename(key: key, to: "京都", items: [a, b], context: context)
        try context.save()

        XCTAssertEqual(a.namedPlace, "京都")
        XCTAssertEqual(b.namedPlace, "京都")
        // The import's own name stays, so the next import still finds the place.
        XCTAssertEqual(city.name, "Kyōto-shi")
        XCTAssertEqual(PlaceNames.options(for: [a, b]).map(\.name), ["京都"])

        PlaceNames.restore(changes, context: context)
        try context.save()
        XCTAssertEqual(a.namedPlace, "Kyōto-shi")
        XCTAssertNil(city.localNameOverride)
    }

    func testMergingGivesThePlacesOneNameAndKeepsEveryPhoto() throws {
        let context = try makeContext()
        let kyoto = Place(id: "p1", name: "Kyoto", kind: .city)
        let other = Place(id: "p2", name: "Kyōto", kind: .city)
        let osaka = Place(id: "p3", name: "Osaka", kind: .city)
        [kyoto, other, osaka].forEach(context.insert)
        let a = MediaItem(id: "a", captureDate: base, place: kyoto)
        let b = MediaItem(id: "b", captureDate: base, place: other)
        // A photo whose place was typed in by hand, and a photo elsewhere.
        let c = MediaItem(id: "c", captureDate: base, place: osaka)
        let d = MediaItem(id: "d", captureDate: base, place: osaka)
        [a, b, c, d].forEach(context.insert)
        context.insert(PlaceOverride(mediaID: "c", nameOverride: "京都", mediaItem: c))
        try context.save()
        let items = [a, b, c, d]

        let changes = PlaceNames.merge([PlaceNames.key("Kyōto"), PlaceNames.key("京都")], into: PlaceNames.key("Kyoto"), items: items, context: context)
        try context.save()

        let groups = PlaceNames.groups(for: items)
        XCTAssertEqual(groups.map(\.name), ["Kyoto", "Osaka"])
        XCTAssertEqual(Set(groups[0].itemIDs), ["a", "b", "c"])
        XCTAssertEqual(groups[1].itemIDs, ["d"])
        // Nothing is moved or deleted: each photo keeps its place.
        XCTAssertEqual(b.place?.id, "p2")
        XCTAssertEqual(c.place?.id, "p3")

        PlaceNames.restore(changes, context: context)
        try context.save()
        XCTAssertEqual(PlaceNames.groups(for: items).map(\.name).sorted(), ["Kyoto", "Kyōto", "Osaka", "京都"])
    }

    func testSmartGroupsAndPlaceDescriptionsFollowARename() throws {
        let context = try makeContext()
        let city = Place(id: "city", name: "Kyoto", kind: .city)
        context.insert(city)
        let a = MediaItem(id: "a", captureDate: base, place: city)
        context.insert(a)
        let key = PlaceNames.key("Kyoto")
        let group = UserGroup(name: "Kyoto days", kind: .smart, rules: UserGroupRuleSet(rules: [UserGroupRule(field: .place, value: PlaceNames.optionPrefix + key)]))
        context.insert(group)
        let note = PlaceNote(placeName: "Kyoto", text: "Synthetic description")
        context.insert(note)
        try context.save()

        let changes = PlaceNames.rename(key: key, to: "京都", items: [a], context: context)
        XCTAssertEqual(group.rules.rules.first?.value, PlaceNames.optionPrefix + PlaceNames.key("京都"))
        XCTAssertTrue(UserGroupRuleEngine.matches(a, ruleSet: group.rules))
        XCTAssertEqual(note.placeKey, PlaceNote.key(for: "京都"))

        PlaceNames.restore(changes, context: context)
        XCTAssertEqual(group.rules.rules.first?.value, PlaceNames.optionPrefix + key)
        XCTAssertEqual(note.placeName, "Kyoto")
    }

    func testRenamingBackToTheImportedNameRemovesTheRename() throws {
        let context = try makeContext()
        let city = Place(id: "city", name: "Lisbon", kind: .city)
        context.insert(city)
        let a = MediaItem(id: "a", captureDate: base, place: city)
        context.insert(a)
        PlaceNames.rename(key: PlaceNames.key("Lisbon"), to: "Lisboa", items: [a], context: context)
        PlaceNames.rename(key: PlaceNames.key("Lisboa"), to: "Lisbon", items: [a], context: context)
        XCTAssertNil(city.correctedName)
        XCTAssertEqual(a.namedPlace, "Lisbon")
    }

    func testACorrectedPhotoLeavesItsOldPlace() throws {
        let context = try makeContext()
        let osaka = Place(id: "p", name: "Osaka", kind: .city)
        context.insert(osaka)
        let a = MediaItem(id: "a", captureDate: base, place: osaka)
        let b = MediaItem(id: "b", captureDate: base, place: osaka)
        [a, b].forEach(context.insert)
        context.insert(PlaceOverride(mediaID: "a", nameOverride: "Nara", mediaItem: a))
        XCTAssertFalse(PlaceNames.matches(a, key: PlaceNames.key("Osaka")))
        XCTAssertTrue(PlaceNames.matches(a, key: PlaceNames.key("nara")))
        XCTAssertTrue(PlaceNames.matches(b, key: PlaceNames.key("Osaka")))
    }

    func testFiltersSavedBeforeNamesStillWork() throws {
        let context = try makeContext()
        let city = Place(id: "city", name: "Porto", kind: .city)
        let spot = Place(id: "s-4d5e6f", name: "Spot 4d5e6f", kind: .spot, parent: city)
        [city, spot].forEach(context.insert)
        let a = MediaItem(id: "a", captureDate: base, place: spot)
        context.insert(a)
        XCTAssertEqual(PlaceNames.optionID(forLegacy: "city", items: [a]), PlaceNames.optionPrefix + PlaceNames.key("Porto"))
        XCTAssertEqual(PlaceNames.optionID(forLegacy: "override:Café", items: [a]), PlaceNames.optionPrefix + PlaceNames.key("Café"))
        var criteria = LibraryFilterCriteria()
        criteria.placeID = "city"
        XCTAssertEqual(LibraryFilterEngine.filteredItems([a], by: criteria).map(\.id), ["a"])
    }

    // MARK: People

    func testThisIsntAnnaItsBenMovesTheFaceAndRemembers() throws {
        let context = try makeContext()
        let anna = Person(id: "anna", name: "Anna")
        let ben = Person(id: "ben", name: "Ben")
        [anna, ben].forEach(context.insert)
        let wrong = FaceObservation(id: "f1", mediaID: "m1", rect: (0.1, 0.1, 0.2, 0.2), embedding: Data(), cropData: Data(), quality: 1, personID: "anna", assignmentSource: "auto")
        let annaToo = FaceObservation(id: "f2", mediaID: "m2", rect: (0.1, 0.1, 0.2, 0.2), embedding: Data(), cropData: Data(), quality: 1, personID: "anna", confirmed: true)
        [wrong, annaToo].forEach(context.insert)
        try context.save()

        let snapshot = try XCTUnwrap(FaceCorrection.reassign(wrong, to: ben, observations: [wrong, annaToo]))
        XCTAssertEqual(wrong.personID, "ben")
        XCTAssertTrue(wrong.confirmed)
        XCTAssertEqual(wrong.assignmentSource, "user")
        XCTAssertEqual(wrong.rejectedPersonIDSet, ["anna"])
        XCTAssertFalse(anna.hidden, "Anna still has another face")

        FaceCorrection.restore(snapshot, context: context)
        XCTAssertEqual(wrong.personID, "anna")
        XCTAssertFalse(wrong.confirmed)
        XCTAssertEqual(wrong.assignmentSource, "auto")
        XCTAssertTrue(wrong.rejectedPersonIDSet.isEmpty)
    }

    func testMovingSomeonesOnlyFaceHidesThemUntilUndo() throws {
        let context = try makeContext()
        let anna = Person(id: "anna", name: "Anna")
        let ben = Person(id: "ben", name: "Ben")
        [anna, ben].forEach(context.insert)
        let face = FaceObservation(id: "f1", mediaID: "m1", rect: (0.1, 0.1, 0.2, 0.2), embedding: Data(), cropData: Data(), quality: 1, personID: "anna")
        context.insert(face)
        try context.save()

        let snapshot = try XCTUnwrap(FaceCorrection.reassign(face, to: ben, observations: [face]))
        XCTAssertTrue(anna.hidden)
        FaceCorrection.restore(snapshot, context: context)
        XCTAssertFalse(anna.hidden)
        XCTAssertEqual(face.personID, "anna")
    }

    func testANewNameCreatesThePersonAndUndoRemovesThem() throws {
        let context = try makeContext()
        let anna = Person(id: "anna", name: "Anna")
        context.insert(anna)
        let face = FaceObservation(id: "f1", mediaID: "m1", rect: (0.1, 0.1, 0.2, 0.2), embedding: Data(), cropData: Data(), quality: 1, personID: "anna")
        let other = FaceObservation(id: "f2", mediaID: "m2", rect: (0.1, 0.1, 0.2, 0.2), embedding: Data(), cropData: Data(), quality: 1, personID: "anna")
        [face, other].forEach(context.insert)
        try context.save()

        let snapshot = try XCTUnwrap(FaceCorrection.reassign(face, toName: " Carla ", people: [anna], observations: [face, other], context: context))
        try context.save()
        let carla = try XCTUnwrap(try context.fetch(FetchDescriptor<Person>()).first { $0.name == "Carla" })
        XCTAssertEqual(face.personID, carla.id)

        FaceCorrection.restore(snapshot, context: context)
        try context.save()
        XCTAssertEqual(face.personID, "anna")
        XCTAssertNil(try context.fetch(FetchDescriptor<Person>()).first { $0.name == "Carla" })
    }

    func testASameNamedPersonIsJoinedNotDuplicated() throws {
        let context = try makeContext()
        let anna = Person(id: "anna", name: "Anna")
        let ben = Person(id: "ben", name: "Ben")
        [anna, ben].forEach(context.insert)
        let face = FaceObservation(id: "f1", mediaID: "m1", rect: (0.1, 0.1, 0.2, 0.2), embedding: Data(), cropData: Data(), quality: 1, personID: "anna")
        context.insert(face)
        FaceCorrection.reassign(face, toName: "ben", people: [anna, ben], observations: [face], context: context)
        XCTAssertEqual(face.personID, "ben")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Person>()).count, 2)
    }

    // MARK: Undo

    func testACorrectionIsUndoneOnlyOnce() throws {
        let context = try makeContext()
        var runs = 0
        let correction = CorrectionUndo(message: "", actionName: "") { _ in runs += 1 }
        correction.perform(in: context)
        correction.perform(in: context)
        XCTAssertEqual(runs, 1)
        XCTAssertTrue(correction.isDone)
    }
}

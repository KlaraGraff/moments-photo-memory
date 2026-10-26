import Foundation
import SwiftData
import XCTest
@testable import Moments

@MainActor
final class PhotoInfoEditingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

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

    func testAdjustingTheDateKeepsTheCameraTimeToGoBackTo() throws {
        let context = try makeContext()
        let item = MediaItem(id: "a", captureDate: base)
        context.insert(item)

        let corrected = base.addingTimeInterval(3 * 60 * 60)
        PhotoInfoEditing.setCaptureDate(corrected, on: item, now: base)
        XCTAssertEqual(item.effectiveCaptureDate, corrected)
        XCTAssertEqual(item.captureDate, base)
        XCTAssertEqual(item.timeConfidence, .userCorrected)

        PhotoInfoEditing.revertCaptureDate(on: item, now: base)
        XCTAssertEqual(item.effectiveCaptureDate, base)
        XCTAssertNil(item.userCorrectedCaptureDateUTC)
        XCTAssertEqual(item.timeConfidence, .exact)
    }

    func testSettingTheCameraTimeAgainClearsTheCorrection() throws {
        let context = try makeContext()
        let item = MediaItem(id: "a", captureDate: base)
        context.insert(item)
        PhotoInfoEditing.setCaptureDate(base.addingTimeInterval(60), on: item)
        PhotoInfoEditing.setCaptureDate(base, on: item)
        XCTAssertNil(item.userCorrectedCaptureDateUTC)
    }

    func testTypingAPlaceCorrectsItAndEmptyGoesBack() throws {
        let context = try makeContext()
        let harbor = Place(name: "Harbor", kind: .city)
        context.insert(harbor)
        let item = MediaItem(id: "a", captureDate: base, place: harbor)
        context.insert(item)

        PhotoInfoEditing.setPlaceName("  Blue cafe ", on: item, context: context)
        XCTAssertEqual(item.namedPlace, "Blue cafe")
        PhotoInfoEditing.setPlaceName("Pier", on: item, context: context)
        XCTAssertEqual(item.namedPlace, "Pier")
        XCTAssertEqual(try context.fetch(FetchDescriptor<PlaceOverride>()).count, 1, "A second change reuses the correction")

        PhotoInfoEditing.setPlaceName("", on: item, context: context)
        try context.save()
        XCTAssertEqual(item.namedPlace, "Harbor")
        XCTAssertTrue(try context.fetch(FetchDescriptor<PlaceOverride>()).isEmpty)
    }

    func testTypingThePlacesOwnNameAddsNoCorrection() throws {
        let context = try makeContext()
        let harbor = Place(name: "Harbor", kind: .city)
        context.insert(harbor)
        let item = MediaItem(id: "a", place: harbor)
        context.insert(item)
        PhotoInfoEditing.setPlaceName("Harbor", on: item, context: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<PlaceOverride>()).isEmpty)
    }

    func testMovingAPhotoBetweenTripsAndRenamingOne() throws {
        let context = try makeContext()
        let spring = Trip(id: "t1", name: "Trip 2026-04-02")
        let summer = Trip(id: "t2", name: "Trip 2026-08-20")
        context.insert(spring)
        context.insert(summer)
        let item = MediaItem(id: "a", trip: spring)
        context.insert(item)

        PhotoInfoEditing.setTrip(summer, on: item)
        XCTAssertEqual(item.trip?.id, "t2")
        XCTAssertEqual(item.tripID, "t2")
        PhotoInfoEditing.setTrip(nil, on: item)
        XCTAssertNil(item.trip)
        XCTAssertNil(item.tripID)

        PhotoInfoEditing.renameTrip(summer, to: " Morocco ")
        XCTAssertEqual(summer.effectiveName, "Morocco")
        PhotoInfoEditing.renameTrip(summer, to: "")
        XCTAssertNil(summer.overrideName)
        XCTAssertEqual(summer.effectiveName, "Trip 2026-08-20")
    }

    func testNewTripHoldsThePhotoAndSpansItsDay() throws {
        let context = try makeContext()
        let item = MediaItem(id: "a", captureDate: base)
        context.insert(item)
        XCTAssertNil(PhotoInfoEditing.moveToNewTrip(named: "  ", item: item, context: context))
        let trip = try XCTUnwrap(PhotoInfoEditing.moveToNewTrip(named: "Fes Aug 21", item: item, context: context))
        XCTAssertEqual(item.trip?.id, trip.id)
        XCTAssertEqual(item.tripID, trip.id)
        XCTAssertEqual(trip.startDate, base)
        XCTAssertEqual(trip.endDate, base)
        XCTAssertFalse(trip.isSuggestion)
    }

    func testSwipeTurnsThePageWhenFarOrFastEnough() {
        // Slid a third of the way: next photo.
        XCTAssertEqual(ViewerSwipe.direction(offset: -200, width: 600, lastStep: -1, hasPrevious: true, hasNext: true), 1)
        XCTAssertEqual(ViewerSwipe.direction(offset: 200, width: 600, lastStep: 1, hasPrevious: true, hasNext: true), -1)
        // A short, slow slide springs back.
        XCTAssertEqual(ViewerSwipe.direction(offset: -30, width: 600, lastStep: -2, hasPrevious: true, hasNext: true), 0)
        // A short quick flick still turns.
        XCTAssertEqual(ViewerSwipe.direction(offset: -30, width: 600, lastStep: -12, hasPrevious: true, hasNext: true), 1)
        // Far enough wins over a last flick back; a short slide flicked back does not turn.
        XCTAssertEqual(ViewerSwipe.direction(offset: -200, width: 600, lastStep: 12, hasPrevious: true, hasNext: true), 1)
        XCTAssertEqual(ViewerSwipe.direction(offset: -30, width: 600, lastStep: 12, hasPrevious: true, hasNext: true), 0)
        // Nothing past the last photo.
        XCTAssertEqual(ViewerSwipe.direction(offset: -300, width: 600, lastStep: -12, hasPrevious: true, hasNext: false), 0)
    }

    // A 400×300 photo fitted into a 400×300 area.
    private let fitted = CGSize(width: 400, height: 300)
    private let area = CGSize(width: 400, height: 300)

    func testZoomKeepsThePointUnderThePointer() {
        var zoom = ViewerZoom()
        let anchor = CGPoint(x: 300, y: 150)
        zoom.zoom(to: 2, anchor: anchor, fitted: fitted, area: area)
        XCTAssertEqual(zoom.scale, 2)
        // The point 100 to the right of centre stays under the pointer.
        XCTAssertEqual(zoom.offset.width, -100, accuracy: 0.001)
        XCTAssertEqual(zoom.offset.height, 0, accuracy: 0.001)
    }

    func testZoomIsClampedAndFittingCentres() {
        var zoom = ViewerZoom()
        zoom.zoom(to: 40, anchor: .zero, fitted: fitted, area: area)
        XCTAssertEqual(zoom.scale, ViewerZoom.maximum)
        zoom.zoom(to: 0.2, anchor: .zero, fitted: fitted, area: area)
        XCTAssertEqual(zoom.scale, 1)
        XCTAssertEqual(zoom.offset, .zero)
        XCTAssertFalse(zoom.isZoomed)
    }

    func testPanStopsAtThePhotosEdges() {
        var zoom = ViewerZoom()
        zoom.zoom(to: 2, anchor: CGPoint(x: 200, y: 150), fitted: fitted, area: area)
        zoom.pan(by: CGSize(width: 1000, height: -1000), fitted: fitted, area: area)
        XCTAssertEqual(zoom.offset.width, 200, accuracy: 0.001)
        XCTAssertEqual(zoom.offset.height, -150, accuracy: 0.001)
        // A tall photo narrower than the area stays centred across.
        var tall = ViewerZoom()
        let narrow = CGSize(width: 150, height: 300)
        tall.zoom(to: 2, anchor: CGPoint(x: 200, y: 150), fitted: narrow, area: area)
        tall.pan(by: CGSize(width: 500, height: 0), fitted: narrow, area: area)
        XCTAssertEqual(tall.offset.width, 0, accuracy: 0.001)
    }
}

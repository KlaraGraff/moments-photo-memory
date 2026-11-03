import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// The "look place names up again" pass: which cities lose their name, and
/// which keep it because this person typed it.
@MainActor
final class PlaceReorganizeTests: XCTestCase {
    /// Kept for the length of a test, so its main context stays valid.
    private var container: ModelContainer?

    private func makeContext() throws -> ModelContext {
        let container: ModelContainer = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    func testForgetAutoNamesClearsACityNamedByTheGeocoder() throws {
        let context: ModelContext = try makeContext()
        let city = Place(
            id: "city-auto",
            name: "Synthetic Town",
            kind: .city,
            latitude: 0.01,
            longitude: 0.01
        )
        context.insert(city)
        try context.save()

        let cleared: Int = try PlaceReorganize.forgetAutoNames(context: context)

        XCTAssertEqual(cleared, 1)
        XCTAssertEqual(city.name, "")
    }

    func testForgetAutoNamesKeepsANameTheOwnerTyped() throws {
        let context: ModelContext = try makeContext()
        let city = Place(
            id: "city-renamed",
            name: "Synthetic Town",
            kind: .city,
            latitude: 0.02,
            longitude: 0.02
        )
        context.insert(city)
        // A rename writes a place-wide override; the stored name stays.
        let rename = PlaceOverride(
            placeID: city.id,
            nameOverride: "Our own town",
            place: city
        )
        context.insert(rename)
        try context.save()

        let cleared: Int = try PlaceReorganize.forgetAutoNames(context: context)

        XCTAssertEqual(cleared, 0)
        XCTAssertEqual(city.name, "Synthetic Town")
        XCTAssertEqual(city.correctedName, "Our own town")
    }

    func testForgetAutoNamesIgnoresAreasAndSpots() throws {
        let context: ModelContext = try makeContext()
        let area = Place(
            id: "area-1",
            name: "Synthetic Area",
            kind: .area,
            latitude: 0.03,
            longitude: 0.03
        )
        let spot = Place(
            id: "spot-abc123",
            name: "Synthetic Spot",
            kind: .spot,
            latitude: 0.04,
            longitude: 0.04
        )
        context.insert(area)
        context.insert(spot)
        try context.save()

        let cleared: Int = try PlaceReorganize.forgetAutoNames(context: context)

        XCTAssertEqual(cleared, 0)
        XCTAssertEqual(area.name, "Synthetic Area")
        XCTAssertEqual(spot.name, "Synthetic Spot")
    }

    func testForgetAutoNamesLeavesACityWithoutCoordinates() throws {
        let context: ModelContext = try makeContext()
        let city = Place(id: "city-nowhere", name: "Synthetic Town", kind: .city)
        context.insert(city)
        try context.save()

        let cleared: Int = try PlaceReorganize.forgetAutoNames(context: context)

        XCTAssertEqual(cleared, 0)
        XCTAssertEqual(city.name, "Synthetic Town")
    }
}

/// "Reorganize everything" throws away what Vision measured; the stack
/// decisions this person made live on `UserGroup` records and are untouched.
@MainActor
final class PhotoStackForgetAllTests: XCTestCase {
    /// No file: nothing is read from or written to Application Support.
    private func makeStore() -> PhotoStackAnalysisStore {
        PhotoStackAnalysisStore(fileURL: nil)
    }

    private func analysis(sharpness: Double) -> PhotoStackAnalysis {
        let quality = StackQuality(sharpness: sharpness)
        return PhotoStackAnalysis(featurePrint: nil, quality: quality)
    }

    func testForgetAllDropsEntriesAndMovesRevision() {
        let store: PhotoStackAnalysisStore = makeStore()
        let first: PhotoStackAnalysis = analysis(sharpness: 0.5)
        let second: PhotoStackAnalysis = analysis(sharpness: 0.75)
        let measured: [String: PhotoStackAnalysis] = ["photo-1": first, "photo-2": second]
        store.merge(measured)
        let revisionBefore: Int = store.revision
        XCTAssertEqual(store.entries.count, 2)

        store.forgetAll()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.revision, revisionBefore + 1)
    }
}

import Foundation
import SwiftData
import XCTest
@testable import Moments

/// The scan store must be made and dropped away from the main actor, and the
/// work it reports must still be found on a synthetic in-memory store.
@MainActor
final class PeopleScanStoreReleaseTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try MomentsPersistence.makeContainer(inMemory: true)
    }

    func testHasWorkFindsPendingFaceAndScannedPhotosMakeNone() async throws {
        let container: ModelContainer = try makeContainer()
        let context: ModelContext = container.mainContext
        context.insert(MediaItem(id: "synthetic-photo-a"))
        context.insert(MediaItem(id: "synthetic-photo-b"))
        try context.save()

        // Two photos nobody has scanned yet: there is work.
        let pending: Bool = try await PeopleScanController.hasWork(container: container)
        XCTAssertTrue(pending)

        // Both scanned and stored as plain faces: nothing left to do.
        let store: PeopleScanStore = PeopleScanStore(modelContainer: container)
        let results: [PeopleScanResult] = [
            PeopleScanResult(mediaID: "synthetic-photo-a", faces: []),
            PeopleScanResult(mediaID: "synthetic-photo-b", faces: [])
        ]
        try await store.save(results: results, scannedIDs: ["synthetic-photo-a", "synthetic-photo-b"], version: 1)

        let done: Bool = try await PeopleScanController.hasWork(container: container)
        XCTAssertFalse(done)
    }

    func testHasWorkFindsPendingClusterAfterEveryPhotoWasScanned() async throws {
        let container: ModelContainer = try makeContainer()
        let context: ModelContext = container.mainContext
        context.insert(MediaItem(id: "synthetic-photo-c"))
        let face: FaceObservation = FaceObservation(
            id: "synthetic-face-c",
            mediaID: "synthetic-photo-c",
            rect: (0.1, 0.1, 0.2, 0.2),
            embedding: Data([0, 0, 128, 63]),
            cropData: Data([1]),
            quality: 0.9,
            clusterID: "pending-synthetic-face-c"
        )
        context.insert(face)
        context.insert(FaceScanRecord(id: "synthetic-photo-c"))
        try context.save()

        let pending: Bool = try await PeopleScanController.hasWork(container: container)
        XCTAssertTrue(pending, "A face still in its pending cluster is work for the next scan")
    }

    func testScanStepsStillReadAndWriteThroughTheirOwnStores() async throws {
        let container: ModelContainer = try makeContainer()
        let context: ModelContext = container.mainContext
        context.insert(MediaItem(id: "synthetic-photo-d"))
        try context.save()

        let descriptors: [PeopleMediaDescriptor] = try await PeopleScanController.pendingDescriptors(container: container)
        XCTAssertEqual(descriptors.map(\.id), ["synthetic-photo-d"])

        let results: [PeopleScanResult] = [PeopleScanResult(mediaID: "synthetic-photo-d", faces: [])]
        try await PeopleScanController.save(container: container, results: results, scannedIDs: ["synthetic-photo-d"])

        let snapshot: PeopleStoreAssignmentSnapshot = try await PeopleScanController.assignmentSnapshot(container: container)
        XCTAssertEqual(snapshot.faces.count, 0)
        XCTAssertEqual(snapshot.people.count, 0)

        try await PeopleScanController.apply(container: container, assignments: [], snapshots: [])
        let records: [FaceScanRecord] = try ModelContext(container).fetch(FetchDescriptor<FaceScanRecord>())
        XCTAssertEqual(records.map(\.id), ["synthetic-photo-d"])
    }
}

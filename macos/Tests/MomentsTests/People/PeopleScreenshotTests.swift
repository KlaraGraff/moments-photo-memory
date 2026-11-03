import Foundation
import SwiftData
import XCTest
@testable import Moments

/// Photos the system marks as screenshots never take part in People: no face
/// scan, no planner input and no card. Every ID, face and photo here is synthetic.
@MainActor
final class PeopleScreenshotTests: XCTestCase {
    private func embedding() -> Data {
        Data(repeating: 0, count: 8 * MemoryLayout<Float>.size)
    }

    private func face(_ id: String, photo: String, personID: String? = nil) -> FaceObservation {
        FaceObservation(
            id: id,
            mediaID: photo,
            rect: (0.1, 0.1, 0.2, 0.2),
            embedding: embedding(),
            cropData: Data([1, 2, 3]),
            quality: 0.8,
            personID: personID,
            clusterID: personID == nil ? "pending-\(id)" : nil,
            confirmed: personID != nil,
            assignmentSource: personID == nil ? "auto" : "user"
        )
    }

    /// A defaults domain whose grouping version is current, so `hasWork` can
    /// only be moved by the items themselves. Returns the suite name for cleanup.
    private func currentDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "PeopleScreenshotTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(PeopleScanStore.groupingVersion, forKey: PeopleScanStore.groupingVersionKey)
        return (defaults, suiteName)
    }

    /// a) A screenshot with no scan record is not pending work.
    func testScreenshotWithoutScanRecordIsNotPendingWork() async throws {
        let (defaults, suiteName) = try currentDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        context.insert(MediaItem(id: "synthetic-screenshot", isScreenshot: true))
        try context.save()

        let store = PeopleScanStore(modelContainer: container)
        let pending: [PeopleMediaDescriptor] = try await store.pendingDescriptors()
        XCTAssertTrue(pending.isEmpty, "A screenshot is never scanned for faces")
        let hasWork: Bool = try await store.hasWork(defaults: defaults)
        XCTAssertFalse(hasWork, "A screenshot alone is no pending work")
    }

    /// Control for a): a normal photo without a record is still pending work.
    func testNormalPhotoWithoutScanRecordIsStillPendingWork() async throws {
        let (defaults, suiteName) = try currentDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        context.insert(MediaItem(id: "synthetic-photo"))
        try context.save()

        let store = PeopleScanStore(modelContainer: container)
        let pending: [PeopleMediaDescriptor] = try await store.pendingDescriptors()
        XCTAssertEqual(pending.map(\.id), ["synthetic-photo"])
        let hasWork: Bool = try await store.hasWork(defaults: defaults)
        XCTAssertTrue(hasWork, "An unscanned photo is pending work")
    }

    /// b) and c): only the normal photo's face reaches the planner.
    func testAssignmentSnapshotLeavesOutFacesInScreenshots() async throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        context.insert(MediaItem(id: "synthetic-screenshot", isScreenshot: true))
        context.insert(MediaItem(id: "synthetic-photo"))
        let screenshotFace = face("screenshot-face", photo: "synthetic-screenshot", personID: "synthetic-person")
        let photoFace = face("photo-face", photo: "synthetic-photo", personID: "synthetic-person")
        context.insert(Person(id: "synthetic-person", name: "Synthetic"))
        context.insert(screenshotFace)
        context.insert(photoFace)
        try context.save()

        let store = PeopleScanStore(modelContainer: container)
        let snapshot = try await store.assignmentSnapshot()
        let faceIDs: [String] = snapshot.faces.map(\.id)
        XCTAssertEqual(faceIDs, ["photo-face"], "Only the normal photo's face is planner input")
        XCTAssertFalse(snapshot.faces.contains { $0.mediaID == "synthetic-screenshot" })

        // Nothing was deleted or rewritten: the skipped face keeps its assignment.
        let stored: [FaceObservation] = try ModelContext(container).fetch(FetchDescriptor<FaceObservation>())
        let kept = stored.first { $0.id == "screenshot-face" }
        XCTAssertEqual(kept?.personID, "synthetic-person")
        XCTAssertTrue(kept?.confirmed ?? false)
    }
}

import XCTest
@testable import MomentsCore

final class PhotosLibraryChangesTests: XCTestCase {
    func testNetDropsAnAssetAddedAndRemovedWhileClosed() {
        let net = PhotosLibraryChanges.net([
            PhotosChangeBatch(inserted: ["synthetic-a", "synthetic-b"]),
            PhotosChangeBatch(updated: ["synthetic-a"], deleted: ["synthetic-b", "synthetic-old"])
        ])
        XCTAssertEqual(net.inserted, ["synthetic-a"])
        XCTAssertEqual(net.deleted, ["synthetic-old"])
    }

    func testPendingKeepsWaitingAssetsAndSkipsImportedOrRemovedOnes() {
        let pending = PhotosLibraryChanges.pending(
            waiting: ["synthetic-waiting", "synthetic-gone"],
            inserted: ["synthetic-new", "synthetic-imported", "synthetic-waiting"],
            deleted: ["synthetic-gone"],
            alreadyImported: ["synthetic-imported"]
        )
        XCTAssertEqual(pending, ["synthetic-new", "synthetic-waiting"])
    }

    func testPlanRelinksThroughTheCloudIdentifierOnAnotherMac() {
        let entries = [
            entry("item-a", local: "old-mac/a", cloud: "cloud-a"),
            entry("item-b", local: "old-mac/b", cloud: "cloud-b"),
            entry("item-c", local: "old-mac/c", cloud: nil)
        ]
        let present: Set<String> = []
        XCTAssertEqual(
            PhotosLibraryReconciliation.cloudIdentifiersToLookUp(entries, present: present),
            ["cloud-a", "cloud-b"]
        )
        let plan = PhotosLibraryReconciliation.plan(
            entries,
            present: present,
            localForCloud: ["cloud-a": "new-mac/a"]
        )
        XCTAssertEqual(plan.relinked, ["item-a": "new-mac/a"])
        XCTAssertEqual(plan.newlyMissing, ["item-b", "item-c"])
        XCTAssertEqual(plan.foundAgain, [])
    }

    func testPlanLeavesPresentItemsAndClearsTheirMissingMark() {
        let entries = [
            entry("item-a", local: "mac/a", cloud: "cloud-a", missing: true),
            entry("item-b", local: "mac/b", cloud: "cloud-b"),
            entry("item-c", local: "mac/c", cloud: "cloud-c", missing: true)
        ]
        let plan = PhotosLibraryReconciliation.plan(entries, present: ["mac/a", "mac/b"], localForCloud: [:])
        XCTAssertEqual(plan.relinked, [:])
        XCTAssertEqual(plan.foundAgain, ["item-a"])
        // Already marked: nothing to change.
        XCTAssertEqual(plan.newlyMissing, [])
        XCTAssertEqual(
            PhotosLibraryReconciliation.cloudIdentifiersToLookUp(entries, present: ["mac/a", "mac/b"]),
            ["cloud-c"]
        )
    }

    func testPlanNeverGivesOneLocalIdentifierToTwoItems() {
        let entries = [
            entry("item-a", local: "mac/a", cloud: "cloud-a"),
            // A second record of the same photo, from another Mac.
            entry("item-b", local: "old-mac/a", cloud: "cloud-a"),
            entry("item-c", local: "old-mac/c", cloud: "cloud-c"),
            entry("item-d", local: "old-mac/d", cloud: "cloud-c")
        ]
        let plan = PhotosLibraryReconciliation.plan(
            entries,
            present: ["mac/a"],
            localForCloud: ["cloud-a": "mac/a", "cloud-c": "mac/c"]
        )
        XCTAssertEqual(plan.relinked, ["item-c": "mac/c"])
        XCTAssertEqual(plan.newlyMissing, ["item-b", "item-d"])
    }

    func testOnlyAMostlyUnknownSampleLooksLikeAnotherMac() {
        XCTAssertFalse(PhotosLibraryReconciliation.looksLikeAnotherMac(sampleCount: 0, unknownInSample: 0))
        XCTAssertFalse(PhotosLibraryReconciliation.looksLikeAnotherMac(sampleCount: 50, unknownInSample: 3))
        XCTAssertFalse(PhotosLibraryReconciliation.looksLikeAnotherMac(sampleCount: 50, unknownInSample: 25))
        XCTAssertTrue(PhotosLibraryReconciliation.looksLikeAnotherMac(sampleCount: 50, unknownInSample: 26))
    }

    private func entry(_ id: String, local: String, cloud: String?, missing: Bool = false) -> PhotosLibraryReconciliation.Entry {
        PhotosLibraryReconciliation.Entry(id: id, localIdentifier: local, cloudIdentifier: cloud, isMarkedMissing: missing)
    }
}

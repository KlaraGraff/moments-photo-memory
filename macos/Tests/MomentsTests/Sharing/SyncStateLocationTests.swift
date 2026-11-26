import Foundation
import XCTest
@testable import Moments

/// Sync state must follow the library folder, never a fixed "Moments" folder
/// that another build's library could also use.
@MainActor
final class SyncStateLocationTests: XCTestCase {
    func testSyncStateSitsInsideTheLibraryFolder() {
        let folder: URL = URL(filePath: "/tmp/Synthetic Support/Moments Sharing Test", directoryHint: .isDirectory)

        let root: URL = SharingController.stateRoot(storeFolder: folder)

        XCTAssertEqual(root.lastPathComponent, "Sync")
        XCTAssertEqual(root.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
    }

    func testThisBuildsSyncStateFollowsItsStoreFolder() throws {
        let root: URL = try XCTUnwrap(SharingController.stateRoot)
        let storeFolder: URL = MomentsPersistence.defaultStoreFolder()

        XCTAssertEqual(root.deletingLastPathComponent().standardizedFileURL, storeFolder.standardizedFileURL)
    }

    func testSharedPreviewsFollowTheStoreFolder() throws {
        let previews: URL = try XCTUnwrap(SharedPreviewFiles.defaultFolder)
        let storeFolder: URL = MomentsPersistence.defaultStoreFolder()

        XCTAssertEqual(previews.lastPathComponent, "SharedPreviews")
        XCTAssertEqual(previews.deletingLastPathComponent().standardizedFileURL, storeFolder.standardizedFileURL)
    }
}

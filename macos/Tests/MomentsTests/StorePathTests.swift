import Foundation
import XCTest
@testable import Moments

/// Store-root selection is pure path logic; these tests never touch the real
/// Application Support directory or a user's store.
final class StorePathTests: XCTestCase {
    func testPeoplePreviewKeepsLegacyStoreRoot() {
        let support = URL(fileURLWithPath: "/tmp/synthetic-application-support", isDirectory: true)

        let folder = MomentsPersistence.defaultStoreFolder(
            applicationSupportDirectory: support,
            bundleIdentifier: "org.example.Moments.peoplepreview"
        )

        XCTAssertEqual(folder.path, "/tmp/synthetic-application-support/Moments People Preview")
    }

    func testRegularBundleUsesMomentsStoreRoot() {
        let support = URL(fileURLWithPath: "/tmp/synthetic-application-support", isDirectory: true)

        let folder = MomentsPersistence.defaultStoreFolder(
            applicationSupportDirectory: support,
            bundleIdentifier: "org.example.Moments"
        )

        XCTAssertEqual(folder.path, "/tmp/synthetic-application-support/Moments")
    }
}

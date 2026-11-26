import Foundation
import XCTest
@testable import Moments

/// The switch from placeholder bundle identifiers to the release one. Every
/// test uses its own defaults suite and synthetic paths; nothing touches the
/// real Application Support folder or the host's own defaults. The suite also
/// stands in for the app's own domain (its name is not a placeholder).
final class AppIdentityMigrationTests: XCTestCase {
    private let releaseID = "com.momentsphotomemory.Moments"
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "AppIdentityMigrationTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testPlaceholderIdentifiersAreRecognised() {
        XCTAssertTrue(AppIdentityMigration.isPlaceholder("org.example.Moments"))
        XCTAssertTrue(AppIdentityMigration.isPlaceholder("org.example.Moments.peoplepreview"))
        XCTAssertTrue(AppIdentityMigration.isPlaceholder(nil))
        XCTAssertFalse(AppIdentityMigration.isPlaceholder(releaseID))
    }

    func testImportPrefersThePreviewBuildsSettings() {
        let legacy: [String: [String: Any]] = [
            "org.example.Moments.peoplepreview": ["trip.cover": "photo-a", "people.ignored": ["g1", "g2"]],
            "org.example.Moments": ["trip.cover": "photo-b", "only.in.dev": true]
        ]
        let reader: (String) -> [String: Any]? = { (domain: String) -> [String: Any]? in legacy[domain] }

        let source = AppIdentityMigration.importLegacyPreferences(
            into: defaults, ownDomain: suiteName, readDomain: reader
        )

        XCTAssertEqual(source, "org.example.Moments.peoplepreview")
        XCTAssertEqual(defaults.string(forKey: "trip.cover"), "photo-a")
        XCTAssertEqual(defaults.stringArray(forKey: "people.ignored"), ["g1", "g2"])
        // Only one domain is copied, never a blend of two builds.
        XCTAssertNil(defaults.object(forKey: "only.in.dev"))
    }

    func testImportFallsBackToTheDevelopmentBuild() {
        let reader: (String) -> [String: Any]? = { (domain: String) -> [String: Any]? in
            domain == "org.example.Moments" ? ["only.in.dev": true] : nil
        }

        let source = AppIdentityMigration.importLegacyPreferences(
            into: defaults, ownDomain: suiteName, readDomain: reader
        )

        XCTAssertEqual(source, "org.example.Moments")
        XCTAssertTrue(defaults.bool(forKey: "only.in.dev"))
    }

    func testImportNeverOverwritesAndRunsOnce() {
        defaults.set("mine", forKey: "trip.cover")
        let ownDomain: String = suiteName
        var reads = 0
        let reader: (String) -> [String: Any]? = { (_: String) -> [String: Any]? in
            reads += 1
            return ["trip.cover": "old", "filter": "beach"]
        }

        // A value already in the suite counts as "set by this build".
        let first = AppIdentityMigration.importLegacyPreferences(
            into: defaults, ownDomain: ownDomain, readDomain: reader
        )
        let second = AppIdentityMigration.importLegacyPreferences(
            into: defaults, ownDomain: ownDomain, readDomain: reader
        )

        XCTAssertEqual(first, "org.example.Moments.peoplepreview")
        XCTAssertNil(second)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(defaults.string(forKey: "trip.cover"), "mine")
        XCTAssertEqual(defaults.string(forKey: "filter"), "beach")
    }

    func testImportRecordsAnEmptySourceWhenNoEarlierBuildRan() {
        let ownDomain: String = suiteName
        let reader: (String) -> [String: Any]? = { (_: String) -> [String: Any]? in nil }

        let source = AppIdentityMigration.importLegacyPreferences(
            into: defaults, ownDomain: ownDomain, readDomain: reader
        )

        XCTAssertEqual(source, "")
        XCTAssertEqual(defaults.string(forKey: AppIdentityMigration.importedFromKey), "")
    }

    func testPlaceholderBuildsNeverImport() {
        let reader: (String) -> [String: Any]? = { (_: String) -> [String: Any]? in ["x": 1] }

        let source = AppIdentityMigration.importLegacyPreferences(
            into: defaults, ownDomain: "org.example.Moments", readDomain: reader
        )

        XCTAssertNil(source)
        XCTAssertNil(defaults.object(forKey: "x"))
    }

    func testReleaseBuildAdoptsThePreviewLibrary() {
        let exists: (String) -> Bool = { (folder: String) -> Bool in folder == "Moments People Preview" }

        let name = AppIdentityMigration.storeFolderName(
            bundleIdentifier: releaseID, defaults: defaults, storeExists: exists
        )

        XCTAssertEqual(name, "Moments People Preview")
        XCTAssertEqual(defaults.string(forKey: AppIdentityMigration.storeFolderKey), "Moments People Preview")
    }

    func testReleaseBuildWithoutPreviewLibraryUsesMoments() {
        let exists: (String) -> Bool = { (_: String) -> Bool in false }

        let name = AppIdentityMigration.storeFolderName(
            bundleIdentifier: releaseID, defaults: defaults, storeExists: exists
        )

        XCTAssertEqual(name, "Moments")
    }

    func testReleaseBuildKeepsItsFirstChoice() {
        let none: (String) -> Bool = { (_: String) -> Bool in false }
        let previewAppears: (String) -> Bool = { (folder: String) -> Bool in folder == "Moments People Preview" }

        let first = AppIdentityMigration.storeFolderName(
            bundleIdentifier: releaseID, defaults: defaults, storeExists: none
        )
        let later = AppIdentityMigration.storeFolderName(
            bundleIdentifier: releaseID, defaults: defaults, storeExists: previewAppears
        )

        XCTAssertEqual(first, "Moments")
        XCTAssertEqual(later, "Moments")
    }

    func testPlaceholderBuildsKeepTheirFoldersAndRecordNothing() {
        let exists: (String) -> Bool = { (_: String) -> Bool in true }

        let preview = AppIdentityMigration.storeFolderName(
            bundleIdentifier: "org.example.Moments.peoplepreview", defaults: defaults, storeExists: exists
        )
        let development = AppIdentityMigration.storeFolderName(
            bundleIdentifier: "org.example.Moments", defaults: defaults, storeExists: exists
        )

        XCTAssertEqual(preview, "Moments People Preview")
        XCTAssertEqual(development, "Moments")
        XCTAssertNil(defaults.object(forKey: AppIdentityMigration.storeFolderKey))
    }

    func testNotRecordingLeavesTheChoiceOpen() {
        let exists: (String) -> Bool = { (_: String) -> Bool in false }

        let name = AppIdentityMigration.storeFolderName(
            bundleIdentifier: releaseID, defaults: defaults, record: false, storeExists: exists
        )

        XCTAssertEqual(name, "Moments")
        XCTAssertNil(defaults.object(forKey: AppIdentityMigration.storeFolderKey))
    }

    func testARecordedFolderOfItsOwnIsHonoured() {
        defaults.set("Moments Sharing Test", forKey: AppIdentityMigration.storeFolderKey)
        let previewExists: (String) -> Bool = { (folder: String) -> Bool in folder == "Moments People Preview" }

        let name = AppIdentityMigration.storeFolderName(
            bundleIdentifier: "com.momentsphotomemory.Moments.sharingtest",
            defaults: defaults,
            storeExists: previewExists
        )

        XCTAssertEqual(name, "Moments Sharing Test")
        XCTAssertEqual(defaults.string(forKey: AppIdentityMigration.storeFolderKey), "Moments Sharing Test")
    }

    func testARecordedPathOrHiddenNameIsReplaced() {
        let none: (String) -> Bool = { (_: String) -> Bool in false }
        let unsafe: [String] = ["", " ", "../Elsewhere", "a/b", ".hidden", "..", "x:y", " Moments"]

        for value in unsafe {
            defaults.set(value, forKey: AppIdentityMigration.storeFolderKey)
            let name = AppIdentityMigration.storeFolderName(
                bundleIdentifier: releaseID, defaults: defaults, storeExists: none
            )
            XCTAssertEqual(name, "Moments", "recorded value \(value.debugDescription)")
        }
    }

    func testImportReadsARealLegacyDomain() throws {
        // A second suite stands in for the preview build's domain, read the
        // way the app reads it: through persistentDomain(forName:).
        let legacyName: String = "AppIdentityMigrationTests-legacy-\(UUID().uuidString)"
        let legacy: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: legacyName))
        defer { legacy.removePersistentDomain(forName: legacyName) }
        legacy.setPersistentDomain(["trip.cover": "photo-a"], forName: legacyName)
        let reader: (String) -> [String: Any]? = { (domain: String) -> [String: Any]? in
            domain == "org.example.Moments.peoplepreview" ? legacy.persistentDomain(forName: legacyName) : nil
        }

        let source = AppIdentityMigration.importLegacyPreferences(
            into: defaults, ownDomain: suiteName, readDomain: reader
        )

        XCTAssertEqual(source, "org.example.Moments.peoplepreview")
        XCTAssertEqual(defaults.string(forKey: "trip.cover"), "photo-a")
    }

    func testPreviewFolderWithoutAStoreIsNotAdopted() throws {
        let support = FileManager.default.temporaryDirectory
            .appending(path: "AppIdentityMigrationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: support) }
        let previewFolder = support.appending(path: "Moments People Preview", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: previewFolder, withIntermediateDirectories: true)

        let folder = MomentsPersistence.defaultStoreFolder(
            applicationSupportDirectory: support,
            bundleIdentifier: releaseID,
            defaults: defaults
        )

        XCTAssertEqual(folder.lastPathComponent, "Moments")
    }

    func testDefaultStoreFolderLooksForThePreviewStoreOnDisk() throws {
        let support = FileManager.default.temporaryDirectory
            .appending(path: "AppIdentityMigrationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: support) }
        let previewFolder = support.appending(path: "Moments People Preview", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: previewFolder, withIntermediateDirectories: true)
        try Data().write(to: previewFolder.appending(path: "Moments.store"))

        let folder = MomentsPersistence.defaultStoreFolder(
            applicationSupportDirectory: support,
            bundleIdentifier: releaseID,
            defaults: defaults
        )

        XCTAssertEqual(folder.lastPathComponent, "Moments People Preview")
    }
}

import SwiftData
import XCTest
@testable import Moments

/// Temp directories only: these tests never touch the user's store.
@MainActor
final class StoreRecoveryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "moments-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testUnreadableStoreIsBackedUpByteForByteAndAFreshStoreOpens() throws {
        let storeURL = folder.appending(path: "Moments.store")
        let garbage = Data("synthetic corrupt store bytes".utf8)
        let walBytes = Data("synthetic wal".utf8)
        try garbage.write(to: storeURL)
        try walBytes.write(to: folder.appending(path: "Moments.store-wal"))
        let support = folder.appending(path: ".Moments_SUPPORT/_EXTERNAL_DATA", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("synthetic blob".utf8).write(to: support.appending(path: "blob"))

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "moments-recovery-\(UUID().uuidString)"))
        XCTAssertTrue(MomentsPersistence.isProvablyCorrupt(storeURL))
        let opened = try MomentsPersistence.openWithRecovery(url: storeURL, now: Date(timeIntervalSince1970: 1_767_225_600), notices: defaults)
        let recovery = try XCTUnwrap(opened.recovery)
        XCTAssertEqual(defaults.string(forKey: StoreRecoveryNotice.defaultsKey), recovery.backupFolder.path)

        XCTAssertEqual(recovery.backupFolder.deletingLastPathComponent().lastPathComponent, "Backups")
        XCTAssertEqual(try Data(contentsOf: recovery.backupFolder.appending(path: "Moments.store")), garbage)
        XCTAssertEqual(try Data(contentsOf: recovery.backupFolder.appending(path: "Moments.store-wal")), walBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.backupFolder.appending(path: ".Moments_SUPPORT/_EXTERNAL_DATA/blob").path))

        // The fresh store at the normal path works.
        let context = opened.container.mainContext
        context.insert(MediaItem(id: "synthetic-after-recovery"))
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<MediaItem>()).map(\.id), ["synthetic-after-recovery"])

    }

    func testReadableLegacyStoreWithRealDataIsNeverMoved() throws {
        let storeURL = folder.appending(path: "Moments.store")
        do {
            let legacy = try MomentsPersistence.makeV1Container(url: storeURL)
            legacy.mainContext.insert(SchemaV1.MediaItem(id: "synthetic-legacy-real", source: .file))
            try legacy.mainContext.save()
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "moments-recovery-\(UUID().uuidString)"))
        XCTAssertFalse(MomentsPersistence.isProvablyCorrupt(storeURL))
        XCTAssertThrowsError(try MomentsPersistence.openWithRecovery(url: storeURL, notices: defaults)) { error in
            XCTAssertEqual(error as? MomentsStoreError, .protectedLegacyStore)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "Backups").path))
        XCTAssertNil(defaults.string(forKey: StoreRecoveryNotice.defaultsKey))
    }

    func testNoticeKeepsEveryPendingBackup() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "moments-recovery-\(UUID().uuidString)"))
        StoreRecoveryNotice.record(StoreRecovery(backupFolder: folder.appending(path: "Backups/one")), in: defaults)
        StoreRecoveryNotice.record(StoreRecovery(backupFolder: folder.appending(path: "Backups/two")), in: defaults)
        let paths = defaults.string(forKey: StoreRecoveryNotice.defaultsKey)?.split(separator: "\n").map(String.init) ?? []
        XCTAssertEqual(paths.map { URL(fileURLWithPath: $0).lastPathComponent }, ["one", "two"])
    }

    func testReadableStoreOpensWithoutBackup() throws {
        let storeURL = folder.appending(path: "Moments.store")
        _ = try MomentsPersistence.makeContainer(url: storeURL)
        let opened = try MomentsPersistence.openWithRecovery(url: storeURL)
        XCTAssertNil(opened.recovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "Backups").path))
    }

    func testFailedBackupLeavesTheStoreInPlaceAndRethrows() throws {
        let storeURL = folder.appending(path: "Moments.store")
        let garbage = Data("synthetic corrupt store bytes".utf8)
        try garbage.write(to: storeURL)
        // A file named "Backups" makes the backup folder impossible to create.
        try Data().write(to: folder.appending(path: "Backups"))

        XCTAssertThrowsError(try MomentsPersistence.openWithRecovery(url: storeURL))
        XCTAssertEqual(try Data(contentsOf: storeURL), garbage)
    }
}

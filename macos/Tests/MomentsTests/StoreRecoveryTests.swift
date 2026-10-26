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

        let opened = try MomentsPersistence.openWithRecovery(url: storeURL, now: Date(timeIntervalSince1970: 1_767_225_600))
        let recovery = try XCTUnwrap(opened.recovery)

        XCTAssertEqual(recovery.backupFolder.deletingLastPathComponent().lastPathComponent, "Backups")
        XCTAssertEqual(try Data(contentsOf: recovery.backupFolder.appending(path: "Moments.store")), garbage)
        XCTAssertEqual(try Data(contentsOf: recovery.backupFolder.appending(path: "Moments.store-wal")), walBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.backupFolder.appending(path: ".Moments_SUPPORT/_EXTERNAL_DATA/blob").path))

        // The fresh store at the normal path works.
        let context = opened.container.mainContext
        context.insert(MediaItem(id: "synthetic-after-recovery"))
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<MediaItem>()).map(\.id), ["synthetic-after-recovery"])

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "moments-recovery-\(UUID().uuidString)"))
        StoreRecoveryNotice.record(recovery, in: defaults)
        XCTAssertEqual(defaults.string(forKey: StoreRecoveryNotice.defaultsKey), recovery.backupFolder.path)
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

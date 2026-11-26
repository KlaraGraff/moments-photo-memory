import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// Backups and restores on temporary folders with synthetic data only: these
/// tests never touch the user's store, defaults or Application Support.
@MainActor
final class LibraryBackupTests: XCTestCase {
    private var folder: URL!
    private var location: LibraryLocation!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let origin = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "moments-backup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        location = LibraryLocation(storeURL: folder.appending(path: "Moments.store"), correctionLogURL: folder.appending(path: "trip-corrections.jsonl"))
        suiteName = "moments-backup-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Writes synthetic photos and memories into the on-disk test store and
    /// closes it again.
    private func addItems(_ ids: [String], memory: String? = nil) throws {
        let container: ModelContainer = try MomentsPersistence.makeContainer(url: location.storeURL)
        let context = container.mainContext
        for id in ids {
            let item = MediaItem(id: id)
            context.insert(item)
            if let memory {
                context.insert(Memory(text: memory, mediaItem: item))
            }
        }
        try context.save()
    }

    private func storedIDs(at url: URL) throws -> [String] {
        let container: ModelContainer = try MomentsPersistence.makeContainer(url: url)
        let items: [MediaItem] = try container.mainContext.fetch(FetchDescriptor<MediaItem>())
        return items.map(\.id).sorted()
    }

    func testBackupIsACompleteOpenableCopyWithCounts() throws {
        try addItems(["synthetic-a", "synthetic-b"], memory: "synthetic memory")
        try Data("{\"synthetic\":1}\n".utf8).write(to: location.correctionLogURL)
        defaults.set(["synthetic-a"], forKey: TripAssignmentLocks.defaultsKey)

        let backup = try LibraryBackup.makeBackup(.daily, location: location, defaults: defaults, now: origin)

        let manifest = try XCTUnwrap(LibraryBackup.readManifest(in: backup))
        XCTAssertEqual(manifest.kind, .daily)
        XCTAssertEqual(manifest.schemaVersion, LibraryBackup.currentSchemaVersion)
        XCTAssertEqual(manifest.photoCount, 2)
        XCTAssertEqual(manifest.memoryCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appending(path: "trip-corrections.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appending(path: "Moments.store-wal").path), "a backup is one self-contained file")
        XCTAssertEqual(try storedIDs(at: backup.appending(path: "Moments.store")), ["synthetic-a", "synthetic-b"])
        XCTAssertEqual(LibraryBackup.list(location: location).map(\.folderName), [backup.lastPathComponent])
    }

    func testBackupWhileTheStoreIsOpenSeesSavedChanges() throws {
        let container: ModelContainer = try MomentsPersistence.makeContainer(url: location.storeURL)
        container.mainContext.insert(MediaItem(id: "synthetic-open"))
        try container.mainContext.save()

        let backup = try LibraryBackup.makeBackup(.daily, location: location, defaults: defaults, now: origin)
        XCTAssertEqual(LibraryBackup.readManifest(in: backup)?.photoCount, 1)
        // The live store keeps working after the copy.
        container.mainContext.insert(MediaItem(id: "synthetic-after"))
        XCTAssertNoThrow(try container.mainContext.save())
    }

    func testDailyBackupRunsOncePerDayAndOnlyWhenChanged() throws {
        try addItems(["synthetic-a"])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // The store files were last written just before the first backup.
        try setStoreModified(origin.addingTimeInterval(-60))

        let first = try LibraryBackup.backUpDailyIfDue(location: location, defaults: defaults, now: origin, calendar: calendar)
        XCTAssertNotNil(first)
        let sameDay = try LibraryBackup.backUpDailyIfDue(location: location, defaults: defaults, now: origin.addingTimeInterval(600), calendar: calendar)
        XCTAssertNil(sameDay)
        let nextDay = origin.addingTimeInterval(86_400 * 2)
        // Opening the store for the copy may touch its log; the times say
        // what the library's own writes would.
        try setStoreModified(origin.addingTimeInterval(-60.4))
        let unchanged = try LibraryBackup.backUpDailyIfDue(location: location, defaults: defaults, now: nextDay, calendar: calendar)
        XCTAssertNil(unchanged, "an unchanged library is not copied again")
        try setStoreModified(nextDay.addingTimeInterval(-5))
        let changed = try LibraryBackup.backUpDailyIfDue(location: location, defaults: defaults, now: nextDay, calendar: calendar)
        XCTAssertNotNil(changed)
        XCTAssertEqual(LibraryBackup.list(location: location).count, 2)
    }

    private func setStoreModified(_ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: location.storeURL.path)
        let walPath = location.storeURL.path + "-wal"
        if FileManager.default.fileExists(atPath: walPath) {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: walPath)
        }
    }

    func testOldDailyBackupsArePrunedButOthersStay() throws {
        try addItems(["synthetic-a"])
        try LibraryBackup.makeBackup(.beforeRestore, location: location, defaults: defaults, now: origin)
        for day in 0..<(BackupPolicy.dailyKeep + 2) {
            let date: Date = origin.addingTimeInterval(Double(day + 1) * 86_400)
            try LibraryBackup.makeBackup(.daily, location: location, defaults: defaults, now: date)
        }
        let entries: [BackupEntry] = LibraryBackup.list(location: location)
        XCTAssertEqual(entries.filter { $0.manifest.kind == .daily }.count, BackupPolicy.dailyKeep)
        XCTAssertEqual(entries.filter { $0.manifest.kind == .beforeRestore }.count, 1)
        let oldestDaily: Date? = entries.filter { $0.manifest.kind == .daily }.map(\.manifest.createdAt).min()
        XCTAssertEqual(oldestDaily, origin.addingTimeInterval(3 * 86_400))
    }

    /// Restoring the oldest of the kept "before restore" copies: saving the
    /// current library first must not prune the very backup being restored.
    func testRestoringTheOldestBeforeRestoreCopyKeepsIt() throws {
        try addItems(["synthetic-a"])
        let oldest = try LibraryBackup.makeBackup(.beforeRestore, location: location, defaults: defaults, now: origin)
        try addItems(["synthetic-b"])
        for index in 1..<BackupPolicy.beforeRestoreKeep {
            let date: Date = origin.addingTimeInterval(Double(index) * 86_400)
            try LibraryBackup.makeBackup(.beforeRestore, location: location, defaults: defaults, now: date)
        }
        try LibraryBackup.scheduleRestore(from: oldest, location: location)
        let later: Date = origin.addingTimeInterval(30 * 86_400)
        let notice = try XCTUnwrap(LibraryBackup.performPendingRestore(location: location, defaults: defaults, now: later))
        XCTAssertNil(notice.failure)
        XCTAssertEqual(try storedIDs(at: location.storeURL), ["synthetic-a"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldest.path), "the restored backup is still there")
    }

    /// External-storage blobs (face crops) travel with the backup and come
    /// back with a restore.
    func testExternalStorageIsBackedUpAndRestored() throws {
        let crop = Data((0..<400_000).map { (index: Int) -> UInt8 in UInt8(index % 251) })
        do {
            let container: ModelContainer = try MomentsPersistence.makeContainer(url: location.storeURL)
            let face = FaceObservation(id: "synthetic-face", mediaID: "synthetic-a", rect: (x: 0.1, y: 0.1, w: 0.2, h: 0.2), embedding: Data(repeating: 7, count: 300_000), cropData: crop, quality: 0.9)
            container.mainContext.insert(MediaItem(id: "synthetic-a"))
            container.mainContext.insert(face)
            try container.mainContext.save()
        }
        let backup = try LibraryBackup.makeBackup(.daily, location: location, defaults: defaults, now: origin)
        // The live library loses its faces; the restore brings them back.
        do {
            let container: ModelContainer = try MomentsPersistence.makeContainer(url: location.storeURL)
            for face in try container.mainContext.fetch(FetchDescriptor<FaceObservation>()) { container.mainContext.delete(face) }
            try container.mainContext.save()
        }
        try LibraryBackup.scheduleRestore(from: backup, location: location)
        XCTAssertNil(LibraryBackup.performPendingRestore(location: location, defaults: defaults)?.failure)
        let container: ModelContainer = try MomentsPersistence.makeContainer(url: location.storeURL)
        let faces: [FaceObservation] = try container.mainContext.fetch(FetchDescriptor<FaceObservation>())
        XCTAssertEqual(faces.map(\.id), ["synthetic-face"])
        XCTAssertEqual(faces.first?.cropData, crop)
    }

    func testAnUnreadableRestoreRequestIsReported() throws {
        try Data("not json".utf8).write(to: location.pendingRestoreURL)
        let notice = try XCTUnwrap(LibraryBackup.performPendingRestore(location: location, defaults: defaults))
        XCTAssertNotNil(notice.failure)
        XCTAssertFalse(LibraryBackup.hasPendingRestore(location: location))
    }

    /// A crash in the middle of a restore: the store was moved aside but the
    /// backup's copy never arrived. The next launch moves the store back.
    func testAnInterruptedRestoreGetsTheLibraryBack() throws {
        try addItems(["synthetic-a"])
        let aside = folder.appending(path: ".restore-old-synthetic", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasPrefix("Moments.store") {
            try FileManager.default.moveItem(at: folder.appending(path: name), to: aside.appending(path: name))
        }
        // The backup's blob folder had already arrived when the crash came.
        let partial = folder.appending(path: ".Moments_SUPPORT/_EXTERNAL_DATA", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("synthetic backup blob".utf8).write(to: partial.appending(path: "from-backup"))
        let asideSupport = aside.appending(path: ".Moments_SUPPORT/_EXTERNAL_DATA", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: asideSupport, withIntermediateDirectories: true)
        try Data("synthetic old blob".utf8).write(to: asideSupport.appending(path: "old"))
        let incoming = location.backupsFolder.appending(path: ".incoming-synthetic", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)

        LibraryBackup.cleanUpLeftovers(location: location)
        XCTAssertEqual(try storedIDs(at: location.storeURL), ["synthetic-a"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
        let blobs = folder.appending(path: ".Moments_SUPPORT/_EXTERNAL_DATA", directoryHint: .isDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobs.appending(path: "old").path), "the old library's blobs came back with it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobs.appending(path: "from-backup").path))
    }

    func testTheScheduleNeverStartsWithoutALibrary() {
        let controller = BackupController()
        controller.configure(location: nil)
        controller.startSchedule()
        XCTAssertFalse(controller.isScheduled)
        XCTAssertTrue(controller.entries.isEmpty)
    }

    func testRecoveryCopiesWithoutManifestAreNeverListedOrPruned() throws {
        let recovery = location.backupsFolder.appending(path: "2026-01-01T00-00-00Z", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: recovery.appending(path: "Moments.store"))
        LibraryBackup.prune(location: location)
        XCTAssertTrue(LibraryBackup.list(location: location).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
    }

    func testRestoreBringsBackTheLibraryAndItsChoicesAndKeepsTheCurrentOne() throws {
        try addItems(["synthetic-a"])
        defaults.set(["synthetic-a"], forKey: TripAssignmentLocks.defaultsKey)
        // Labelled V8: before V9 these choices lived in user defaults, and a
        // restore puts the backup's copy of them back there.
        let backup = try LibraryBackup.makeBackup(.daily, location: location, defaults: defaults, now: origin, schemaVersion: "8.0.0")

        // Later work that the restore undoes.
        try addItems(["synthetic-b"])
        defaults.set(["synthetic-a", "synthetic-b"], forKey: TripAssignmentLocks.defaultsKey)
        defaults.set(["pair-x"], forKey: PeopleStoreActions.declinedPairsKey)

        try LibraryBackup.scheduleRestore(from: backup, location: location)
        XCTAssertTrue(LibraryBackup.hasPendingRestore(location: location))
        let notice = try XCTUnwrap(LibraryBackup.performPendingRestore(location: location, defaults: defaults, now: origin.addingTimeInterval(3_600)))

        XCTAssertNil(notice.failure)
        XCTAssertEqual(notice.restoredBackupDate, origin)
        XCTAssertFalse(LibraryBackup.hasPendingRestore(location: location))
        XCTAssertEqual(try storedIDs(at: location.storeURL), ["synthetic-a"])
        XCTAssertEqual(defaults.stringArray(forKey: TripAssignmentLocks.defaultsKey), ["synthetic-a"])
        XCTAssertNil(defaults.object(forKey: PeopleStoreActions.declinedPairsKey), "answers made after the backup go too")
        XCTAssertEqual(BackupRestoreNotice.read(defaults), notice)

        let before = try XCTUnwrap(LibraryBackup.list(location: location).first { $0.manifest.kind == .beforeRestore })
        let beforeStore = location.backupsFolder.appending(path: before.folderName).appending(path: "Moments.store")
        XCTAssertEqual(try storedIDs(at: beforeStore), ["synthetic-a", "synthetic-b"], "the library from before the restore can be restored again")
        let leftovers: [String] = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".restore-") }
        XCTAssertEqual(leftovers, [])
    }

    /// Sharing's sync state belongs to the library being replaced: a restore
    /// drops it (so the next sync fetches again instead of deleting records
    /// made after the backup) and a backup never carries it.
    func testRestoreDropsTheSyncStateAndBackupsLeaveItOut() throws {
        try addItems(["synthetic-a"])
        let sync = location.syncStateFolder
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        try Data("synthetic sync state".utf8).write(to: sync.appending(path: "state.json"))
        let previews = folder.appending(path: "SharedPreviews", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: previews.appending(path: "synthetic.jpg"))

        let backup = try LibraryBackup.makeBackup(.daily, location: location, defaults: defaults, now: origin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appending(path: "Sync").path))

        try LibraryBackup.scheduleRestore(from: backup, location: location)
        XCTAssertNil(LibraryBackup.performPendingRestore(location: location, defaults: defaults, now: origin.addingTimeInterval(3_600))?.failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sync.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: previews.appending(path: "synthetic.jpg").path), "shared previews stay")
        XCTAssertEqual(try storedIDs(at: location.storeURL), ["synthetic-a"])
    }

    func testRestoreOntoANewMacWithoutALibrary() throws {
        try addItems(["synthetic-a"])
        try Data("{\"synthetic\":1}\n".utf8).write(to: location.correctionLogURL)
        let backup = try LibraryBackup.makeBackup(.daily, location: location, defaults: defaults, now: origin)

        // A second Mac: an empty folder of its own, the backup copied over.
        let otherFolder = folder.appending(path: "other-mac", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let copied = otherFolder.appending(path: "copied-backup", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: backup, to: copied)
        let newMac = LibraryLocation(storeURL: otherFolder.appending(path: "Library/Moments.store"), correctionLogURL: otherFolder.appending(path: "Library/trip-corrections.jsonl"))

        try LibraryBackup.scheduleRestore(from: copied, location: newMac)
        let notice = LibraryBackup.performPendingRestore(location: newMac, defaults: defaults)
        XCTAssertNil(notice?.failure)
        XCTAssertEqual(try storedIDs(at: newMac.storeURL), ["synthetic-a"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: newMac.correctionLogURL.path))
    }

    func testABackupFromANewerSchemaIsRefused() throws {
        try addItems(["synthetic-a"])
        let backup = try LibraryBackup.makeBackup(.daily, location: location, defaults: defaults, now: origin, schemaVersion: "99.0.0")
        XCTAssertThrowsError(try LibraryBackup.scheduleRestore(from: backup, location: location)) { error in
            XCTAssertEqual(error as? LibraryBackupError, .tooNew)
        }
        XCTAssertFalse(LibraryBackup.hasPendingRestore(location: location))
    }

    func testAFolderThatIsNotABackupIsRefused() throws {
        let stray = folder.appending(path: "stray", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        XCTAssertThrowsError(try LibraryBackup.validate(stray)) { error in
            XCTAssertEqual(error as? LibraryBackupError, .notABackup)
        }
    }

    func testAFailedRestoreLeavesTheLibraryAsItWas() throws {
        try addItems(["synthetic-a"])
        let backup = try LibraryBackup.makeBackup(.daily, location: location, defaults: defaults, now: origin)
        try LibraryBackup.scheduleRestore(from: backup, location: location)
        // The backup disappears before the next launch (a drive unplugged).
        try FileManager.default.removeItem(at: backup)

        let notice = try XCTUnwrap(LibraryBackup.performPendingRestore(location: location, defaults: defaults))
        XCTAssertNotNil(notice.failure)
        XCTAssertEqual(try storedIDs(at: location.storeURL), ["synthetic-a"])
        XCTAssertFalse(LibraryBackup.hasPendingRestore(location: location), "a failed restore is not retried at every launch")
    }

    func testUpgradeBackupHappensOncePerSchema() throws {
        XCTAssertNil(LibraryBackup.backUpBeforeUpgradeIfNeeded(location: location, defaults: defaults, now: origin), "nothing to save before the first launch")
        try addItems(["synthetic-a"])
        let first = LibraryBackup.backUpBeforeUpgradeIfNeeded(location: location, defaults: defaults, now: origin)
        XCTAssertNotNil(first)
        XCTAssertEqual(first.flatMap { LibraryBackup.readManifest(in: $0) }?.kind, .beforeUpgrade)
        LibraryBackup.recordOpened(location: location)
        XCTAssertNil(LibraryBackup.backUpBeforeUpgradeIfNeeded(location: location, defaults: defaults, now: origin))
        // A newer build with another schema backs up again.
        let next = LibraryBackup.backUpBeforeUpgradeIfNeeded(location: location, defaults: defaults, now: origin.addingTimeInterval(60), schemaVersion: "99.0.0")
        XCTAssertEqual(next.flatMap { LibraryBackup.readManifest(in: $0) }?.schemaVersion, LibraryBackup.currentSchemaVersion, "the copy is labelled with the schema it really has")
    }

    func testNoStoreMeansNoBackup() {
        XCTAssertThrowsError(try LibraryBackup.makeBackup(.daily, location: location, defaults: defaults, now: origin)) { error in
            XCTAssertEqual(error as? LibraryBackupError, .noStore)
        }
        XCTAssertTrue(LibraryBackup.list(location: location).isEmpty)
    }
}

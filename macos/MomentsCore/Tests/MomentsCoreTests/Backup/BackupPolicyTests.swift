import Foundation
import XCTest
@testable import MomentsCore

/// The rules behind automatic backups: when one is due, which are kept, and
/// which backups this app may restore.
final class BackupPolicyTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let origin = Date(timeIntervalSince1970: 1_790_000_000)

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    private func manifest(_ kind: BackupKind, at date: Date, modified: Date? = nil, schema: String = "8.0.0") -> BackupManifest {
        BackupManifest(kind: kind, createdAt: date, appVersion: "1.0", schemaVersion: schema, sourceModifiedAt: modified)
    }

    private func entry(_ name: String, _ kind: BackupKind, at date: Date) -> BackupEntry {
        BackupEntry(folderName: name, manifest: manifest(kind, at: date))
    }

    func testALibraryWithoutBackupsIsDue() {
        XCTAssertTrue(BackupPolicy.isDailyDue(newest: nil, currentSourceModifiedAt: origin, now: origin, calendar: utc))
    }

    func testNotDueTwiceOnTheSameDay() {
        let morning = utc.startOfDay(for: origin).addingTimeInterval(3_600)
        let evening = morning.addingTimeInterval(12 * 3_600)
        let newest = manifest(.daily, at: morning, modified: morning)
        XCTAssertFalse(BackupPolicy.isDailyDue(newest: newest, currentSourceModifiedAt: evening, now: evening, calendar: utc))
    }

    func testDueTheNextDayOnlyWhenTheLibraryChanged() {
        let backedUp = origin
        let newest = manifest(.daily, at: backedUp, modified: backedUp.addingTimeInterval(-60))
        let tomorrow = backedUp.addingTimeInterval(day)
        let unchanged = BackupPolicy.isDailyDue(newest: newest, currentSourceModifiedAt: backedUp.addingTimeInterval(-60), now: tomorrow, calendar: utc)
        let changed = BackupPolicy.isDailyDue(newest: newest, currentSourceModifiedAt: tomorrow.addingTimeInterval(-10), now: tomorrow, calendar: utc)
        XCTAssertFalse(unchanged, "an unchanged library is not copied again")
        XCTAssertTrue(changed)
    }

    /// backup.json keeps whole seconds; an unchanged store with a fractional
    /// file time must not look newer than its copy.
    func testFractionalFileTimesDoNotLookChanged() throws {
        let fileTime = Date(timeIntervalSince1970: 1_790_000_000.73)
        let roundTripped = try BackupManifest.decode(manifest(.daily, at: origin, modified: fileTime).encoded())
        let tomorrow = origin.addingTimeInterval(day)
        XCTAssertFalse(BackupPolicy.isDailyDue(newest: roundTripped, currentSourceModifiedAt: fileTime, now: tomorrow, calendar: utc))
        XCTAssertTrue(BackupPolicy.isDailyDue(newest: roundTripped, currentSourceModifiedAt: fileTime.addingTimeInterval(5), now: tomorrow, calendar: utc))
    }

    func testAProtectedBackupIsNeverPrunedNorCounted() {
        var entries: [BackupEntry] = []
        for index in 0..<6 {
            entries.append(entry("restore-\(index)", .beforeRestore, at: origin.addingTimeInterval(Double(index) * day)))
        }
        let doomed = BackupPolicy.foldersToPrune(entries, protected: ["restore-0"])
        XCTAssertEqual(doomed, [], "the oldest is protected, and the other five fit")
        XCTAssertEqual(BackupPolicy.foldersToPrune(entries), ["restore-0"])
    }

    func testAnyKindCountsAsTodaysBackup() {
        let newest = manifest(.beforeUpgrade, at: origin, modified: origin)
        XCTAssertFalse(BackupPolicy.isDailyDue(newest: newest, currentSourceModifiedAt: origin.addingTimeInterval(30), now: origin.addingTimeInterval(60), calendar: utc))
    }

    func testPruningKeepsTheNewestOfEachAutomaticKind() {
        var entries: [BackupEntry] = []
        for index in 0..<20 {
            entries.append(entry(String(format: "daily-%02d", index), .daily, at: origin.addingTimeInterval(Double(index) * day)))
        }
        for index in 0..<5 {
            entries.append(entry("upgrade-\(index)", .beforeUpgrade, at: origin.addingTimeInterval(Double(index) * day)))
        }
        for index in 0..<2 {
            entries.append(entry("restore-\(index)", .beforeRestore, at: origin.addingTimeInterval(Double(index) * day)))
        }
        let doomed = BackupPolicy.foldersToPrune(entries)
        let expectedDaily: [String] = (0..<6).map { String(format: "daily-%02d", $0) }
        XCTAssertEqual(doomed, (expectedDaily + ["upgrade-0", "upgrade-1"]).sorted())
        let kept: [BackupEntry] = entries.filter { !doomed.contains($0.folderName) }
        XCTAssertEqual(kept.filter { $0.manifest.kind == .daily }.count, BackupPolicy.dailyKeep)
        XCTAssertEqual(kept.filter { $0.manifest.kind == .beforeUpgrade }.count, BackupPolicy.beforeUpgradeKeep)
        XCTAssertEqual(kept.filter { $0.manifest.kind == .beforeRestore }.count, 2)
    }

    func testUpgradeBackupWhenTheSchemaChangedOrWasNeverRecorded() {
        XCTAssertTrue(BackupPolicy.needsUpgradeBackup(lastOpenedSchema: nil, currentSchema: "9.0.0", storeExists: true))
        XCTAssertTrue(BackupPolicy.needsUpgradeBackup(lastOpenedSchema: "8.0.0", currentSchema: "9.0.0", storeExists: true))
        XCTAssertFalse(BackupPolicy.needsUpgradeBackup(lastOpenedSchema: "9.0.0", currentSchema: "9.0.0", storeExists: true))
        XCTAssertFalse(BackupPolicy.needsUpgradeBackup(lastOpenedSchema: nil, currentSchema: "9.0.0", storeExists: false), "a first launch has nothing to save")
    }

    func testOnlyBackupsFromThisSchemaOrOlderAreRestored() {
        XCTAssertEqual(BackupPolicy.restoreCheck(manifest(.daily, at: origin, schema: "8.0.0"), currentSchema: "8.0.0"), .ok)
        XCTAssertEqual(BackupPolicy.restoreCheck(manifest(.daily, at: origin, schema: "7.0.0"), currentSchema: "8.0.0"), .ok)
        XCTAssertEqual(BackupPolicy.restoreCheck(manifest(.daily, at: origin, schema: "10.0.0"), currentSchema: "9.0.0"), .tooNew, "compared as numbers, not text")
        XCTAssertEqual(BackupPolicy.restoreCheck(manifest(.daily, at: origin, schema: "eight"), currentSchema: "8.0.0"), .unreadable)
        var future = manifest(.daily, at: origin)
        future.format = BackupManifest.currentFormat + 1
        XCTAssertEqual(BackupPolicy.restoreCheck(future, currentSchema: "8.0.0"), .unreadable)
    }

    func testManifestRoundTrips() throws {
        let original = BackupManifest(kind: .beforeRestore, createdAt: Date(timeIntervalSince1970: 1_790_000_000), appVersion: "1.2", schemaVersion: "8.0.0", photoCount: 1_240, memoryCount: 86, sourceModifiedAt: Date(timeIntervalSince1970: 1_789_999_000))
        let decoded = try BackupManifest.decode(original.encoded())
        XCTAssertEqual(decoded, original)
    }

    func testNewestFirstOrder() {
        let entries = [entry("b", .daily, at: origin), entry("c", .daily, at: origin.addingTimeInterval(day)), entry("a", .beforeUpgrade, at: origin.addingTimeInterval(-day))]
        XCTAssertEqual(BackupPolicy.sortedNewestFirst(entries).map(\.folderName), ["c", "b", "a"])
        XCTAssertEqual(BackupPolicy.newest(entries)?.folderName, "c")
    }

    func testFolderNameSortsByTimeAndNamesTheKind() throws {
        let utcZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let first = BackupPolicy.folderName(for: .daily, at: origin, timeZone: utcZone)
        let second = BackupPolicy.folderName(for: .daily, at: origin.addingTimeInterval(3_600), timeZone: utcZone)
        XCTAssertTrue(first.hasSuffix(" daily"))
        XCTAssertFalse(first.contains(":"), "Finder shows colons as slashes")
        XCTAssertLessThan(first, second)
    }
}

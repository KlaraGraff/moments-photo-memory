import Foundation
import MomentsCore
import os
import SQLite3

/// Where one library lives on disk and the files that travel with it.
///
/// A backup is a folder in `Backups/` next to the store:
///
///     Moments.store          a self-contained SQLite copy (no -wal/-shm)
///     .Moments_SUPPORT/      SwiftData's external storage, when there is one
///     trip-corrections.jsonl the hand-correction log, when there is one
///     decisions.plist        choices still kept in user defaults
///     backup.json            written last: what kind, when, which schema
///
/// Original photos are never copied: they stay in their folders or in Photos.
struct LibraryLocation: Sendable {
    var storeURL: URL
    var correctionLogURL: URL

    var folder: URL { storeURL.deletingLastPathComponent() }
    var backupsFolder: URL { folder.appending(path: "Backups", directoryHint: .isDirectory) }
    /// Which schema last opened this library, so an upgrade is backed up first.
    var stateURL: URL { folder.appending(path: "library-state.json") }
    /// A restore asked for in Settings, carried out at the next launch before
    /// the store opens.
    var pendingRestoreURL: URL { folder.appending(path: "restore-pending.json") }
    /// Sharing's sync state (the server's version of each record). Never
    /// backed up, and dropped when a backup is restored.
    var syncStateFolder: URL { folder.appending(path: "Sync", directoryHint: .isDirectory) }
    var storeName: String { storeURL.lastPathComponent }
    var supportName: String { "." + storeURL.deletingPathExtension().lastPathComponent + "_SUPPORT" }

    static func live() throws -> LibraryLocation {
        LibraryLocation(storeURL: try MomentsPersistence.defaultStoreURL(), correctionLogURL: TripCorrectionLog.defaultFileURL())
    }
}

/// Library choices that lived in user defaults before schema V9. A backup
/// carries a copy of them. Restoring a backup from before V9 puts the copy
/// back, so the restored store copies its covers, hand-placed photos and
/// People answers in when it opens; from V9 on these are in the store, and
/// only the keys still in user defaults (the editor name) come back.
enum LibraryDecisionKeys {
    static var all: [String] {
        [
            TripAssignmentLocks.defaultsKey,
            TripCoverChoice.defaultsKey,
            EventSuggestions.suggestedDaysKey,
            TripRegrouping.versionKey,
            PeopleGroupStore.groupsKey,
            PeopleGroupStore.membersKey,
            PeopleGroupStore.seededKey,
            PeopleStoreActions.keepSeparateKey,
            PeopleStoreActions.keyFacesKey,
            PeopleStoreActions.questionsKey,
            PeopleStoreActions.declinedPairsKey,
            PeopleScanStore.groupingVersionKey,
            TripCorrectionLog.editorKey
        ]
    }

    static func snapshot(_ defaults: UserDefaults) -> [String: Any] {
        var values: [String: Any] = [:]
        for key in all {
            if let value = defaults.object(forKey: key) { values[key] = value }
        }
        return values
    }

    /// Makes `defaults` hold exactly the snapshot: keys missing from it are
    /// removed, so the restored library doesn't keep answers made after it.
    static func apply(_ values: [String: Any], to defaults: UserDefaults, keys: [String] = LibraryDecisionKeys.all) {
        for key in keys {
            if let value = values[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

enum LibraryBackupError: LocalizedError, Equatable {
    case noStore
    case copyFailed(String)
    case notABackup
    case tooNew
    case diskFull

    var errorDescription: String? {
        switch self {
        case .noStore: return String(localized: "There is no library to back up yet.")
        case .copyFailed: return String(localized: "The library couldn't be copied.")
        case .notABackup: return String(localized: "This folder isn't a Moments backup.")
        case .tooNew: return String(localized: "This backup comes from a newer version of Moments. Update Moments first.")
        case .diskFull: return String(localized: "There isn't enough disk space.")
        }
    }
}

/// What the first launch after a restore tells the person.
struct BackupRestoreNotice: Codable, Equatable {
    static let defaultsKey = "moments.backup.restoreNotice"

    var restoredBackupDate: Date?
    var failure: String?

    static func record(_ notice: BackupRestoreNotice, in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(notice) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func read(_ defaults: UserDefaults) -> BackupRestoreNotice? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(BackupRestoreNotice.self, from: data)
    }
}

/// Makes, lists, prunes and restores library backups. Every function takes
/// its location, defaults and clock, so tests run on temporary folders only.
enum LibraryBackup {
    static let logger = Logger(subsystem: "org.example.Moments", category: "Backup")
    static let decisionsFileName = "decisions.plist"
    static let correctionLogFileName = "trip-corrections.jsonl"
    /// The schema from which covers, hand-placed photos and People answers
    /// are kept in the store rather than in user defaults.
    static let decisionsInStoreSchema = "9.0.0"

    /// The schema the running app opens stores with, "9.0.0".
    static var currentSchemaVersion: String {
        let version = MomentsMigrationPlan.schemas.last?.versionIdentifier ?? SchemaV8.versionIdentifier
        return "\(version.major).\(version.minor).\(version.patch)"
    }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    // MARK: Making a backup

    /// Copies the library into a new folder in `Backups/` and prunes old
    /// automatic backups. The copy is made in a hidden folder and renamed
    /// only when it is complete, so a half-made backup is never listed.
    /// Safe while the app has the store open: SQLite's backup API reads one
    /// consistent snapshot, the write-ahead log included.
    @discardableResult
    static func makeBackup(
        _ kind: BackupKind,
        location: LibraryLocation,
        defaults: UserDefaults,
        now: Date = .now,
        schemaVersion: String = LibraryBackup.currentSchemaVersion,
        protecting protected: Set<String> = []
    ) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: location.storeURL.path) else { throw LibraryBackupError.noStore }
        try fileManager.createDirectory(at: location.backupsFolder, withIntermediateDirectories: true)
        // Never fill the disk the live store writes to: a copy needs room
        // for itself and a margin left over.
        if let free = freeSpace(at: location.backupsFolder), free < librarySize(location) + spaceMargin {
            throw LibraryBackupError.diskFull
        }
        let incoming = location.backupsFolder.appending(path: ".incoming-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)
        do {
            let modified = sourceModifiedAt(location)
            let support = location.folder.appending(path: location.supportName, directoryHint: .isDirectory)
            let copiedSupport = incoming.appending(path: location.supportName, directoryHint: .isDirectory)
            // External blobs are copied before and after the database: a blob
            // deleted while the snapshot is taken is in the first pass, one
            // added meanwhile in the second, so the snapshot finds its blobs
            // (short of one created and deleted again between the passes).
            if fileManager.fileExists(atPath: support.path) {
                try fileManager.copyItem(at: support, to: copiedSupport)
            }
            let copiedStore = incoming.appending(path: location.storeName)
            try copyDatabase(from: location.storeURL, to: copiedStore)
            if fileManager.fileExists(atPath: support.path) {
                try copyMissingItems(from: support, to: copiedSupport)
            }
            if fileManager.fileExists(atPath: location.correctionLogURL.path) {
                try fileManager.copyItem(at: location.correctionLogURL, to: incoming.appending(path: correctionLogFileName))
            }
            let decisions = try PropertyListSerialization.data(fromPropertyList: LibraryDecisionKeys.snapshot(defaults), format: .binary, options: 0)
            try decisions.write(to: incoming.appending(path: decisionsFileName), options: .atomic)
            let counts = countRows(in: copiedStore)
            let manifest = BackupManifest(
                kind: kind,
                createdAt: now,
                appVersion: appVersion,
                schemaVersion: schemaVersion,
                photoCount: counts.photos,
                memoryCount: counts.memories,
                sourceModifiedAt: modified
            )
            try manifest.encoded().write(to: incoming.appending(path: BackupManifest.fileName), options: .atomic)

            var destination = location.backupsFolder.appending(path: BackupPolicy.folderName(for: kind, at: now), directoryHint: .isDirectory)
            var suffix = 2
            while fileManager.fileExists(atPath: destination.path) {
                destination = location.backupsFolder.appending(path: BackupPolicy.folderName(for: kind, at: now) + " \(suffix)", directoryHint: .isDirectory)
                suffix += 1
            }
            try fileManager.moveItem(at: incoming, to: destination)
            prune(location: location, protecting: protected)
            return destination
        } catch {
            // Only our own unfinished copy is removed; nothing of the library.
            try? fileManager.removeItem(at: incoming)
            if isDiskFull(error) { throw LibraryBackupError.diskFull }
            throw error
        }
    }

    /// The daily backup, made only when none was made today and the library
    /// changed since the newest one. Returns the new folder, if any.
    @discardableResult
    static func backUpDailyIfDue(location: LibraryLocation, defaults: UserDefaults, now: Date = .now, calendar: Calendar = .current) throws -> URL? {
        guard FileManager.default.fileExists(atPath: location.storeURL.path) else { return nil }
        let newest = BackupPolicy.newest(list(location: location))?.manifest
        guard BackupPolicy.isDailyDue(newest: newest, currentSourceModifiedAt: sourceModifiedAt(location), now: now, calendar: calendar) else { return nil }
        return try makeBackup(.daily, location: location, defaults: defaults, now: now)
    }

    /// Before a build with a newer schema opens the library, keep a copy of
    /// it as it was. Also runs once on the first launch of a build that makes
    /// backups, so every library has one from the start. A failure is logged
    /// and the launch goes on: the store itself is never touched here.
    @discardableResult
    static func backUpBeforeUpgradeIfNeeded(location: LibraryLocation, defaults: UserDefaults, now: Date = .now, schemaVersion: String = LibraryBackup.currentSchemaVersion) -> URL? {
        let storeExists = FileManager.default.fileExists(atPath: location.storeURL.path)
        guard BackupPolicy.needsUpgradeBackup(lastOpenedSchema: lastOpenedSchema(location), currentSchema: schemaVersion, storeExists: storeExists) else { return nil }
        do {
            return try makeBackup(.beforeUpgrade, location: location, defaults: defaults, now: now, schemaVersion: lastOpenedSchema(location) ?? schemaVersion)
        } catch {
            logger.error("Backup before upgrade failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Library state

    private struct LibraryState: Codable {
        var lastOpenedSchema: String
    }

    static func lastOpenedSchema(_ location: LibraryLocation) -> String? {
        guard let data = try? Data(contentsOf: location.stateURL) else { return nil }
        return (try? JSONDecoder().decode(LibraryState.self, from: data))?.lastOpenedSchema
    }

    /// Called once the store opened with the current schema.
    static func recordOpened(location: LibraryLocation, schemaVersion: String = LibraryBackup.currentSchemaVersion) {
        guard lastOpenedSchema(location) != schemaVersion,
              let data = try? JSONEncoder().encode(LibraryState(lastOpenedSchema: schemaVersion)) else { return }
        try? data.write(to: location.stateURL, options: .atomic)
    }

    // MARK: Listing and pruning

    /// Every finished backup in `Backups/`. Folders without `backup.json`
    /// (unfinished copies, or the older "couldn't open" copies) are left out.
    static func list(location: LibraryLocation) -> [BackupEntry] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: location.backupsFolder.path) else { return [] }
        return names.compactMap { name -> BackupEntry? in
            guard !name.hasPrefix("."),
                  let manifest = readManifest(in: location.backupsFolder.appending(path: name, directoryHint: .isDirectory)) else { return nil }
            return BackupEntry(folderName: name, manifest: manifest)
        }
    }

    static func readManifest(in folder: URL) -> BackupManifest? {
        guard let data = try? Data(contentsOf: folder.appending(path: BackupManifest.fileName)) else { return nil }
        return try? BackupManifest.decode(data)
    }

    static func prune(location: LibraryLocation, protecting protected: Set<String> = []) {
        for name in BackupPolicy.foldersToPrune(list(location: location), protected: protected) {
            do {
                try FileManager.default.removeItem(at: location.backupsFolder.appending(path: name, directoryHint: .isDirectory))
            } catch {
                logger.error("Could not remove an old backup: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Restoring

    private struct PendingRestore: Codable {
        var backupPath: String
    }

    /// Checks a backup folder and remembers it, so the next launch restores
    /// it before the store opens. The running app's store is left alone.
    static func scheduleRestore(from backupFolder: URL, location: LibraryLocation, schemaVersion: String = LibraryBackup.currentSchemaVersion) throws {
        try validate(backupFolder, schemaVersion: schemaVersion)
        let data = try JSONEncoder().encode(PendingRestore(backupPath: backupFolder.path))
        try FileManager.default.createDirectory(at: location.folder, withIntermediateDirectories: true)
        try data.write(to: location.pendingRestoreURL, options: .atomic)
    }

    static func hasPendingRestore(location: LibraryLocation) -> Bool {
        FileManager.default.fileExists(atPath: location.pendingRestoreURL.path)
    }

    @discardableResult
    static func validate(_ backupFolder: URL, schemaVersion: String = LibraryBackup.currentSchemaVersion) throws -> BackupManifest {
        guard let manifest = readManifest(in: backupFolder),
              FileManager.default.fileExists(atPath: backupFolder.appending(path: "Moments.store").path) else {
            throw LibraryBackupError.notABackup
        }
        switch BackupPolicy.restoreCheck(manifest, currentSchema: schemaVersion) {
        case .ok: return manifest
        case .tooNew: throw LibraryBackupError.tooNew
        case .unreadable: throw LibraryBackupError.notABackup
        }
    }

    /// Runs at launch, before the store opens. Saves the current library as
    /// a "before restore" backup, then swaps the backup's files in. If any
    /// step fails the current library stays exactly as it was, and the next
    /// launch says why. Returns the notice it recorded.
    @discardableResult
    static func performPendingRestore(location: LibraryLocation, defaults: UserDefaults, now: Date = .now, schemaVersion: String = LibraryBackup.currentSchemaVersion) -> BackupRestoreNotice? {
        let fileManager = FileManager.default
        guard let data = try? Data(contentsOf: location.pendingRestoreURL) else { return nil }
        // Removed first, so a restore that crashes is not retried at every launch.
        try? fileManager.removeItem(at: location.pendingRestoreURL)
        guard let pending = try? JSONDecoder().decode(PendingRestore.self, from: data) else {
            let notice = BackupRestoreNotice(restoredBackupDate: nil, failure: LibraryBackupError.notABackup.localizedDescription)
            BackupRestoreNotice.record(notice, in: defaults)
            return notice
        }
        let backupFolder = URL(fileURLWithPath: pending.backupPath, isDirectory: true)
        // The backup being restored may be one of ours: it must survive the
        // pruning that saving the current library triggers.
        let ownFolder = backupFolder.standardizedFileURL.deletingLastPathComponent().path == location.backupsFolder.standardizedFileURL.path
        let protected: Set<String> = ownFolder ? [backupFolder.lastPathComponent] : []
        let notice: BackupRestoreNotice
        do {
            let manifest = try validate(backupFolder, schemaVersion: schemaVersion)
            if fileManager.fileExists(atPath: location.storeURL.path) {
                try makeBackup(.beforeRestore, location: location, defaults: defaults, now: now, schemaVersion: lastOpenedSchema(location) ?? schemaVersion, protecting: protected)
            }
            // Before V9 these choices lived only in user defaults, and a
            // restored V8 store copies them in when it opens; from V9 on they
            // are in the restored store, and only what is still in user
            // defaults comes back. Applied before the swap, so a crash in
            // between never leaves a restored older store to copy in today's
            // choices; a failed swap puts the previous values back.
            let keys: [String] = BackupPolicy.isSchema(manifest.schemaVersion, olderThan: LibraryBackup.decisionsInStoreSchema)
                ? LibraryDecisionKeys.all
                : LibraryDecisionKeys.all.filter { !LibraryDecisions.movedKeys.contains($0) }
            var previous: [String: Any]?
            if let decisions = try? Data(contentsOf: backupFolder.appending(path: decisionsFileName)),
               let values = try? PropertyListSerialization.propertyList(from: decisions, format: nil) as? [String: Any] {
                previous = LibraryDecisionKeys.snapshot(defaults)
                LibraryDecisionKeys.apply(values, to: defaults, keys: keys)
            }
            // The sync state describes the library being replaced. Kept with an
            // older store, the next sync would read records made after the
            // backup as deleted here and delete them for the other person
            // too. Without it, sharing fetches everything again and merges;
            // nothing is deleted. Dropped before the swap, so a crash in
            // between can't leave the old state next to the restored store.
            if fileManager.fileExists(atPath: location.syncStateFolder.path) {
                try fileManager.removeItem(at: location.syncStateFolder)
            }
            do {
                try swapIn(backupFolder: backupFolder, location: location)
            } catch {
                if let previous { LibraryDecisionKeys.apply(previous, to: defaults, keys: keys) }
                throw error
            }
            // A new Mac has no correction log yet; an existing one keeps its
            // newer entries.
            let backupLog = backupFolder.appending(path: correctionLogFileName)
            if !fileManager.fileExists(atPath: location.correctionLogURL.path), fileManager.fileExists(atPath: backupLog.path) {
                try? fileManager.createDirectory(at: location.correctionLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fileManager.copyItem(at: backupLog, to: location.correctionLogURL)
            }
            // The backup itself is the copy from before any migration, so the
            // restored store needs no extra "before update" backup.
            if let data = try? JSONEncoder().encode(LibraryState(lastOpenedSchema: schemaVersion)) {
                try? data.write(to: location.stateURL, options: .atomic)
            }
            notice = BackupRestoreNotice(restoredBackupDate: manifest.createdAt, failure: nil)
        } catch {
            logger.error("Restore failed: \(error.localizedDescription, privacy: .public)")
            notice = BackupRestoreNotice(restoredBackupDate: readManifest(in: backupFolder)?.createdAt, failure: error.localizedDescription)
        }
        BackupRestoreNotice.record(notice, in: defaults)
        return notice
    }

    /// Copies the backup's files next to the store first, then moves the
    /// current store set aside and the copies into place. If a move fails,
    /// everything moved so far goes back.
    private static func swapIn(backupFolder: URL, location: LibraryLocation) throws {
        let fileManager = FileManager.default
        let token = UUID().uuidString
        let staging = location.folder.appending(path: ".restore-staging-\(token)", directoryHint: .isDirectory)
        let aside = location.folder.appending(path: ".restore-old-\(token)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: backupFolder.appending(path: "Moments.store"), to: staging.appending(path: location.storeName))
        let backupSupport = backupFolder.appending(path: ".Moments_SUPPORT", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: backupSupport.path) {
            try fileManager.copyItem(at: backupSupport, to: staging.appending(path: location.supportName, directoryHint: .isDirectory))
        }

        try fileManager.createDirectory(at: aside, withIntermediateDirectories: true)
        let current = try fileManager.contentsOfDirectory(atPath: location.folder.path).filter { name in
            name == location.storeName || name.hasPrefix(location.storeName + "-") || name == location.supportName
        }
        var movedAside: [String] = []
        var movedIn: [String] = []
        do {
            for name in current {
                try fileManager.moveItem(at: location.folder.appending(path: name), to: aside.appending(path: name))
                movedAside.append(name)
            }
            // The store goes in last: once it is in place the swap is done,
            // which is what `cleanUpLeftovers` relies on after a crash.
            let staged = try fileManager.contentsOfDirectory(atPath: staging.path).sorted { lhs, rhs in
                (lhs == location.storeName ? 1 : 0, lhs) < (rhs == location.storeName ? 1 : 0, rhs)
            }
            for name in staged {
                try fileManager.moveItem(at: staging.appending(path: name), to: location.folder.appending(path: name))
                movedIn.append(name)
            }
        } catch {
            for name in movedIn.reversed() { try? fileManager.removeItem(at: location.folder.appending(path: name)) }
            for name in movedAside.reversed() { try? fileManager.moveItem(at: aside.appending(path: name), to: location.folder.appending(path: name)) }
            if (try? fileManager.contentsOfDirectory(atPath: aside.path))?.isEmpty == true { try? fileManager.removeItem(at: aside) }
            throw error
        }
        // The old library is already saved as the "before restore" backup.
        try? fileManager.removeItem(at: aside)
    }

    // MARK: Leftovers

    /// Runs at launch, before a restore and before the store opens. Removes
    /// unfinished copies a quit or crash left behind (`.incoming-*`,
    /// `.restore-staging-*`). If a crash came in the middle of a restore,
    /// after the current store was moved aside but before the backup was in
    /// place, the store set aside is moved back; otherwise it is removed, as
    /// its "before restore" backup was made first.
    static func cleanUpLeftovers(location: LibraryLocation) {
        let fileManager = FileManager.default
        if let names = try? fileManager.contentsOfDirectory(atPath: location.backupsFolder.path) {
            for name in names where name.hasPrefix(".incoming-") {
                try? fileManager.removeItem(at: location.backupsFolder.appending(path: name, directoryHint: .isDirectory))
            }
        }
        guard let names = try? fileManager.contentsOfDirectory(atPath: location.folder.path) else { return }
        for name in names where name.hasPrefix(".restore-staging-") {
            try? fileManager.removeItem(at: location.folder.appending(path: name, directoryHint: .isDirectory))
        }
        for name in names.sorted() where name.hasPrefix(".restore-old-") {
            let aside = location.folder.appending(path: name, directoryHint: .isDirectory)
            let asideStore = aside.appending(path: location.storeName)
            if !fileManager.fileExists(atPath: location.storeURL.path), fileManager.fileExists(atPath: asideStore.path) {
                for item in (try? fileManager.contentsOfDirectory(atPath: aside.path)) ?? [] {
                    // Anything already in its place came from the backup (the
                    // store goes in last), and the backup still has it.
                    let target = location.folder.appending(path: item)
                    if fileManager.fileExists(atPath: target.path) { try? fileManager.removeItem(at: target) }
                    try? fileManager.moveItem(at: aside.appending(path: item), to: target)
                }
                logger.error("Moved the library back after an interrupted restore")
            }
            if (try? fileManager.contentsOfDirectory(atPath: aside.path))?.isEmpty == true || fileManager.fileExists(atPath: location.storeURL.path) {
                try? fileManager.removeItem(at: aside)
            }
        }
    }

    // MARK: Files

    /// Room left over after a backup, so the live store can still write.
    static let spaceMargin: Int64 = 200 * 1_024 * 1_024

    static func freeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The bytes a backup will take: the store, its log and external blobs.
    static func librarySize(_ location: LibraryLocation) -> Int64 {
        let fileManager = FileManager.default
        var total: Int64 = 0
        for url in [location.storeURL, URL(fileURLWithPath: location.storeURL.path + "-wal")] {
            total += Int64((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0)
        }
        let support = location.folder.appending(path: location.supportName, directoryHint: .isDirectory)
        if let walker = fileManager.enumerator(at: support, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in walker {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Copies whatever exists under `source` but not yet under `destination`.
    static func copyMissingItems(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fileManager.contentsOfDirectory(atPath: source.path) {
            let from = source.appending(path: name)
            let to = destination.appending(path: name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: from.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                try copyMissingItems(from: from, to: to)
            } else if !fileManager.fileExists(atPath: to.path) {
                do {
                    try fileManager.copyItem(at: from, to: to)
                } catch {
                    // Deleted after it was listed: the first pass has it if
                    // the snapshot refers to it. Any other failure counts.
                    if fileManager.fileExists(atPath: from.path) { throw error }
                }
            }
        }
    }

    // MARK: SQLite

    /// A consistent, self-contained copy of the store through SQLite's backup
    /// API: one step copies every page under a single read snapshot, so
    /// writes from the running app never tear it.
    static func copyDatabase(from source: URL, to destination: URL) throws {
        var sourceDB: OpaquePointer?
        guard sqlite3_open_v2(source.path, &sourceDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(sourceDB)
            throw LibraryBackupError.copyFailed("open source")
        }
        defer { sqlite3_close(sourceDB) }
        sqlite3_busy_timeout(sourceDB, 5_000)
        var destinationDB: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &destinationDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(destinationDB)
            throw LibraryBackupError.copyFailed("open destination")
        }
        defer { sqlite3_close(destinationDB) }
        guard let backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") else {
            throw LibraryBackupError.copyFailed(String(cString: sqlite3_errmsg(destinationDB)))
        }
        var result: Int32 = SQLITE_OK
        var attempts = 0
        repeat {
            result = sqlite3_backup_step(backup, -1)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                attempts += 1
                sqlite3_sleep(100)
            }
        } while (result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED) && attempts < 100
        sqlite3_backup_finish(backup)
        if result == SQLITE_FULL { throw LibraryBackupError.diskFull }
        guard result == SQLITE_DONE else { throw LibraryBackupError.copyFailed("step \(result)") }
        // One file, no -wal beside it: easy to copy to another Mac.
        sqlite3_exec(destinationDB, "PRAGMA journal_mode=DELETE", nil, nil, nil)
    }

    /// Photos (not in Recently Deleted) and memories, for the restore list.
    static func countRows(in storeURL: URL) -> (photos: Int?, memories: Int?) {
        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return (nil, nil)
        }
        defer { sqlite3_close(database) }
        func scalar(_ sql: String) -> Int? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int64(statement, 0))
        }
        let photos = scalar("SELECT COUNT(*) FROM ZMEDIAITEM WHERE ZDELETEDAT IS NULL") ?? scalar("SELECT COUNT(*) FROM ZMEDIAITEM")
        return (photos, scalar("SELECT COUNT(*) FROM ZMEMORY"))
    }

    /// The newest modification date of the store and its write-ahead log.
    static func sourceModifiedAt(_ location: LibraryLocation) -> Date? {
        let candidates = [location.storeURL, URL(fileURLWithPath: location.storeURL.path + "-wal")]
        return candidates.compactMap { url -> Date? in
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }.max()
    }

    private static func isDiskFull(_ error: Error) -> Bool {
        if let backupError = error as? LibraryBackupError, backupError == .diskFull { return true }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError { return true }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOSPC)
        }
        return false
    }
}

import AppKit
import Foundation
import MomentsCore
import Observation

/// Runs the automatic daily backup and carries the state the Settings row
/// shows. Backups run off the main thread; there is never more than one.
@MainActor
@Observable
final class BackupController {
    /// The library being backed up. Nil in tests that use an in-memory store,
    /// so they never touch the user's folders.
    private(set) var location: LibraryLocation?
    private(set) var entries: [BackupEntry] = []
    private(set) var isRunning = false
    /// Why the last automatic backup didn't happen, until the next one works.
    private(set) var failure: String?
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// How long after launch the first check waits, so it never competes
    /// with the first pages, and how often it looks again.
    static let firstCheckDelay: Duration = .seconds(90)
    static let checkInterval: Duration = .seconds(3_600)

    var newest: BackupEntry? { BackupPolicy.newest(entries) }

    func configure(location: LibraryLocation?) {
        self.location = location
        refresh()
    }

    /// Starts the daily check loop. Call once the store is open.
    func startSchedule() {
        guard loop == nil, location != nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: Self.firstCheckDelay)
            while !Task.isCancelled {
                await self?.backUpIfDue()
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    func refresh() {
        entries = location.map { BackupPolicy.sortedNewestFirst(LibraryBackup.list(location: $0)) } ?? []
    }

    func backUpIfDue() async {
        guard let location, !isRunning, !LibraryBackup.hasPendingRestore(location: location) else { return }
        isRunning = true
        let outcome: Result<URL?, Error> = await Task.detached(priority: .utility) {
            Result { try LibraryBackup.backUpDailyIfDue(location: location, defaults: .standard) }
        }.value
        isRunning = false
        switch outcome {
        case .success:
            failure = nil
        case .failure(let error):
            failure = error.localizedDescription
            LibraryBackup.logger.error("Daily backup failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// Checks the backup, remembers it for the next launch and reopens
    /// Moments, which restores it before the store opens.
    func restore(_ backupFolder: URL) throws {
        guard let location else { throw LibraryBackupError.noStore }
        try LibraryBackup.scheduleRestore(from: backupFolder, location: location)
        Self.relaunch()
    }

    /// Opens a fresh copy of the app once this one has quit.
    static func relaunch() {
        let bundlePath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path is passed as $0, never spliced into the script.
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}

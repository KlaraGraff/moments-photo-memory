import CryptoKit
import Foundation

/// How a file looked when it was read: its size and modification time. A
/// file that still matches is not read (or hashed) again on resume.
struct ImportFileFingerprint: Codable, Hashable, Sendable {
    let fileSize: Int64
    let modificationTime: Double

    init(fileSize: Int64, modificationTime: Double) {
        self.fileSize = fileSize
        self.modificationTime = modificationTime
    }

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate else { return nil }
        self.init(fileSize: Int64(size), modificationTime: modified.timeIntervalSince1970)
    }
}

/// One file's metadata as it was read, with the fingerprint it was read at.
struct ImportResumeEntry: Codable, Equatable, Sendable {
    let fingerprint: ImportFileFingerprint
    let metadata: ImportedMediaMetadata
}

/// Keeps what a folder import has already read, so a cancelled, failed or
/// interrupted import picks up where it stopped instead of hashing every
/// file again (#36). The folder importer writes it every few hundred files
/// and when it is cancelled, and removes it once the import is saved.
///
/// It is a working file next to the store, never part of the library: the
/// library still receives the folder's photos in one save at the end, after
/// organizing has seen the whole set.
actor ImportResumeStore {
    /// The app's store: Application Support, or a temporary folder in tests.
    static let shared = ImportResumeStore(directory: defaultDirectory)

    private static var defaultDirectory: URL {
        #if DEBUG
        // UI and unit tests never write into the user's Application Support.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-MomentsUITesting") || arguments.contains("-MomentsUITestStoreDirectory") || UnitTestHostDelegate.isUnitTestHost {
            return FileManager.default.temporaryDirectory
                .appending(path: "MomentsTestImportResume-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        }
        #endif
        return URL.applicationSupportDirectory
            .appending(path: "Moments", directoryHint: .isDirectory)
            .appending(path: "ImportResume", directoryHint: .isDirectory)
    }

    /// One batch of reads. A checkpoint is the batches written so far, in
    /// order, so each write costs only its own files, not the whole folder.
    private struct Batch: Codable {
        var version = 1
        var folderKey: String
        var entries: [String: ImportResumeEntry]
    }

    private let directory: URL?
    private var memory: [String: [String: ImportResumeEntry]] = [:]

    /// `nil` keeps checkpoints in memory only, for tests.
    init(directory: URL?) {
        self.directory = directory
    }

    /// The entries saved for `folderKey`, keyed by each file's standardized
    /// path. A later batch's entry for a file replaces an earlier one.
    func entries(forFolder folderKey: String) -> [String: ImportResumeEntry] {
        if let cached = memory[folderKey] { return cached }
        guard let folder = folderURL(forFolder: folderKey) else { return [:] }
        var merged: [String: ImportResumeEntry] = [:]
        let decoder = PropertyListDecoder()
        for url in batchURLs(in: folder) {
            guard let data = try? Data(contentsOf: url),
                  let batch = try? decoder.decode(Batch.self, from: data),
                  batch.version == 1, batch.folderKey == folderKey else {
                // An unreadable batch only costs reading its files again.
                continue
            }
            merged.merge(batch.entries) { _, later in later }
        }
        memory[folderKey] = merged
        return merged
    }

    /// Adds one batch of reads to the folder's checkpoint.
    func append(_ entries: [String: ImportResumeEntry], forFolder folderKey: String) {
        guard !entries.isEmpty else { return }
        var merged = self.entries(forFolder: folderKey)
        merged.merge(entries) { _, later in later }
        memory[folderKey] = merged
        guard let folder = folderURL(forFolder: folderKey) else { return }
        let encoder = PropertyListEncoder()
        // Binary keeps every date and coordinate bit-for-bit.
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(Batch(folderKey: folderKey, entries: entries)) else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let next = (batchURLs(in: folder).last.flatMap(Self.batchNumber) ?? 0) + 1
            let url = folder.appending(path: String(format: "batch-%06d.plist", next))
            try data.write(to: url, options: [.atomic])
        } catch {
            // Without this batch a resume reads its files again; nothing is lost.
        }
    }

    func remove(forFolder folderKey: String) {
        memory[folderKey] = nil
        guard let folder = folderURL(forFolder: folderKey) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The checkpoint's folder: named by a hash, so the imported folder's
    /// path stays out of file names.
    private func folderURL(forFolder folderKey: String) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(folderKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest, directoryHint: .isDirectory)
    }

    private func batchURLs(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { Self.batchNumber($0) != nil }
            .sorted { (Self.batchNumber($0) ?? 0) < (Self.batchNumber($1) ?? 0) }
    }

    private static func batchNumber(_ url: URL) -> Int? {
        let name = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "plist", name.hasPrefix("batch-") else { return nil }
        return Int(name.dropFirst("batch-".count))
    }
}

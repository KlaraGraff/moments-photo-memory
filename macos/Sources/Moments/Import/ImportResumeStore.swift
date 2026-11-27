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

    static var defaultDirectory: URL {
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
        var version = ImportResumeStore.version
        var folderKey: String
        var entries: [String: ImportResumeEntry]
    }

    /// The checkpoint format and what the metadata reader reads. Bump it when
    /// `MediaMetadataReader` changes what it reads, so older reads are not reused.
    static let version = 1
    /// A checkpoint nobody resumed for this long is removed.
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    private let directory: URL?
    /// Checkpoints of the in-memory store only; the disk store keeps none in
    /// memory, so a cancelled import's reads do not stay in RAM.
    private var memory: [String: [String: ImportResumeEntry]] = [:]

    /// `nil` keeps checkpoints in memory only, for tests.
    init(directory: URL?) {
        self.directory = directory
    }

    /// The entries saved for `folderKey`, keyed by each file's standardized
    /// path. A later batch's entry for a file replaces an earlier one.
    func entries(forFolder folderKey: String) -> [String: ImportResumeEntry] {
        guard let directory else { return memory[folderKey] ?? [:] }
        removeStale(in: directory, now: .now)
        let folder = folderURL(in: directory, forFolder: folderKey)
        var merged: [String: ImportResumeEntry] = [:]
        let decoder = PropertyListDecoder()
        for url in batchURLs(in: folder) {
            guard let data = try? Data(contentsOf: url),
                  let batch = try? decoder.decode(Batch.self, from: data),
                  batch.version == Self.version, batch.folderKey == folderKey else {
                // An unreadable or older batch only costs reading its files again.
                continue
            }
            merged.merge(batch.entries) { _, later in later }
        }
        return merged
    }

    /// Adds one batch of reads to the folder's checkpoint.
    func append(_ entries: [String: ImportResumeEntry], forFolder folderKey: String) {
        guard !entries.isEmpty else { return }
        guard let directory else {
            memory[folderKey, default: [:]].merge(entries) { _, later in later }
            return
        }
        let folder = folderURL(in: directory, forFolder: folderKey)
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
        guard let directory else { return }
        try? FileManager.default.removeItem(at: folderURL(in: directory, forFolder: folderKey))
    }

    /// Removes checkpoints whose newest batch is older than `maximumAge`:
    /// an import cancelled and never resumed, or a folder since moved.
    func removeStale(in directory: URL, now: Date) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        for folder in folders {
            let batches = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
            let newest = batches.compactMap { try? $0.resourceValues(forKeys: keys).contentModificationDate }.max()
                ?? (try? folder.resourceValues(forKeys: keys).contentModificationDate)
            if let newest, now.timeIntervalSince(newest) > Self.maximumAge {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// The checkpoint's folder: named by a hash, so the imported folder's
    /// path stays out of file names (the batches inside still hold paths).
    private func folderURL(in directory: URL, forFolder folderKey: String) -> URL {
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

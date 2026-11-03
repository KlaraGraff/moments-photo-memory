import CoreGraphics
import Foundation
import ImageIO
import Observation
import SwiftData
import Vision

/// Keeps clear documents, receipts, screenshots and drawings out of the
/// import review list. Only a highly confident answer from Vision counts, and
/// anything that looks like a camera scene or a person keeps the photo.
/// Nothing is uploaded: classification runs on the thumbnail already on disk.
enum ReviewNoiseClassifier {
    /// Labels that mean a saved page or drawing rather than a camera photo.
    /// Taken from `VNClassifyImageRequest.supportedIdentifiers()`; Vision has
    /// no cartoon, drawing or text label (see `out/identifiers.txt`).
    static let noiseIdentifiers: Set<String> = [
        "document",
        "receipt",
        "screenshot",
        "illustrations",
        "printed_page",
        "handwriting"
    ]

    /// Labels that mean a camera was there, or someone is in the picture.
    /// One of these above `maximumPhotoConfidence` keeps the item. Only names
    /// Vision 1303 actually returns are listed; there is no person, face,
    /// portrait, landscape, selfie or street label.
    static let photoIdentifiers: Set<String> = [
        "people",
        "adult",
        "child",
        "baby",
        "crowd",
        "outdoor",
        "forest",
        "beach",
        "mountain",
        "sky",
        "park",
        "garden"
    ]

    /// A chosen label must reach this confidence before the item is removed.
    static let minimumNoiseConfidence: Float = 0.85
    /// A person or outdoor label at this confidence or above keeps the item.
    static let maximumPhotoConfidence: Float = 0.3

    /// True only when one chosen label is highly confident and no person or
    /// outdoor label is present. Anything unsure stays in the review list.
    static func isNoise(observations: [(identifier: String, confidence: Float)]) -> Bool {
        var definitelyNoise = false
        for observation in observations {
            let identifier = observation.identifier.lowercased()
            if photoIdentifiers.contains(identifier), observation.confidence >= maximumPhotoConfidence {
                return false
            }
            if noiseIdentifiers.contains(identifier), observation.confidence >= minimumNoiseConfidence {
                definitelyNoise = true
            }
        }
        return definitelyNoise
    }

    /// Runs the on-device classification and returns the raw observations.
    static func observations(for image: CGImage) -> [(identifier: String, confidence: Float)] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).map { (observation: VNClassificationObservation) -> (identifier: String, confidence: Float) in
            (identifier: observation.identifier, confidence: observation.confidence)
        }
    }

    static func classify(_ image: CGImage) -> Bool {
        isNoise(observations: observations(for: image))
    }
}

/// Loads the image a review item's thumbnail is made from, only from what is
/// already on this Mac (never from iCloud), like burst analysis does.
enum ReviewNoiseImageLoader {
    nonisolated static func load(photosLocalIdentifier: String?, bookmark: Data?) async -> CGImage? {
        if let photosLocalIdentifier,
           let image = await PhotoKitAssetSource.shared.thumbnailImage(
            forLocalIdentifier: photosLocalIdentifier,
            targetSize: CGSize(width: 1_024, height: 1_024),
            networkAccessAllowed: false
           ) {
            return image
        }
        guard let bookmark, let resolved = try? OriginalMediaBookmark.resolve(bookmark) else { return nil }
        let scoped = resolved.url.startAccessingSecurityScopedResource()
        defer { if scoped { resolved.url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(resolved.url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_024,
            kCGImageSourceShouldCache: false
        ] as CFDictionary)
    }
}

/// The classification results, kept as `id -> isNoise` in a JSON file next to
/// the other caches. A missing id was never classified (or its image could not
/// be read) and is tried again on a later run.
final class ReviewNoiseCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool]
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.values = Self.read(from: self.fileURL)
    }

    func hasValue(for id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values[id] != nil
    }

    func isNoise(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values[id] ?? false
    }

    func record(_ isNoise: Bool, for id: String) {
        lock.lock()
        values[id] = isNoise
        lock.unlock()
    }

    func save() throws {
        lock.lock()
        let snapshot = values
        lock.unlock()
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    static var defaultFileURL: URL {
        #if DEBUG
        // Tests never write into the user's Application Support.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-MomentsUITesting") || arguments.contains("-MomentsUITestStoreDirectory") || UnitTestHostDelegate.isUnitTestHost {
            return FileManager.default.temporaryDirectory
                .appending(path: "MomentsTestReviewNoise-\(ProcessInfo.processInfo.processIdentifier).json")
        }
        #endif
        return URL.applicationSupportDirectory
            .appending(path: "Moments", directoryHint: .isDirectory)
            .appending(path: "review-noise.json")
    }

    private static func read(from url: URL) -> [String: Bool] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return [:]
        }
        return decoded
    }
}

/// Classifies the review items whose thumbnail has not been checked yet, in
/// the background at utility priority. Results are saved every 50 items, so a
/// quit loses at most the last batch.
enum ReviewNoiseScan {
    nonisolated static func run(container: ModelContainer, cache: ReviewNoiseCache) async -> Int {
        let context = ModelContext(container)
        // Only flagged items are fetched: the review list is small next to a
        // 50,000 photo library, and the pass must not walk all of it.
        let descriptor = FetchDescriptor<MediaItem>(
            predicate: #Predicate<MediaItem> { $0.importReviewReasonsRaw != nil },
            sortBy: [SortDescriptor(\.id)]
        )
        guard let items = try? context.fetch(descriptor) else { return 0 }
        let pending = items.filter { (item: MediaItem) -> Bool in
            item.needsImportReview
                && !cache.hasValue(for: item.id)
                && (item.photosLocalIdentifier != nil || item.originalBookmarkData != nil)
        }
        var classified = 0
        for item in pending {
            if Task.isCancelled { break }
            let id = item.id
            let localIdentifier = item.photosLocalIdentifier
            let bookmark = item.originalBookmarkData
            guard let image = await ReviewNoiseImageLoader.load(photosLocalIdentifier: localIdentifier, bookmark: bookmark) else {
                continue
            }
            let noise = ReviewNoiseClassifier.classify(image)
            cache.record(noise, for: id)
            classified += 1
            if classified.isMultiple(of: 50) {
                try? cache.save()
            }
        }
        if classified > 0 {
            try? cache.save()
        }
        return classified
    }
}

/// What the Library reads: the cached answers, plus the one background pass
/// that fills them. `revision` moves when new answers arrive, so the review
/// count and list are rebuilt.
@MainActor
@Observable
final class ReviewNoiseStore {
    static let shared = ReviewNoiseStore()

    @ObservationIgnored private let cache: ReviewNoiseCache
    private(set) var revision = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runAgain = false

    init(fileURL: URL? = nil) {
        self.cache = ReviewNoiseCache(fileURL: fileURL)
    }

    /// Reading `revision` first ties the caller to the observation, so a
    /// review row and the banner are rebuilt when new answers arrive.
    func isNoise(_ id: String) -> Bool {
        _ = revision
        return cache.isNoise(id)
    }

    /// Starts the pass unless one runs already; a request that arrives during
    /// a run makes it go once more, so photos imported meanwhile are covered.
    func start(container: ModelContainer) {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if UnitTestHostDelegate.isUnitTestHost
            || arguments.contains("-MomentsUITesting")
            || arguments.contains("-MomentsUITestStoreDirectory") {
            return
        }
        #endif
        guard task == nil else {
            runAgain = true
            return
        }
        let cache = self.cache
        task = Task { [weak self] in
            let classified = await Task.detached(priority: .utility) {
                await ReviewNoiseScan.run(container: container, cache: cache)
            }.value
            guard let self else { return }
            self.task = nil
            if classified > 0 {
                self.revision += 1
            }
            if self.runAgain, !Task.isCancelled {
                self.runAgain = false
                self.start(container: container)
            }
        }
    }
}

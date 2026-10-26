import AppKit
import Foundation
import ImageIO
import MomentsCore
import Observation
import SwiftData
import Vision

/// What Vision measured on one photo for stacking: how it looks (feature
/// print) and how good a shot it is. Derived on this Mac only; never synced.
struct PhotoStackAnalysis: Codable, Equatable, Sendable {
    var featurePrint: [Float]?
    var quality: StackQuality?

    private enum CodingKeys: String, CodingKey { case featurePrint, quality }

    init(featurePrint: [Float]?, quality: StackQuality?) {
        self.featurePrint = featurePrint
        self.quality = quality
    }

    // The print is kept as raw bytes: a few KB a photo instead of a list of numbers.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let data = try container.decodeIfPresent(Data.self, forKey: .featurePrint)
        featurePrint = data.map { bytes in
            bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        quality = try container.decodeIfPresent(StackQuality.self, forKey: .quality)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let featurePrint {
            try container.encode(featurePrint.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .featurePrint)
        }
        try container.encodeIfPresent(quality, forKey: .quality)
    }
}

/// The analysis results, kept in a small file next to the thumbnails.
/// `revision` changes whenever new results arrive, so screens regroup.
@MainActor
@Observable
final class PhotoStackAnalysisStore {
    static let shared = PhotoStackAnalysisStore(fileURL: PhotoStackAnalysisStore.defaultFileURL)

    private(set) var entries: [String: PhotoStackAnalysis] = [:]
    private(set) var revision = 0
    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? PropertyListDecoder().decode([String: PhotoStackAnalysis].self, from: data) {
            entries = decoded
        }
    }

    private static var defaultFileURL: URL? {
        #if DEBUG
        // UI and unit tests never write into the user's Application Support.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-MomentsUITesting") || arguments.contains("-MomentsUITestStoreDirectory") || UnitTestHostDelegate.isUnitTestHost {
            return nil
        }
        #endif
        return URL.applicationSupportDirectory
            .appending(path: "Moments", directoryHint: .isDirectory)
            .appending(path: "Analysis", directoryHint: .isDirectory)
            .appending(path: "photo-stacks-v1.plist")
    }

    func merge(_ results: [String: PhotoStackAnalysis]) {
        guard !results.isEmpty else { return }
        entries.merge(results) { _, new in new }
        revision += 1
        guard let fileURL else { return }
        let snapshot = entries
        Task.detached(priority: .utility) {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Measures, in the background, only the photos that could be part of a
/// burst: those with another photo a few seconds before or after them.
@MainActor
@Observable
final class PhotoStackAnalyzer {
    private(set) var isRunning = false
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runAgain = false
    @ObservationIgnored private let store: PhotoStackAnalysisStore
    @ObservationIgnored private let maximumGap: TimeInterval

    init(store: PhotoStackAnalysisStore = .shared, maximumGap: TimeInterval = PhotoStackDetector().maximumGap) {
        self.store = store
        self.maximumGap = maximumGap
    }

    func configure(container: ModelContainer) {
        self.container = container
    }

    func analyzeIfNeeded() {
        guard let container else { return }
        guard task == nil else {
            runAgain = true
            return
        }
        isRunning = true
        let known = Set(store.entries.keys)
        let gap = maximumGap
        task = Task { @MainActor [weak self] in
            let pending = await Task.detached(priority: .utility) {
                Self.pendingPhotos(container: container, known: known, maximumGap: gap)
            }.value
            for batch in stride(from: 0, to: pending.count, by: 12) {
                guard !Task.isCancelled else { break }
                let slice = Array(pending[batch..<min(batch + 12, pending.count)])
                let results = await Task.detached(priority: .utility) {
                    var results: [String: PhotoStackAnalysis] = [:]
                    for photo in slice {
                        guard !Task.isCancelled else { break }
                        if let image = await Self.loadImage(photo) {
                            results[photo.id] = Self.analyse(image)
                        }
                    }
                    return results
                }.value
                self?.store.merge(results)
            }
            guard let self else { return }
            self.task = nil
            self.isRunning = false
            if self.runAgain {
                self.runAgain = false
                self.analyzeIfNeeded()
            }
        }
    }

    struct PendingPhoto: Sendable {
        let id: String
        let photosLocalIdentifier: String?
        let bookmark: Data?
    }

    /// Photos with a real image behind them, not yet measured, that have a
    /// neighbour within the burst gap.
    nonisolated static func pendingPhotos(container: ModelContainer, known: Set<String>, maximumGap: TimeInterval) -> [PendingPhoto] {
        let context = ModelContext(container)
        // Live Photos stack too; only videos never do.
        let videoKind = MediaKind.video.rawValue
        let descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.isScreenshot == false && $0.kindRaw != videoKind })
        guard let items = try? context.fetch(descriptor) else { return [] }
        let dated = items
            .compactMap { item -> (MediaItem, Date)? in item.effectiveCaptureDate.map { (item, $0) } }
            .sorted { $0.1 < $1.1 }
        var result: [PendingPhoto] = []
        for (index, entry) in dated.enumerated() {
            let item = entry.0
            guard !known.contains(item.id), item.photosLocalIdentifier != nil || item.originalBookmarkData != nil else { continue }
            let before = index > 0 && entry.1.timeIntervalSince(dated[index - 1].1) <= maximumGap
            let after = index + 1 < dated.count && dated[index + 1].1.timeIntervalSince(entry.1) <= maximumGap
            guard before || after else { continue }
            result.append(PendingPhoto(id: item.id, photosLocalIdentifier: item.photosLocalIdentifier, bookmark: item.originalBookmarkData))
        }
        return result
    }

    /// A copy about 1,000 pixels across: enough for faces and sharpness.
    nonisolated static func loadImage(_ photo: PendingPhoto) async -> CGImage? {
        if let localIdentifier = photo.photosLocalIdentifier,
           let image = await PhotoKitAssetSource().thumbnailImage(
            forLocalIdentifier: localIdentifier,
            targetSize: CGSize(width: 1_024, height: 1_024),
            networkAccessAllowed: true
           ) {
            return image
        }
        guard let bookmark = photo.bookmark, let resolved = try? OriginalMediaBookmark.resolve(bookmark) else { return nil }
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

    /// Feature print, faces (capture quality, eyes) and sharpness.
    nonisolated static func analyse(_ image: CGImage) -> PhotoStackAnalysis {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let printRequest = VNGenerateImageFeaturePrintRequest()
        let faceRequest = VNDetectFaceLandmarksRequest()
        try? handler.perform([printRequest, faceRequest])

        var featurePrint: [Float]?
        if let observation = printRequest.results?.first {
            featurePrint = floats(of: observation)
        }

        // Faces too small to matter in the picture are left out.
        let faces = (faceRequest.results ?? []).filter { $0.boundingBox.width >= 0.05 }
        var faceQuality = 0.0
        var eyesOpen = 0.0
        if !faces.isEmpty {
            let qualityRequest = VNDetectFaceCaptureQualityRequest()
            qualityRequest.inputFaceObservations = faces
            try? handler.perform([qualityRequest])
            let scores = (qualityRequest.results ?? []).compactMap { $0.faceCaptureQuality.map(Double.init) }
            faceQuality = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
            let open = faces.filter(hasOpenEyes).count
            eyesOpen = Double(open) / Double(faces.count)
        }
        let quality = StackQuality(sharpness: sharpness(of: image), faceCount: faces.count, faceQuality: faceQuality, eyesOpen: eyesOpen)
        return PhotoStackAnalysis(featurePrint: featurePrint, quality: quality)
    }

    nonisolated private static func floats(of observation: VNFeaturePrintObservation) -> [Float]? {
        let data = observation.data
        switch observation.elementType {
        case .float:
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        case .double:
            return data.withUnsafeBytes { $0.bindMemory(to: Double.self).map { Float($0) } }
        default:
            return nil
        }
    }

    /// Both eye outlines are clearly taller than a slit.
    nonisolated private static func hasOpenEyes(_ face: VNFaceObservation) -> Bool {
        guard let left = face.landmarks?.leftEye, let right = face.landmarks?.rightEye else { return false }
        return openness(left) >= 0.18 && openness(right) >= 0.18
    }

    nonisolated private static func openness(_ region: VNFaceLandmarkRegion2D) -> Double {
        let points = region.normalizedPoints
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX > minX else { return 0 }
        return Double((maxY - minY) / (maxX - minX))
    }

    /// Variance of the Laplacian on a grey copy 512 pixels across.
    nonisolated static func sharpness(of image: CGImage) -> Double {
        let width = 512
        let height = max(8, Int(Double(width) * Double(image.height) / Double(max(1, image.width))))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return 0 }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        var squares = 0.0
        var count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = Int(pixels[y * width + x])
                let value = Int(pixels[(y - 1) * width + x]) + Int(pixels[(y + 1) * width + x])
                    + Int(pixels[y * width + x - 1]) + Int(pixels[y * width + x + 1]) - 4 * center
                let laplacian = Double(value)
                sum += laplacian
                squares += laplacian * laplacian
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return squares / count - mean * mean
    }
}

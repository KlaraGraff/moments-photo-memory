import AppKit
import CoreImage
import CoreML
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Vision

public struct FaceCandidate: Sendable, Equatable {
    public let rect: CGRect
    public let quality: Double
    public let points: [CGPoint]
    public init(rect: CGRect, quality: Double, points: [CGPoint]) { self.rect = rect; self.quality = quality; self.points = points }
}

public enum FaceDetector {
    public static let minimumWidth: CGFloat = 48
    public static let minimumQuality = 0.25
    public static func detect(in image: CGImage) throws -> [FaceCandidate] {
        let sourceSize = CGSize(width: image.width, height: image.height)
        let workingImage = downscaled(image, maxDimension: 2_000)
        let request = VNDetectFaceLandmarksRequest()
        let quality = VNDetectFaceCaptureQualityRequest()
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 6
        rectangles.minimumAspectRatio = 0.3
        rectangles.maximumAspectRatio = 0.8
        rectangles.minimumSize = 0.08
        let handler = VNImageRequestHandler(cgImage: workingImage, options: [:])
        try handler.perform([request, rectangles])
        let phoneRects = (rectangles.results ?? []).map(\.boundingBox)
        let detected = request.results ?? []
        // Score exactly the detected faces; a quality request without input
        // observations finds its own faces in a different order.
        quality.inputFaceObservations = detected
        try handler.perform([quality])
        let scored = quality.results ?? []
        let faces = zip(detected, scored.count == detected.count ? scored : detected).map { ($0, $1.faceCaptureQuality) }
        return faces.compactMap { (face, captureQuality) -> FaceCandidate? in
            let box = face.boundingBox
            let width = box.width * CGFloat(workingImage.width)
            guard width >= minimumWidth else { return nil }
            let score = Double(captureQuality ?? 0)
            guard score >= minimumQuality else { return nil }
            guard !phoneRects.contains(where: { phone in
                phone.width * phone.height >= box.width * box.height * 3 && phone.contains(box) && phone.height > phone.width
            }) else { return nil }
            guard let landmarks = face.landmarks else { return nil }
            let points = LandmarkPoints.make(face: face, landmarks: landmarks).map {
                // Vision reports normalized y-up coordinates. Alignment uses
                // y-down image pixels, so convert before solving the transform.
                CGPoint(x: $0.x * sourceSize.width, y: sourceSize.height - $0.y * sourceSize.height)
            }
            guard points.count == 5 else { return nil }
            return FaceCandidate(rect: box, quality: Double(score), points: points)
        }
    }

    private static func downscaled(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

private enum LandmarkPoints {
    static func make(face: VNFaceObservation, landmarks: VNFaceLandmarks2D) -> [CGPoint] {
        func centroid(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let region, region.pointCount > 0 else { return nil }
            let pts = region.normalizedPoints
            let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count))
        }
        func outerCorner(_ region: VNFaceLandmarkRegion2D?, left: Bool) -> CGPoint? {
            guard let region, region.pointCount > 0 else { return nil }
            let points = region.normalizedPoints
            return (left ? points.min(by: { $0.x < $1.x }) : points.max(by: { $0.x < $1.x }))
        }
        guard let left = centroid(landmarks.leftEye), let right = centroid(landmarks.rightEye),
              let noseRegion = landmarks.nose, noseRegion.pointCount > 0,
              let mouthLeft = outerCorner(landmarks.outerLips, left: true),
              let mouthRight = outerCorner(landmarks.outerLips, left: false) else { return [] }
        // Vision landmark coordinates are y-up. The lowest point in the face
        // therefore has the smallest y and is used as the nose landmark.
        let nose = noseRegion.normalizedPoints.min(by: { $0.y < $1.y })!
        func imagePoint(_ p: CGPoint) -> CGPoint {
            // Vision's landmark coordinates are y-up within the face box.
            CGPoint(x: face.boundingBox.minX + p.x * face.boundingBox.width,
                    y: face.boundingBox.minY + p.y * face.boundingBox.height)
        }
        let values = [imagePoint(left), imagePoint(right), imagePoint(nose), imagePoint(mouthLeft), imagePoint(mouthRight)]
        let imageOrderedEyes = values.prefix(2).sorted { $0.x < $1.x }
        let ordered = [imageOrderedEyes[0], imageOrderedEyes[1], values[2], values[3], values[4]]
        return ordered
    }
}

public enum FaceAlignment {
    public static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366), CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041)
    ]
    public static func transform(from source: [CGPoint], to target: [CGPoint] = template) -> CGAffineTransform? {
        guard source.count == target.count, source.count >= 2 else { return nil }
        var ata = Array(repeating: Array(repeating: 0.0, count: 4), count: 4)
        var atb = Array(repeating: 0.0, count: 4)
        for (p, q) in zip(source, target) {
            let rows: [(Double, Double)] = [(Double(p.x), -Double(p.y)), (Double(p.y), Double(p.x))]
            let rhs = [Double(q.x), Double(q.y)]
            for r in 0..<2 {
                let row = [rows[r].0, rows[r].1, r == 0 ? 1.0 : 0.0, r == 1 ? 1.0 : 0.0]
                for i in 0..<4 { for j in 0..<4 { ata[i][j] += row[i] * row[j] } }
                for i in 0..<4 { atb[i] += row[i] * rhs[r] }
            }
        }
        guard let x = solve(ata, atb) else { return nil }
        return CGAffineTransform(a: x[0], b: x[1], c: -x[1], d: x[0], tx: x[2], ty: x[3])
    }
    public static func alignedCrop(_ image: CGImage, points: [CGPoint]) -> CGImage? {
        guard let transform = transform(from: points) else { return nil }
        let width = 112
        let height = 112
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Work in the image's requested x-right/y-down coordinate system while
        // Core Graphics retains its native y-up backing store. The transform
        // maps y-down image pixels to y-down template pixels.
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.concatenate(transform)
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
    private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = a.enumerated().map { $0.element + [b[$0.offset]] }
        for col in 0..<4 {
            guard let pivot = (col..<4).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-9 else { return nil }
            m.swapAt(col, pivot)
            let divisor = m[col][col]; for j in col..<5 { m[col][j] /= divisor }
            for row in 0..<4 where row != col { let factor = m[row][col]; for j in col..<5 { m[row][j] -= factor * m[col][j] } }
        }
        return m.map { $0[4] }
    }
}

public protocol FaceEmbedder: Sendable {
    var isAvailable: Bool { get }
    func embedding(for crop: CGImage) throws -> [Float]
}

public enum FaceEmbedderError: Error, Equatable { case unavailable, invalidOutput }

public final class SFaceCoreMLEmbedder: FaceEmbedder, @unchecked Sendable {
    private let model: MLModel?
    public let isAvailable: Bool
    public init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "SFace", withExtension: "mlmodelc") else { model = nil; isAvailable = false; return }
        model = try? MLModel(contentsOf: url, configuration: MLModelConfiguration())
        isAvailable = model != nil
    }
    public func embedding(for crop: CGImage) throws -> [Float] {
        guard let model else { throw FaceEmbedderError.unavailable }
        let inputs = model.modelDescription.inputDescriptionsByName
        let outputs = model.modelDescription.outputDescriptionsByName
        let inputName = inputs["data"] != nil ? "data" : inputs.first { $0.value.type == .multiArray }?.key
        let outputName = outputs["embedding"] != nil ? "embedding" : outputs.first { $0.value.type == .multiArray }?.key
        guard let inputName, let outputName,
              let pixels = Self.inputTensor(from: crop),
              let array = try? MLMultiArray(shape: [1, 3, 112, 112], dataType: .float32) else { throw FaceEmbedderError.invalidOutput }
        let pointer = array.dataPointer.bindMemory(to: Float32.self, capacity: pixels.count)
        pixels.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: pixels.count) }
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)]))
        guard let output = result.featureValue(for: outputName)?.multiArrayValue, output.count == 128 else { throw FaceEmbedderError.invalidOutput }
        var values = (0..<output.count).map { Float(truncating: output[$0]) }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { throw FaceEmbedderError.invalidOutput }
        values = values.map { $0 / norm }
        return values
    }

    /// The SFace input: 1x3x112x112, RGB channel order, raw 0...255 values
    /// (the model applies its own mean and scale). RGB was verified against
    /// hand-labelled faces; BGR loses recall at the same precision.
    static func inputTensor(from crop: CGImage) -> [Float]? {
        var bytes = [UInt8](repeating: 0, count: 112 * 112 * 4)
        guard let context = CGContext(
            data: &bytes, width: 112, height: 112, bitsPerComponent: 8, bytesPerRow: 112 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 112, height: 112))
        let plane = 112 * 112
        var tensor = [Float](repeating: 0, count: 3 * plane)
        for index in 0..<plane {
            tensor[index] = Float(bytes[index * 4])
            tensor[plane + index] = Float(bytes[index * 4 + 1])
            tensor[2 * plane + index] = Float(bytes[index * 4 + 2])
        }
        return tensor
    }
}

public enum FaceClustering {
    public static let defaultThreshold: Float = 0.65

    public struct AverageLinkResult: Sendable, Equatable {
        public let clusters: [[Int]]
        public let stopped: Bool
        public init(clusters: [[Int]], stopped: Bool) {
            self.clusters = clusters
            self.stopped = stopped
        }
    }

    /// Average-link clustering with the nearest-neighbour chain algorithm.
    /// Average linkage is reducible, so merging reciprocal nearest neighbours
    /// in any order gives the same clusters as the textbook greedy method, and
    /// a cluster whose nearest neighbour is at or above the threshold can never
    /// merge again. Memory is the flat triangular Float32 matrix only: about
    /// 18 MB at 3,000 faces, however the faces split between people.
    public static func averageLinkResult(_ vectors: [[Float]], threshold: Float = defaultThreshold, shouldStop: (@Sendable () -> Bool)? = nil) -> AverageLinkResult {
        guard !vectors.isEmpty else { return AverageLinkResult(clusters: [], stopped: false) }
        let stop = shouldStop ?? { Task.isCancelled }
        let count = vectors.count
        let normalizedVectors = vectors.map(normalize)
        var clusters = vectors.indices.map { [$0] }
        var sizes = Array(repeating: 1, count: count)
        var active = Array(repeating: true, count: count)
        var finished = Array(repeating: false, count: count)
        var distances = Array(repeating: Float.infinity, count: count * max(count - 1, 0) / 2)
        func offset(_ a: Int, _ b: Int) -> Int {
            let i = min(a, b), j = max(a, b)
            return i * count - i * (i + 1) / 2 + j - i - 1
        }
        for i in 0..<count {
            for j in (i + 1)..<count {
                distances[offset(i, j)] = normalizedDistance(normalizedVectors[i], normalizedVectors[j])
            }
        }
        var chain: [Int] = []
        var nextStart = 0
        var steps = 0
        var stopped = false
        while true {
            if chain.isEmpty {
                while nextStart < count && (!active[nextStart] || finished[nextStart]) { nextStart += 1 }
                guard nextStart < count else { break }
                chain.append(nextStart)
            }
            steps += 1
            // The stop check reads power state, so do it every 64 steps, not every step.
            if steps % 64 == 1 && stop() { stopped = true; break }
            let current = chain[chain.count - 1]
            let previous = chain.count >= 2 ? chain[chain.count - 2] : -1
            var nearest = -1
            var nearestDistance = Float.infinity
            for k in 0..<count where active[k] && k != current {
                let d = distances[offset(current, k)]
                if d < nearestDistance { nearestDistance = d; nearest = k }
            }
            // Prefer the previous chain element on ties so the chain always terminates.
            if previous >= 0, distances[offset(current, previous)] <= nearestDistance {
                nearest = previous
                nearestDistance = distances[offset(current, previous)]
            }
            guard nearest >= 0, nearestDistance < threshold else {
                finished[current] = true
                chain.removeLast()
                continue
            }
            guard nearest == previous else {
                chain.append(nearest)
                continue
            }
            chain.removeLast(2)
            let keep = min(current, previous), drop = max(current, previous)
            let keepSize = sizes[keep], dropSize = sizes[drop]
            for k in 0..<count where active[k] && k != keep && k != drop {
                // Lance–Williams update for average linkage.
                let merged = (Float(keepSize) * distances[offset(keep, k)] + Float(dropSize) * distances[offset(drop, k)]) / Float(keepSize + dropSize)
                distances[offset(keep, k)] = merged
            }
            clusters[keep].append(contentsOf: clusters[drop])
            clusters[drop] = []
            sizes[keep] += dropSize
            active[drop] = false
            if keep < nextStart { nextStart = keep }
        }
        return AverageLinkResult(clusters: clusters.indices.compactMap { active[$0] ? clusters[$0] : nil }, stopped: stopped)
    }

    public static func averageLink(_ vectors: [[Float]], threshold: Float = defaultThreshold, shouldStop: (@Sendable () -> Bool)? = nil) -> [[Int]] {
        averageLinkResult(vectors, threshold: threshold, shouldStop: shouldStop).clusters
    }

    public static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 1 }
        let dot = zip(lhs, rhs).reduce(Float.zero) { $0 + $1.0 * $1.1 }
        let lhsNorm = sqrt(lhs.reduce(Float.zero) { $0 + $1 * $1 })
        let rhsNorm = sqrt(rhs.reduce(Float.zero) { $0 + $1 * $1 })
        guard lhsNorm > 0, rhsNorm > 0 else { return 1 }
        return 1 - dot / (lhsNorm * rhsNorm)
    }

    private static func normalizedDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 1 }
        return 1 - zip(lhs, rhs).reduce(Float.zero) { $0 + $1.0 * $1.1 }
    }
    public static var isPowerPaused: Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return source == kIOPSBatteryPowerValue ||
            ProcessInfo.processInfo.isLowPowerModeEnabled ||
            ProcessInfo.processInfo.thermalState == .serious ||
            ProcessInfo.processInfo.thermalState == .critical
    }

    private static func normalize(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Computes the centroid used for machine suggestions. Callers decide which
    /// observations are user-confirmed before passing their embeddings here.
    public static func centroid(of vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = Array(repeating: Float.zero, count: first.count)
        for vector in vectors where vector.count == sum.count {
            for index in sum.indices { sum[index] += vector[index] }
        }
        let count = Float(vectors.filter { $0.count == sum.count }.count)
        guard count > 0 else { return [] }
        return normalize(sum.map { $0 / count })
    }

    public static func assignIncrementally(
        _ vector: [Float],
        to confirmed: [(id: String, centroid: [Float])],
        rejecting rejectedIDs: Set<String> = [],
        threshold: Float = 0.55
    ) -> String? {
        confirmed
            .filter { !rejectedIDs.contains($0.id) }
            .min(by: { cosineDistance(vector, $0.centroid) < cosineDistance(vector, $1.centroid) })
            .flatMap { cosineDistance(vector, $0.centroid) < threshold ? $0.id : nil }
    }
}

public struct PeopleScanProgress: Sendable, Equatable { public let completed: Int; public let total: Int; public let isPaused: Bool }
public struct PeopleScanItem: @unchecked Sendable { public let id: String; public let image: CGImage; public init(id: String, image: CGImage) { self.id = id; self.image = image } }

public struct FaceObservationDraft: Sendable {
    public let rect: (x: Double, y: Double, w: Double, h: Double)
    public let quality: Double
    public let embedding: Data
    public let cropData: Data

    public init(rect: (x: Double, y: Double, w: Double, h: Double), quality: Double, embedding: Data, cropData: Data) {
        self.rect = rect
        self.quality = quality
        self.embedding = embedding
        self.cropData = cropData
    }
}

public struct PeopleScanResult: Sendable {
    public let mediaID: String
    public let faces: [FaceObservationDraft]

    public init(mediaID: String, faces: [FaceObservationDraft]) {
        self.mediaID = mediaID
        self.faces = faces
    }
}

public actor PeopleScanPipeline {
    private let embedder: any FaceEmbedder
    private var cancelled = false
    public init(embedder: any FaceEmbedder) { self.embedder = embedder }
    public func cancel() { cancelled = true }
    public func scan(_ items: [PeopleScanItem], onProgress: @Sendable (PeopleScanProgress) -> Void = { _ in }) async -> [String: [Float]] {
        let detailed = await scanDetailed(items, onProgress: onProgress)
        return detailed.reduce(into: [:]) { result, item in
            guard let first = item.faces.first else { return }
            result[item.mediaID] = Self.decodeEmbedding(first.embedding)
        }
    }

    public func scanDetailed(_ items: [PeopleScanItem], onProgress: @Sendable (PeopleScanProgress) -> Void = { _ in }) async -> [PeopleScanResult] {
        guard embedder.isAvailable else { onProgress(PeopleScanProgress(completed: 0, total: items.count, isPaused: false)); return [] }
        var values: [PeopleScanResult] = []
        for (index, item) in items.enumerated() {
            if cancelled || Task.isCancelled { break }
            while Self.shouldPause {
                onProgress(PeopleScanProgress(completed: index, total: items.count, isPaused: true))
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    break
                }
                if cancelled || Task.isCancelled { break }
            }
            if cancelled || Task.isCancelled { break }
            let drafts: [FaceObservationDraft] = autoreleasepool {
                var drafts: [FaceObservationDraft] = []
                if let faces = try? FaceDetector.detect(in: item.image) {
                    for face in faces {
                        guard let crop = FaceAlignment.alignedCrop(item.image, points: face.points),
                              let vector = try? embedder.embedding(for: crop),
                              let cropData = Self.jpegData(crop) else { continue }
                        var embedding = Data(capacity: vector.count * MemoryLayout<Float>.size)
                        vector.withUnsafeBytes { embedding.append(contentsOf: $0) }
                        drafts.append(FaceObservationDraft(
                            rect: (Double(face.rect.minX), Double(face.rect.minY), Double(face.rect.width), Double(face.rect.height)),
                            quality: face.quality,
                            embedding: embedding,
                            cropData: cropData
                        ))
                    }
                }
                return drafts
            }
            values.append(PeopleScanResult(mediaID: item.id, faces: drafts))
            onProgress(PeopleScanProgress(completed: index + 1, total: items.count, isPaused: false))
            await Task.yield()
        }
        return values
    }

    private static var shouldPause: Bool {
        isOnBattery || ProcessInfo.processInfo.isLowPowerModeEnabled ||
        ProcessInfo.processInfo.thermalState == .serious ||
        ProcessInfo.processInfo.thermalState == .critical
    }

    private static var isOnBattery: Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        return source == kIOPSBatteryPowerValue
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.86])
    }

    private static func decodeEmbedding(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }
}

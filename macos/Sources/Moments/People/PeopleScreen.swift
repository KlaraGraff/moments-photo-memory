import AppKit
import Foundation
import ImageIO
import Observation
import SwiftData
import SwiftUI

extension Notification.Name {
    static let momentsPeopleScanRequested = Notification.Name("Moments.PeopleScanRequested")
}

struct PeopleScanDisplayProgress: Equatable {
    let completed: Int
    let total: Int
    let skippedUnavailable: Int
    let isPaused: Bool
}

struct PeopleFaceSnapshot: Sendable {
    let id: String
    let personID: String?
    let clusterID: String?
    let confirmed: Bool
    let assignmentSource: String
    let rejectedPersonIDs: String
    let embedding: Data
    var createdAt: Date = .distantPast
    var updatedAt: Date = .distantPast
}

struct PeoplePersonSnapshot: Sendable {
    let id: String
}

struct PeopleFaceAssignment: Sendable {
    let id: String
    var personID: String?
    var clusterID: String?
    var confirmed: Bool
    var assignmentSource: String
}

struct PeopleAssignmentResult: Sendable {
    let assignments: [PeopleFaceAssignment]
    let clusteringStopped: Bool
}

struct PeopleStoreAssignmentSnapshot: Sendable {
    let faces: [PeopleFaceSnapshot]
    let people: [PeoplePersonSnapshot]
}

private struct PeopleClusterSnapshot: Identifiable {
    let id: String
    let faces: [FaceObservation]
}

actor PeopleScanCoordinator {
    private var running: Task<Void, Never>?
    private var generation = 0

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        running?.cancel()
        _ = await running?.result
        generation += 1
        let token = generation
        let next = Task { await operation() }
        running = next
        await next.value
        if token == generation { running = nil }
    }

    func cancel() async {
        let token = generation
        running?.cancel()
        _ = await running?.result
        if token == generation { running = nil }
    }
}

@MainActor
@Observable
final class PeopleScanController {
    enum State: Equatable {
        case idle
        case scanning
        case unavailable
        case finished
        case failed
    }

    private(set) var state: State = .idle
    private(set) var progress = PeopleScanDisplayProgress(completed: 0, total: 0, skippedUnavailable: 0, isPaused: false)
    private let embedder: any FaceEmbedder
    private var container: ModelContainer?
    private var task: Task<Void, Never>?
    private var activePipeline: PeopleScanPipeline?
    private var activeScanID = UUID()
    private let coordinator = PeopleScanCoordinator()

    init(embedder: any FaceEmbedder = SFaceCoreMLEmbedder()) {
        self.embedder = embedder
        if !embedder.isAvailable { state = .unavailable }
    }

    var isAvailable: Bool { embedder.isAvailable }
    var isScanning: Bool { state == .scanning }

    func configure(container: ModelContainer) {
        self.container = container
    }

    func scanIfNeeded() {
        guard isAvailable, let container, task == nil else { return }
        let store = PeopleScanStore(modelContainer: container)
        Task { @MainActor [weak self] in
            let hasWork = (try? await Task.detached(priority: .utility) {
                try await store.hasWork()
            }.value) ?? false
            guard hasWork, let self, self.task == nil else { return }
            self.start()
        }
    }

    func start() {
        guard isAvailable, let container else {
            state = .unavailable
            return
        }
        let scanID = UUID()
        activeScanID = scanID
        state = .scanning
        progress = PeopleScanDisplayProgress(completed: 0, total: 0, skippedUnavailable: 0, isPaused: false)
        let embedder = self.embedder
        let coordinator = self.coordinator
        task = Task { @MainActor [weak self] in
            await coordinator.run { [weak self] in
                await self?.runScan(container: container, embedder: embedder, scanID: scanID)
            }
            guard let self, self.activeScanID == scanID else { return }
            self.task = nil
        }
    }

    private func runScan(container: ModelContainer, embedder: any FaceEmbedder, scanID: UUID) async {
        do {
            guard activeScanID == scanID else { return }
            let store = PeopleScanStore(modelContainer: container)
            let descriptors = try await Task.detached(priority: .utility) {
                try await store.pendingDescriptors()
            }.value
            let total = descriptors.count
            progress = PeopleScanDisplayProgress(completed: 0, total: total, skippedUnavailable: 0, isPaused: false)
            let pipeline = PeopleScanPipeline(embedder: embedder)
            activePipeline = pipeline
            var completed = 0
            var skippedUnavailable = 0
            for batch in stride(from: 0, to: descriptors.count, by: 16) {
                try Task.checkCancellation()
                let end = min(batch + 16, descriptors.count)
                var batchResults: [PeopleScanResult] = []
                var batchScannedIDs: [String] = []
                for (offset, descriptor) in descriptors[batch..<end].enumerated() {
                    try Task.checkCancellation()
                    if let image = await PeopleImageLoader.load(descriptor) {
                        try Task.checkCancellation()
                        let batchBase = completed + offset
                        let skippedBeforeImage = skippedUnavailable
                        let results = await pipeline.scanDetailed([PeopleScanItem(id: descriptor.id, image: image)]) { [weak self] scanProgress in
                            Task { @MainActor [weak self] in
                                guard let self, self.activeScanID == scanID, self.state == .scanning else { return }
                                self.progress = PeopleScanDisplayProgress(completed: batchBase + scanProgress.completed, total: total, skippedUnavailable: skippedBeforeImage, isPaused: scanProgress.isPaused)
                            }
                        }
                        batchResults.append(contentsOf: results)
                        batchScannedIDs.append(descriptor.id)
                    } else {
                        skippedUnavailable += 1
                        progress = PeopleScanDisplayProgress(completed: completed + offset + 1, total: total, skippedUnavailable: skippedUnavailable, isPaused: false)
                    }
                }
                try Task.checkCancellation()
                try await Task.detached(priority: .utility) {
                    try await store.save(results: batchResults, scannedIDs: batchScannedIDs, version: 1)
                }.value
                completed += end - batch
                progress = PeopleScanDisplayProgress(completed: completed, total: total, skippedUnavailable: skippedUnavailable, isPaused: false)
            }
            guard !Task.isCancelled else { throw CancellationError() }
            let snapshot = try await Task.detached(priority: .utility) {
                try await store.assignmentSnapshot()
            }.value
            let assignmentTask = Task.detached(priority: .utility) {
                guard !Task.isCancelled else { return PeopleAssignmentResult(assignments: [], clusteringStopped: true) }
                return PeopleScanController.makeAssignmentsResult(faces: snapshot.faces, people: snapshot.people)
            }
            let assignments = await withTaskCancellationHandler(operation: {
                await assignmentTask.value
            }, onCancel: {
                assignmentTask.cancel()
            })
            try Task.checkCancellation()
            guard !assignments.clusteringStopped else {
                guard activeScanID == scanID else { return }
                activePipeline = nil
                state = .idle
                return
            }
            try await Task.detached(priority: .utility) {
                try await store.apply(assignments: assignments.assignments, snapshots: snapshot.faces)
            }.value
            guard activeScanID == scanID else { return }
            activePipeline = nil
            state = .finished
        } catch is CancellationError {
            guard activeScanID == scanID else { return }
            activePipeline = nil
            state = .idle
        } catch {
            guard activeScanID == scanID else { return }
            activePipeline = nil
            state = .failed
        }
    }

    func cancel() {
        activeScanID = UUID()
        if state == .scanning { state = .idle }
        let pipeline = activePipeline
        activePipeline = nil
        task = nil
        if let pipeline {
            Task { await pipeline.cancel() }
        }
        let coordinator = self.coordinator
        Task { await coordinator.cancel() }
    }

    nonisolated static func makeAssignmentsResult(
        faces: [PeopleFaceSnapshot],
        people: [PeoplePersonSnapshot],
        shouldStop: (@Sendable () -> Bool)? = nil
    ) -> PeopleAssignmentResult {
        let confirmed = people.compactMap { person -> (id: String, centroid: [Float])? in
            let vectors = faces.filter { $0.personID == person.id && $0.confirmed && $0.assignmentSource == "user" }.compactMap { decode($0.embedding) }
            guard !vectors.isEmpty else { return nil }
            return (person.id, FaceClustering.centroid(of: vectors))
        }
        let originalAssignments = faces.map { PeopleFaceAssignment(id: $0.id, personID: $0.personID, clusterID: $0.clusterID, confirmed: $0.confirmed, assignmentSource: $0.assignmentSource) }
        var assignments = originalAssignments
        for index in assignments.indices where assignments[index].personID == nil {
            guard let vector = decode(faces[index].embedding) else { continue }
            let rejected = Set(faces[index].rejectedPersonIDs.split(separator: ",").map(String.init))
            if let personID = FaceClustering.assignIncrementally(vector, to: confirmed, rejecting: rejected) {
                assignments[index].personID = personID
                assignments[index].clusterID = nil
                assignments[index].confirmed = false
                assignments[index].assignmentSource = "auto"
            }
        }
        let pendingIndices = assignments.indices
            .filter { assignments[$0].personID == nil && assignments[$0].clusterID?.hasPrefix("pending-") == true && decode(faces[$0].embedding) != nil }
            .sorted { faces[$0].createdAt > faces[$1].createdAt }
        let existingClusters = Dictionary(grouping: assignments.indices.filter {
            assignments[$0].personID == nil && assignments[$0].clusterID?.hasPrefix("cluster-") == true
        }, by: { assignments[$0].clusterID! })
        // Average cosine distance to a cluster equals 1 - v·mean(members) for
        // unit vectors, so each cluster needs one mean vector, computed once.
        func unit(_ vector: [Float]) -> [Float] {
            let norm = sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 })
            return norm > 0 ? vector.map { $0 / norm } : vector
        }
        var clusterMeans: [(id: String, mean: [Float])] = []
        for (clusterID, members) in existingClusters {
            let vectors = members.compactMap { decode(faces[$0].embedding) }.map(unit)
            guard let dimension = vectors.first?.count else { continue }
            var sum = [Float](repeating: 0, count: dimension)
            for vector in vectors where vector.count == dimension {
                for d in 0..<dimension { sum[d] += vector[d] }
            }
            clusterMeans.append((clusterID, sum.map { $0 / Float(vectors.count) }))
        }
        let stop = shouldStop ?? { Task.isCancelled || FaceClustering.isPowerPaused }
        var clusteringIndices: [Int] = []
        for (position, index) in pendingIndices.enumerated() {
            if position % 64 == 0, stop() {
                return PeopleAssignmentResult(assignments: originalAssignments, clusteringStopped: true)
            }
            guard let vector = decode(faces[index].embedding).map(unit) else { continue }
            var best: (id: String, distance: Float)?
            for cluster in clusterMeans where cluster.mean.count == vector.count {
                let distance = 1 - zip(vector, cluster.mean).reduce(Float.zero) { $0 + $1.0 * $1.1 }
                if distance < FaceClustering.defaultThreshold, distance < (best?.distance ?? .infinity) {
                    best = (cluster.id, distance)
                }
            }
            if let best {
                assignments[index].clusterID = best.id
            } else {
                clusteringIndices.append(index)
            }
        }
        let limitedIndices = Array(clusteringIndices.prefix(3_000))
        let vectors = limitedIndices.compactMap { decode(faces[$0].embedding) }
        guard vectors.count == limitedIndices.count else { return PeopleAssignmentResult(assignments: assignments, clusteringStopped: false) }
        let result = FaceClustering.averageLinkResult(vectors, shouldStop: stop)
        if result.stopped {
            return PeopleAssignmentResult(assignments: originalAssignments, clusteringStopped: true)
        }
        for cluster in result.clusters {
            guard let first = cluster.first else { continue }
            let firstIndex = limitedIndices[first]
            let clusterID = "cluster-\(assignments[firstIndex].id)"
            for member in cluster { assignments[limitedIndices[member]].clusterID = clusterID }
        }
        return PeopleAssignmentResult(assignments: assignments, clusteringStopped: false)
    }

    nonisolated static func makeAssignments(faces: [PeopleFaceSnapshot], people: [PeoplePersonSnapshot]) -> [PeopleFaceAssignment] {
        makeAssignmentsResult(faces: faces, people: people).assignments
    }

    nonisolated private static func decode(_ data: Data) -> [Float]? {
        guard data.count % MemoryLayout<Float>.size == 0 else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

}

enum PeopleStoreActions {
    static func merge(sourceID: String, into targetID: String, people: [Person], observations: [FaceObservation], context: ModelContext) {
        guard sourceID != targetID else { return }
        for face in observations where face.personID == sourceID {
            face.personID = targetID
            var rejected = face.rejectedPersonIDSet
            if rejected.remove(sourceID) != nil { rejected.insert(targetID) }
            face.rejectedPersonIDs = rejected.sorted().joined(separator: ",")
            face.updatedAt = .now
        }
        for face in observations {
            var rejected = face.rejectedPersonIDSet
            guard rejected.remove(sourceID) != nil else { continue }
            rejected.insert(targetID)
            face.rejectedPersonIDs = rejected.sorted().joined(separator: ",")
            face.updatedAt = .now
        }
        for group in (try? context.fetch(FetchDescriptor<UserGroup>())) ?? [] {
            var rules = group.rules
            var changed = false
            for index in rules.rules.indices where rules.rules[index].field == .person && rules.rules[index].value == sourceID {
                rules.rules[index].value = targetID
                changed = true
            }
            if changed { group.rules = rules; group.updatedAt = .now }
        }
        let key = "moments.library.person"
        if UserDefaults.standard.string(forKey: key) == sourceID {
            UserDefaults.standard.set(targetID, forKey: key)
        }
        if let source = people.first(where: { $0.id == sourceID }) { context.delete(source) }
    }

    static func remove(face: FaceObservation) {
        if let personID = face.personID {
            face.reject(personID: personID)
        }
        face.personID = nil
        face.confirmed = false
        face.assignmentSource = "user"
        face.clusterID = nil
        face.updatedAt = .now
    }

    static func hide(person: Person) {
        person.hidden = true
        person.updatedAt = .now
    }
}

struct PeopleMediaDescriptor: Sendable {
    let id: String
    let bookmarkData: Data?
    let photosLocalIdentifier: String?

    init(id: String, bookmarkData: Data?, photosLocalIdentifier: String?) {
        self.id = id
        self.bookmarkData = bookmarkData
        self.photosLocalIdentifier = photosLocalIdentifier
    }

    init(_ item: MediaItem) {
        id = item.id
        bookmarkData = item.originalBookmarkData
        photosLocalIdentifier = item.photosLocalIdentifier
    }
}

/// Owns the write context away from the view's main-actor context. Each batch
/// is committed independently so cancellation can resume at the next item.
@ModelActor
actor PeopleScanStore {
    func hasWork() throws -> Bool {
        var recordsDescriptor = FetchDescriptor<FaceScanRecord>()
        recordsDescriptor.propertiesToFetch = [\.id]
        let completedIDs = Set(try modelContext.fetch(recordsDescriptor).map(\.id))
        var itemsDescriptor = FetchDescriptor<MediaItem>()
        itemsDescriptor.propertiesToFetch = [\.id, \.kindRaw]
        let needsFaceScan = try modelContext.fetch(itemsDescriptor).contains { $0.kind != .video && !completedIDs.contains($0.id) }
        var facesDescriptor = FetchDescriptor<FaceObservation>()
        facesDescriptor.propertiesToFetch = [\.personID, \.clusterID]
        let needsClustering = try modelContext.fetch(facesDescriptor).contains { $0.personID == nil && $0.clusterID?.hasPrefix("pending-") == true }
        return needsFaceScan || needsClustering
    }

    func pendingDescriptors() throws -> [PeopleMediaDescriptor] {
        var recordsDescriptor = FetchDescriptor<FaceScanRecord>()
        recordsDescriptor.propertiesToFetch = [\.id]
        let records = try modelContext.fetch(recordsDescriptor)
        let completedIDs = Set(records.map(\.id))
        var itemsDescriptor = FetchDescriptor<MediaItem>()
        itemsDescriptor.propertiesToFetch = [\.id, \.kindRaw, \.originalBookmarkData, \.photosLocalIdentifier]
        let items = try modelContext.fetch(itemsDescriptor)
        return items.compactMap { item in
            guard item.kind != .video, !completedIDs.contains(item.id) else { return nil }
            return PeopleMediaDescriptor(item)
        }
    }

    func save(results: [PeopleScanResult], scannedIDs: [String], version: Int) throws {
        var keys = Set<String>()
        for mediaID in Set(results.map(\.mediaID)) {
            let predicate = #Predicate<FaceObservation> { $0.mediaID == mediaID }
            var descriptor = FetchDescriptor<FaceObservation>(predicate: predicate)
            descriptor.propertiesToFetch = [\.mediaID, \.rectX, \.rectY, \.rectWidth, \.rectHeight]
            keys.formUnion(try modelContext.fetch(descriptor).map { Self.key(mediaID: $0.mediaID, rect: ($0.rectX, $0.rectY, $0.rectWidth, $0.rectHeight)) })
        }
        for result in results {
            for draft in result.faces {
                let key = Self.key(mediaID: result.mediaID, rect: draft.rect)
                guard keys.insert(key).inserted else { continue }
                let face = FaceObservation(
                    mediaID: result.mediaID,
                    rect: draft.rect,
                    embedding: draft.embedding,
                    cropData: draft.cropData,
                    quality: draft.quality,
                    assignmentSource: "auto"
                )
                face.clusterID = "pending-\(face.id)"
                modelContext.insert(face)
            }
        }
        for mediaID in scannedIDs {
            let predicate = #Predicate<FaceScanRecord> { $0.id == mediaID }
            if try modelContext.fetch(FetchDescriptor<FaceScanRecord>(predicate: predicate)).isEmpty {
                modelContext.insert(FaceScanRecord(id: mediaID, scannedAt: .now, version: version))
            }
        }
        try modelContext.save()
    }

    func assignmentSnapshot() throws -> PeopleStoreAssignmentSnapshot {
        var descriptor = FetchDescriptor<FaceObservation>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.propertiesToFetch = [\.id, \.mediaID, \.embedding, \.personID, \.clusterID, \.confirmed, \.rejectedPersonIDs, \.assignmentSource, \.createdAt, \.updatedAt]
        let faces = try modelContext.fetch(descriptor).map {
            PeopleFaceSnapshot(
                id: $0.id,
                personID: $0.personID,
                clusterID: $0.clusterID,
                confirmed: $0.confirmed,
                assignmentSource: $0.assignmentSource,
                rejectedPersonIDs: $0.rejectedPersonIDs,
                embedding: $0.embedding,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt
            )
        }
        var peopleDescriptor = FetchDescriptor<Person>()
        peopleDescriptor.propertiesToFetch = [\.id]
        let people = try modelContext.fetch(peopleDescriptor).map { PeoplePersonSnapshot(id: $0.id) }
        return PeopleStoreAssignmentSnapshot(faces: faces, people: people)
    }

    func apply(assignments: [PeopleFaceAssignment], snapshots: [PeopleFaceSnapshot]) throws {
        let snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        // One fetch for every face in this write-back instead of one per face.
        let faceIDs = assignments.map(\.id)
        var descriptor = FetchDescriptor<FaceObservation>(predicate: #Predicate { faceIDs.contains($0.id) })
        descriptor.propertiesToFetch = [\.id, \.personID, \.clusterID, \.confirmed, \.assignmentSource, \.updatedAt, \.rejectedPersonIDs]
        let facesByID = Dictionary(try modelContext.fetch(descriptor).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for assignment in assignments {
            guard let snapshot = snapshotsByID[assignment.id] else { continue }
            guard let face = facesByID[assignment.id],
                  face.updatedAt == snapshot.updatedAt,
                  face.personID == snapshot.personID,
                  face.confirmed == snapshot.confirmed,
                  face.assignmentSource == snapshot.assignmentSource,
                  face.rejectedPersonIDs == snapshot.rejectedPersonIDs else { continue }
            guard face.assignmentSource != "user", !face.confirmed else { continue }
            // Touch only faces whose assignment actually changed, so a scan does
            // not rewrite every face and force the People screen to recompute.
            guard face.personID != assignment.personID
                || face.clusterID != assignment.clusterID
                || face.confirmed != assignment.confirmed
                || face.assignmentSource != assignment.assignmentSource else { continue }
            face.personID = assignment.personID
            face.clusterID = assignment.clusterID
            face.confirmed = assignment.confirmed
            face.assignmentSource = assignment.assignmentSource
            face.updatedAt = .now
        }
        if modelContext.hasChanges { try modelContext.save() }
    }

    private static func key(mediaID: String, rect: (x: Double, y: Double, w: Double, h: Double)) -> String {
        let values = [rect.x, rect.y, rect.w, rect.h].map { String(format: "%.4f", $0) }.joined(separator: ",")
        return "\(mediaID)|\(values)"
    }
}

enum PeopleImageLoader {
    static func load(_ descriptor: PeopleMediaDescriptor) async -> CGImage? {
        let photoSource = PhotoKitAssetSource()
        if let localIdentifier = descriptor.photosLocalIdentifier,
           let image = await photoSource.thumbnailImage(forLocalIdentifier: localIdentifier, targetSize: CGSize(width: 2_000, height: 2_000), networkAccessAllowed: true) {
            return image
        }
        guard let bookmark = descriptor.bookmarkData,
              let resolved = try? OriginalMediaBookmark.resolve(bookmark) else { return nil }
        let scoped = resolved.url.startAccessingSecurityScopedResource()
        defer { if scoped { resolved.url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(resolved.url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_000,
            kCGImageSourceShouldCache: false
        ] as CFDictionary)
    }
}

struct PeopleScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PeopleScanController.self) private var scanner
    @Query(sort: \Person.name) private var people: [Person]
    @Query private var observations: [FaceObservation]
    @State private var clusterNames: [String: String] = [:]
    @State private var mergeSource: String?
    @State private var mergeTarget: String?
    @State private var cachedFacesByPerson: [String: [FaceObservation]] = [:]
    @State private var cachedUnnamedClusters: [PeopleClusterSnapshot] = []

    private var namedPeople: [Person] {
        people.filter { !$0.hidden && $0.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }

    private var unnamedClusters: [PeopleClusterSnapshot] { cachedUnnamedClusters }

    private var observationsKey: Int {
        var hasher = Hasher()
        for observation in observations {
            hasher.combine(observation.id)
            hasher.combine(observation.mediaID)
            hasher.combine(observation.personID)
            hasher.combine(observation.clusterID)
            hasher.combine(observation.confirmed)
            hasher.combine(observation.assignmentSource)
            hasher.combine(observation.updatedAt)
        }
        return hasher.finalize()
    }

    private func refreshFaceCaches() {
        cachedFacesByPerson = Dictionary(grouping: observations.compactMap { $0.personID == nil ? nil : $0 }, by: { $0.personID! })
        let grouped = Dictionary(grouping: observations.filter { $0.personID == nil && $0.clusterID != nil }, by: { $0.clusterID! })
        cachedUnnamedClusters = grouped.map { PeopleClusterSnapshot(id: $0.key, faces: $0.value.sorted { $0.createdAt < $1.createdAt }) }.sorted { $0.id < $1.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "People"))
                    .font(.system(size: 34, weight: .medium, design: .serif))
                    .foregroundStyle(Color(red: 0.227, green: 0.165, blue: 0.141))
                Spacer()
                Button {
                    scanner.start()
                } label: {
                    Label(String(localized: "Scan for people"), systemImage: "person.crop.circle.badge.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(!scanner.isAvailable || scanner.isScanning)
            }

            if !scanner.isAvailable {
                Text(String(localized: "People scanning is unavailable on this device."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if scanner.isScanning || scanner.progress.total > 0 && scanner.progress.completed < scanner.progress.total {
                HStack(spacing: 9) {
                    if scanner.progress.isPaused { ProgressView().controlSize(.small) } else { ProgressView(value: Double(scanner.progress.completed), total: Double(max(scanner.progress.total, 1))).frame(width: 130) }
                    Text(String(format: String(localized: "Finding faces progress"), scanner.progress.completed, scanner.progress.total))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if scanner.progress.skippedUnavailable > 0 {
                        Text(String(format: String(localized: "Skipped unavailable"), scanner.progress.skippedUnavailable))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if scanner.progress.isPaused { Text(String(localized: "Paused to save battery")).font(.caption).foregroundStyle(.secondary) }
                    Button(String(localized: "Cancel")) { scanner.cancel() }.buttonStyle(.borderless)
                }
            }

            if !scanner.isAvailable {
                Spacer(minLength: 0)
            } else if namedPeople.isEmpty && unnamedClusters.isEmpty {
                ContentUnavailableView(String(localized: "No people yet"), systemImage: "person.2", description: Text(String(localized: "Scan your library to find faces on this Mac.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if !namedPeople.isEmpty { namedSection }
                        if !unnamedClusters.isEmpty { unnamedSection }
                    }
                }
            }
        }
        .padding(34)
        .background(Color(red: 0.984, green: 0.945, blue: 0.918))
        .onAppear { scanner.scanIfNeeded() }
        .onChange(of: observationsKey, initial: true) { _, _ in refreshFaceCaches() }
        .onChange(of: people.map(\.id), initial: true) { _, ids in
            if !personFilterIsValid(ids: ids) { UserDefaults.standard.removeObject(forKey: "moments.library.person") }
        }
        .confirmationDialog(String(localized: "Merge two people"), isPresented: Binding(get: { mergeSource != nil }, set: { if !$0 { mergeSource = nil } })) {
            ForEach(namedPeople.filter { $0.id != mergeSource }, id: \.id) { person in
                Button(person.name ?? String(localized: "Unnamed person")) { mergeTarget = person.id; mergePeople() }
            }
            Button(String(localized: "Cancel"), role: .cancel) { mergeSource = nil }
        }
    }

    private var namedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Named people")).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(namedPeople, id: \.id) { person in namedCard(person) }
            }
        }
    }

    private func namedCard(_ person: Person) -> some View {
        let faces = cachedFacesByPerson[person.id] ?? []
        let photoCount = Set(faces.map(\.mediaID)).count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let first = faces.first { FaceCropView(data: first.cropData, size: 62) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name ?? String(localized: "Unnamed person")).font(.headline)
                    Text(String(format: String(localized: "People photo count"), photoCount)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button(String(localized: "Merge two people")) { mergeSource = person.id }
                    Button(String(localized: "Hide a person")) { PeopleStoreActions.hide(person: person); try? modelContext.save() }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton)
            }
            if !faces.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(faces, id: \.id) { face in
                            FaceCropView(data: face.cropData, size: 40)
                                .overlay(alignment: .topTrailing) {
                                    VStack(spacing: 2) {
                                        if !face.confirmed || face.assignmentSource != "user" {
                                            Button {
                                                face.confirmed = true
                                                face.assignmentSource = "user"
                                                face.updatedAt = .now
                                                try? modelContext.save()
                                            } label: {
                                                Image(systemName: "checkmark.circle.fill").font(.caption)
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(.white, .green)
                                        }
                                        Button { remove(face) } label: { Image(systemName: "minus.circle.fill").font(.caption) }.buttonStyle(.plain).foregroundStyle(.white, .red)
                                    }
                                }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var unnamedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Is this the same person?")).font(.headline)
            ForEach(unnamedClusters) { cluster in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField(String(localized: "Name this person"), text: Binding(get: { clusterNames[cluster.id] ?? "" }, set: { clusterNames[cluster.id] = $0 }))
                            .textFieldStyle(.roundedBorder)
                        Button(String(localized: "Save")) { name(cluster) }.buttonStyle(.borderedProminent)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(cluster.faces, id: \.id) { face in
                                VStack(spacing: 4) {
                                    FaceCropView(data: face.cropData, size: 72)
                                    HStack(spacing: 6) {
                                        Button { face.confirmed = true; face.assignmentSource = "user"; face.updatedAt = .now; try? modelContext.save() } label: { Image(systemName: "checkmark") }.buttonStyle(.borderless).foregroundStyle(.green)
                                        Button { remove(face) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func name(_ cluster: PeopleClusterSnapshot) {
        let value = (clusterNames[cluster.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let person = Person(name: value)
        modelContext.insert(person)
        for face in cluster.faces {
            face.personID = person.id
            face.clusterID = nil
            face.confirmed = true
            face.assignmentSource = "user"
            face.updatedAt = .now
        }
        try? modelContext.save()
        clusterNames[cluster.id] = nil
    }

    private func remove(_ face: FaceObservation) {
        let personID = face.personID
        PeopleStoreActions.remove(face: face)
        if let personID,
           !observations.contains(where: { $0 !== face && $0.personID == personID }),
           let person = people.first(where: { $0.id == personID }) {
            PeopleStoreActions.hide(person: person)
        }
        try? modelContext.save()
    }

    private func mergePeople() {
        guard let sourceID = mergeSource, let targetID = mergeTarget, sourceID != targetID else { return }
        PeopleStoreActions.merge(sourceID: sourceID, into: targetID, people: people, observations: observations, context: modelContext)
        try? modelContext.save()
        mergeSource = nil
        mergeTarget = nil
    }

    private func personFilterIsValid(ids: [String]) -> Bool {
        let value = UserDefaults.standard.string(forKey: "moments.library.person") ?? ""
        return value.isEmpty || ids.contains(value)
    }
}

private struct FaceCropView: View {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()
    let data: Data
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.18)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1))
        .task(id: data) {
            let key = "\(data.hashValue):\(data.count)" as NSString
            if let cached = Self.cache.object(forKey: key) {
                image = cached
                return
            }
            let decodeTask = Task.detached(priority: .utility) { () -> Data? in
                guard !Task.isCancelled else { return nil }
                return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
            }
            let decodedData = await withTaskCancellationHandler(operation: {
                await decodeTask.value
            }, onCancel: {
                decodeTask.cancel()
            })
            guard let decoded = decodedData.flatMap(NSImage.init(data:)) else { return }
            Self.cache.setObject(decoded, forKey: key)
            image = decoded
        }
    }
}

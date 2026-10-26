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
    /// The photo the face was found in. Empty means unknown, which turns off
    /// the one-face-per-photo rule for that face.
    var mediaID: String = ""
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

/// A face's state before ✓ or ✗, so the change can be taken back.
private struct FaceUndoSnapshot {
    let faceID: String
    let personID: String?
    let clusterID: String?
    let confirmed: Bool
    let assignmentSource: String
    let rejectedPersonIDs: String
    /// Set when removing the last face hid this person.
    var hiddenPersonID: String?

    init(_ face: FaceObservation) {
        faceID = face.id
        personID = face.personID
        clusterID = face.clusterID
        confirmed = face.confirmed
        assignmentSource = face.assignmentSource
        rejectedPersonIDs = face.rejectedPersonIDs
    }
}

private struct PendingRename: Identifiable {
    let personID: String
    let name: String
    let targetID: String
    let targetName: String
    var id: String { personID }
}

/// A cluster name that matches an existing person, waiting for the user to
/// choose between merging and keeping the two apart.
private struct PendingNameMerge: Identifiable {
    let id: String
    let name: String
    let targetID: String
    let targetName: String
}

private enum PeopleFacePicker {
    /// The face that represents a group: a user-confirmed face if there is one,
    /// then the sharpest. Every People surface shows this face's aligned crop,
    /// never the whole source photo, so a multi-person photo shows one face.
    static func cover(_ faces: [FaceObservation]) -> FaceObservation? {
        faces.max { lhs, rhs in
            let left = lhs.confirmed && lhs.assignmentSource == "user"
            let right = rhs.confirmed && rhs.assignmentSource == "user"
            if left != right { return !left }
            return lhs.quality < rhs.quality
        }
    }
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
        guard vectors.count == limitedIndices.count else {
            separateSamePhotoFaces(&assignments, faces: faces)
            return PeopleAssignmentResult(assignments: assignments, clusteringStopped: false)
        }
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
        separateSamePhotoFaces(&assignments, faces: faces)
        return PeopleAssignmentResult(assignments: assignments, clusteringStopped: false)
    }

    /// One person appears at most once in a photo, so two faces from the same
    /// photo never share a suggested person or an unnamed group. In each group
    /// the face closest to the group's mean stays; the others move to groups of
    /// their own. Faces the user confirmed are never moved.
    nonisolated static func separateSamePhotoFaces(_ assignments: inout [PeopleFaceAssignment], faces: [PeopleFaceSnapshot]) {
        // The same faces that write-back never touches: anything confirmed or
        // set by the user.
        func isUserConfirmed(_ index: Int) -> Bool {
            assignments[index].confirmed || assignments[index].assignmentSource == "user"
        }
        func groupKey(_ index: Int) -> String? {
            guard !faces[index].mediaID.isEmpty else { return nil }
            if let personID = assignments[index].personID { return "person:\(personID)" }
            if let clusterID = assignments[index].clusterID, !clusterID.hasPrefix("pending-") { return "cluster:\(clusterID)" }
            return nil
        }
        func unit(_ vector: [Float]) -> [Float] {
            let norm = sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 })
            return norm > 0 ? vector.map { $0 / norm } : vector
        }
        var groups: [String: [Int]] = [:]
        for index in assignments.indices {
            if let key = groupKey(index) { groups[key, default: []].append(index) }
        }
        for members in groups.values {
            let byPhoto = Dictionary(grouping: members, by: { faces[$0].mediaID })
            guard byPhoto.values.contains(where: { $0.count > 1 }) else { continue }
            let vectors = Dictionary(uniqueKeysWithValues: members.compactMap { index in decode(faces[index].embedding).map { (index, unit($0)) } })
            // Confirmed faces define the person when there are any.
            let anchors = members.filter(isUserConfirmed).isEmpty ? members : members.filter(isUserConfirmed)
            let anchorVectors = anchors.compactMap { vectors[$0] }
            var mean: [Float] = []
            if let dimension = anchorVectors.first?.count {
                mean = [Float](repeating: 0, count: dimension)
                for vector in anchorVectors where vector.count == dimension {
                    for d in 0..<dimension { mean[d] += vector[d] }
                }
            }
            func similarity(_ index: Int) -> Float {
                guard let vector = vectors[index], vector.count == mean.count else { return -.infinity }
                return zip(vector, mean).reduce(Float.zero) { $0 + $1.0 * $1.1 }
            }
            for (_, photoFaces) in byPhoto where photoFaces.count > 1 {
                let confirmed = photoFaces.filter(isUserConfirmed)
                let keep: Set<Int> = confirmed.isEmpty
                    ? [photoFaces.max { (similarity($0), faces[$1].id) < (similarity($1), faces[$0].id) }!]
                    : Set(confirmed)
                for index in photoFaces where !keep.contains(index) {
                    assignments[index].personID = nil
                    assignments[index].clusterID = "cluster-solo-\(assignments[index].id)"
                    assignments[index].confirmed = false
                    assignments[index].assignmentSource = "auto"
                }
            }
        }
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
    /// Local person IDs the user chose to keep apart from a same-named person.
    /// Only opaque IDs are stored here, never names, faces or embeddings.
    static let keepSeparateKey = "moments.people.keepSeparate"

    /// Two person names are the same when they match after trimming, ignoring
    /// case and full-width/half-width forms (so "Ａｌｉｃｅ" equals "alice").
    static func namesMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = (lhs ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let right = (rhs ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left.compare(right, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
    }

    static func keepSeparateIDs(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: keepSeparateKey) ?? [])
    }

    static func setKeepSeparate(_ personID: String, _ isSeparate: Bool, defaults: UserDefaults = .standard) {
        var ids = keepSeparateIDs(defaults)
        let changed = isSeparate ? ids.insert(personID).inserted : ids.remove(personID) != nil
        guard changed else { return }
        if ids.isEmpty { defaults.removeObject(forKey: keepSeparateKey) } else { defaults.set(ids.sorted(), forKey: keepSeparateKey) }
    }

    private static func isOlder(_ lhs: Person, _ rhs: Person) -> Bool {
        (lhs.createdAt, lhs.id) < (rhs.createdAt, rhs.id)
    }

    /// The visible person a new name should merge into: the oldest non-hidden
    /// person with an equal name that the user has not kept separate.
    static func mergeCandidate(forName name: String, people: [Person], excluding excludedID: String? = nil, defaults: UserDefaults = .standard) -> Person? {
        let separate = keepSeparateIDs(defaults)
        return people
            .filter { !$0.hidden && $0.id != excludedID && !separate.contains($0.id) && namesMatch($0.name, name) }
            .min(by: isOlder)
    }

    /// Names a group of faces as a user-confirmed person. With `target`, the
    /// faces join that existing person through ``merge``; otherwise a new
    /// person is created, optionally marked to stay apart from same-named people.
    @discardableResult
    static func name(
        faces: [FaceObservation],
        as name: String,
        mergingInto target: Person?,
        keepSeparate: Bool,
        people: [Person],
        observations: [FaceObservation],
        context: ModelContext,
        defaults: UserDefaults = .standard
    ) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !faces.isEmpty else { return nil }
        let person = Person(name: value)
        context.insert(person)
        for face in faces {
            face.personID = person.id
            face.clusterID = nil
            face.confirmed = true
            face.assignmentSource = "user"
            face.updatedAt = .now
        }
        guard let target, !target.hidden, target.id != person.id else {
            if keepSeparate { setKeepSeparate(person.id, true, defaults: defaults) }
            return person.id
        }
        var seen = Set<ObjectIdentifier>()
        let allFaces = (faces + observations).filter { seen.insert(ObjectIdentifier($0)).inserted }
        merge(sourceID: person.id, into: target.id, people: people + [person], observations: allFaces, context: context, defaults: defaults)
        // Naming these faces is an explicit choice, so it overrides an older
        // "not this person" rejection of the same person.
        for face in faces {
            var rejected = face.rejectedPersonIDSet
            guard rejected.remove(target.id) != nil else { continue }
            face.rejectedPersonIDs = rejected.sorted().joined(separator: ",")
        }
        return target.id
    }

    /// Merges visible people whose names are equal into the oldest of them,
    /// skipping anyone the user kept separate. Returns how many were merged.
    @discardableResult
    static func mergeDuplicateNames(people: [Person], observations: [FaceObservation], context: ModelContext, defaults: UserDefaults = .standard) -> Int {
        let separate = keepSeparateIDs(defaults)
        let candidates = people
            .filter { !$0.hidden && !separate.contains($0.id) && $0.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
            .sorted(by: isOlder)
        var keepers: [Person] = []
        var merged = 0
        for person in candidates {
            if let keeper = keepers.first(where: { namesMatch($0.name, person.name) }) {
                merge(sourceID: person.id, into: keeper.id, people: people, observations: observations, context: context, defaults: defaults)
                merged += 1
            } else {
                keepers.append(person)
            }
        }
        return merged
    }

    static func merge(sourceID: String, into targetID: String, people: [Person], observations: [FaceObservation], context: ModelContext, defaults: UserDefaults = .standard) {
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
        if defaults.string(forKey: key) == sourceID {
            defaults.set(targetID, forKey: key)
        }
        setKeepSeparate(sourceID, false, defaults: defaults)
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
        facesDescriptor.propertiesToFetch = [\.mediaID, \.personID, \.clusterID, \.confirmed, \.assignmentSource]
        let faces = try modelContext.fetch(facesDescriptor)
        let needsClustering = faces.contains { $0.personID == nil && $0.clusterID?.hasPrefix("pending-") == true }
        return needsFaceScan || needsClustering || Self.hasSamePhotoSuggestions(faces)
    }

    /// True when an unnamed group or a machine-suggested person holds two faces
    /// from one photo, as groups made before the one-face-per-photo rule can.
    static func hasSamePhotoSuggestions(_ faces: [FaceObservation]) -> Bool {
        var seen = Set<String>()
        // Matches separateSamePhotoFaces: faces without a photo and faces the
        // write-back never moves can't make work.
        for face in faces where !face.mediaID.isEmpty && !face.confirmed && face.assignmentSource != "user" {
            let group: String
            if let personID = face.personID { group = "person:\(personID)" }
            else if let clusterID = face.clusterID, !clusterID.hasPrefix("pending-") { group = "cluster:\(clusterID)" }
            else { continue }
            if !seen.insert("\(group)|\(face.mediaID)").inserted { return true }
        }
        return false
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
        // A fresh context per call: a long-lived context would serve faces it
        // inserted earlier from its cache, hiding edits made on the main context.
        let modelContext = ModelContext(modelContainer)
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
        // A fresh context per call: a long-lived context would serve faces it
        // inserted earlier from its cache, hiding edits made on the main context.
        let modelContext = ModelContext(modelContainer)
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
                updatedAt: $0.updatedAt,
                mediaID: $0.mediaID
            )
        }
        var peopleDescriptor = FetchDescriptor<Person>()
        peopleDescriptor.propertiesToFetch = [\.id]
        let people = try modelContext.fetch(peopleDescriptor).map { PeoplePersonSnapshot(id: $0.id) }
        return PeopleStoreAssignmentSnapshot(faces: faces, people: people)
    }

    func apply(assignments: [PeopleFaceAssignment], snapshots: [PeopleFaceSnapshot]) throws {
        // A fresh context per call: a long-lived context would serve faces it
        // inserted earlier from its cache, hiding edits made on the main context.
        let modelContext = ModelContext(modelContainer)
        let snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        // One fetch for every face in this write-back instead of one per face.
        let faceIDs = assignments.map(\.id)
        var descriptor = FetchDescriptor<FaceObservation>(predicate: #Predicate { faceIDs.contains($0.id) })
        descriptor.propertiesToFetch = [\.id, \.personID, \.clusterID, \.confirmed, \.assignmentSource, \.updatedAt, \.rejectedPersonIDs]
        let facesByID = Dictionary(try modelContext.fetch(descriptor).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A person merged or removed while the scan ran must not get faces back;
        // such a face stays as it was and the next scan places it again.
        var peopleDescriptor = FetchDescriptor<Person>()
        peopleDescriptor.propertiesToFetch = [\.id]
        let livePersonIDs = Set(try modelContext.fetch(peopleDescriptor).map(\.id))
        for assignment in assignments {
            if let personID = assignment.personID, !livePersonIDs.contains(personID) { continue }
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
    @State private var pendingNameMerge: PendingNameMerge?
    @State private var cachedFacesByPerson: [String: [FaceObservation]] = [:]
    @State private var cachedUnnamedClusters: [PeopleClusterSnapshot] = []
    @State private var lastFaceChange: FaceUndoSnapshot?
    @State private var renamingPersonID: String?
    @State private var renameText = ""
    @State private var pendingRename: PendingRename?
    @Environment(SelectionModel.self) private var selection
    @AppStorage("moments.library.person") private var libraryPersonFilterID = ""

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
        VStack(alignment: .leading, spacing: 0) {
            PaperScreenHeader(String(localized: "People")) {
                if !namedPeople.isEmpty { Text("\(namedPeople.count)") }
            } trailing: {
                if lastFaceChange != nil {
                    // No ⌘Z: it would take text undo from the name fields.
                    Button(String(localized: "Undo")) { undoFaceChange() }
                        .accessibilityIdentifier("people.undo")
                }
                Button {
                    scanner.start()
                } label: {
                    Label(String(localized: "Scan for people"), systemImage: "person.crop.circle.badge.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(!scanner.isAvailable || scanner.isScanning)
            }

            VStack(alignment: .leading, spacing: 20) {
                if !scanner.isAvailable {
                    Text(String(localized: "People scanning is unavailable on this device."))
                        .font(.callout)
                        .foregroundStyle(Paper.muted)
                } else if scanner.isScanning || scanner.progress.total > 0 && scanner.progress.completed < scanner.progress.total {
                    HStack(spacing: 9) {
                        if scanner.progress.isPaused { ProgressView().controlSize(.small) } else { ProgressView(value: Double(scanner.progress.completed), total: Double(max(scanner.progress.total, 1))).frame(width: 130) }
                        Text(String(format: String(localized: "Finding faces progress"), scanner.progress.completed, scanner.progress.total))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Paper.muted)
                        if scanner.progress.skippedUnavailable > 0 {
                            Text(String(format: String(localized: "Skipped unavailable"), scanner.progress.skippedUnavailable))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Paper.muted)
                        }
                        if scanner.progress.isPaused { Text(String(localized: "Paused to save battery")).font(.caption).foregroundStyle(Paper.muted) }
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
            .padding(.horizontal, PaperMetrics.screenInset)
            .padding(.bottom, PaperMetrics.screenInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Paper.canvas)
        .onAppear {
            mergeSameNamedPeople()
            scanner.scanIfNeeded()
        }
        .onChange(of: observationsKey, initial: true) { _, _ in refreshFaceCaches() }
        .onChange(of: people.map(\.id), initial: true) { _, ids in
            if !personFilterIsValid(ids: ids) { UserDefaults.standard.removeObject(forKey: "moments.library.person") }
        }
        .sheet(isPresented: Binding(get: { mergeSource != nil }, set: { if !$0 { mergeSource = nil } })) {
            mergeSheet
        }
        .alert(
            String(format: String(localized: "Merge with existing %@?"), pendingNameMerge?.targetName ?? ""),
            isPresented: Binding(get: { pendingNameMerge != nil }, set: { if !$0 { pendingNameMerge = nil } }),
            presenting: pendingNameMerge
        ) { pending in
            Button(String(localized: "Merge")) { commitName(pending, merge: true) }
                .keyboardShortcut(.defaultAction)
            Button(String(localized: "Keep separate")) { commitName(pending, merge: false) }
            Button(String(localized: "Cancel"), role: .cancel) { pendingNameMerge = nil }
        }
        .alert(
            String(localized: "Rename"),
            isPresented: Binding(get: { renamingPersonID != nil }, set: { if !$0 { renamingPersonID = nil } })
        ) {
            TextField(String(localized: "Name this person"), text: $renameText)
            Button(String(localized: "Save")) { rename() }
                .keyboardShortcut(.defaultAction)
            Button(String(localized: "Cancel"), role: .cancel) { renamingPersonID = nil }
        }
        .alert(
            String(format: String(localized: "Merge with existing %@?"), pendingRename?.targetName ?? ""),
            isPresented: Binding(get: { pendingRename != nil }, set: { if !$0 { pendingRename = nil } }),
            presenting: pendingRename
        ) { pending in
            Button(String(localized: "Merge")) { commitRename(pending, merge: true) }
                .keyboardShortcut(.defaultAction)
            Button(String(localized: "Keep separate")) { commitRename(pending, merge: false) }
            Button(String(localized: "Cancel"), role: .cancel) { pendingRename = nil }
        }
    }

    private var mergeSheet: some View {
        let source = people.first { $0.id == mergeSource }
        return PaperSheet(String(localized: "Merge two people")) {
            VStack(alignment: .leading, spacing: 14) {
                if let source {
                    HStack(spacing: 10) {
                        if let face = PeopleFacePicker.cover(cachedFacesByPerson[source.id] ?? []) {
                            FaceCropView(data: face.cropData, cacheKey: face.id, size: 56)
                        }
                        Text(source.name ?? String(localized: "Unnamed person")).font(.title3)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(namedPeople.filter { $0.id != mergeSource }, id: \.id) { person in
                            Button {
                                mergeTarget = person.id
                                mergePeople()
                            } label: {
                                HStack(spacing: 10) {
                                    if let face = PeopleFacePicker.cover(cachedFacesByPerson[person.id] ?? []) {
                                        FaceCropView(data: face.cropData, cacheKey: face.id, size: 44)
                                    }
                                    Text(person.name ?? String(localized: "Unnamed person"))
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .paperWell(padding: 4)
                .frame(maxHeight: 320)
            }
        } footer: {
            Button(String(localized: "Cancel"), role: .cancel) { mergeSource = nil }
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 360)
    }

    private var namedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Named people")).font(.system(.title3, design: .serif).weight(.medium)).foregroundStyle(Paper.ink)
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
                // The face and name open this person's photos in the Library.
                Button { showPhotos(of: person) } label: {
                    HStack {
                        if let cover = PeopleFacePicker.cover(faces) { FaceCropView(data: cover.cropData, cacheKey: cover.id, size: 72) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name ?? String(localized: "Unnamed person")).font(.headline).foregroundStyle(Paper.ink)
                            Text(String(format: String(localized: "People photo count"), photoCount)).font(.caption.monospacedDigit()).foregroundStyle(Paper.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Show this person's photos"))
                .accessibilityIdentifier("people.person.\(person.id)")
                Menu {
                    Button(String(localized: "Show this person's photos")) { showPhotos(of: person) }
                    Button(String(localized: "Rename…")) {
                        renameText = person.name ?? ""
                        renamingPersonID = person.id
                    }
                    Divider()
                    Button(String(localized: "Merge two people")) { mergeSource = person.id }
                    Button(String(localized: "Hide a person")) { PeopleStoreActions.hide(person: person); try? modelContext.save() }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton)
            }
            if !faces.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(faces, id: \.id) { face in
                            FaceCropView(data: face.cropData, cacheKey: face.id, size: 56)
                                .overlay(alignment: .topTrailing) {
                                    VStack(spacing: 2) {
                                        if !face.confirmed || face.assignmentSource != "user" {
                                            Button { confirm(face) } label: {
                                                Image(systemName: "checkmark.circle.fill").font(.body)
                                                    .frame(width: 22, height: 22)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(.white, .green)
                                            .help(String(localized: "This is them"))
                                        }
                                        Button { remove(face) } label: {
                                            Image(systemName: "minus.circle.fill").font(.body)
                                                .frame(width: 22, height: 22)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.white, .red)
                                        .help(String(localized: "Not this person"))
                                    }
                                }
                                .frame(width: 56, height: 56)
                        }
                    }
                }
            }
        }
        .paperCard(cornerRadius: 12, padding: 12)
    }

    private var unnamedSection: some View {
        // Lazy so a card's zoomed photo loads only when the card scrolls in.
        LazyVStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Is this the same person?")).font(.system(.title3, design: .serif).weight(.medium)).foregroundStyle(Paper.ink)
            ForEach(unnamedClusters) { cluster in
                HStack(alignment: .top, spacing: 14) {
                    if let cover = PeopleFacePicker.cover(cluster.faces) {
                        FaceInPhotoView(
                            faceID: cover.id,
                            faceRect: CGRect(x: cover.rectX, y: cover.rectY, width: cover.rectWidth, height: cover.rectHeight),
                            mediaID: cover.mediaID,
                            fallbackCrop: cover.cropData,
                            size: 150
                        )
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            TextField(String(localized: "Name this person"), text: Binding(get: { clusterNames[cluster.id] ?? "" }, set: { clusterNames[cluster.id] = $0 }))
                                .textFieldStyle(.paper)
                                .onSubmit { name(cluster) }
                            Button(String(localized: "Save")) { name(cluster) }.buttonStyle(.borderedProminent)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 10) {
                                ForEach(cluster.faces, id: \.id) { face in
                                    VStack(spacing: 4) {
                                        FaceCropView(data: face.cropData, cacheKey: face.id, size: 64)
                                        HStack(spacing: 4) {
                                            Button { confirm(face) } label: {
                                                Image(systemName: "checkmark").font(.body.weight(.semibold))
                                                    .frame(width: 28, height: 24)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.borderless)
                                            .foregroundStyle(.green)
                                            .help(String(localized: "Same person"))
                                            Button { remove(face) } label: {
                                                Image(systemName: "xmark").font(.body.weight(.semibold))
                                                    .frame(width: 28, height: 24)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.borderless)
                                            .foregroundStyle(.red)
                                            .help(String(localized: "Not the same person"))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .paperCard(cornerRadius: 12, padding: 14)
            }
        }
    }

    private func name(_ cluster: PeopleClusterSnapshot) {
        let value = (clusterNames[cluster.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let target = PeopleStoreActions.mergeCandidate(forName: value, people: people) {
            pendingNameMerge = PendingNameMerge(id: cluster.id, name: value, targetID: target.id, targetName: target.name ?? value)
            return
        }
        commitName(clusterID: cluster.id, name: value, target: nil, keepSeparate: false)
    }

    private func commitName(_ pending: PendingNameMerge, merge: Bool) {
        let target = merge ? people.first { $0.id == pending.targetID && !$0.hidden } : nil
        commitName(clusterID: pending.id, name: pending.name, target: target, keepSeparate: !merge)
        pendingNameMerge = nil
    }

    private func commitName(clusterID: String, name: String, target: Person?, keepSeparate: Bool) {
        guard let cluster = cachedUnnamedClusters.first(where: { $0.id == clusterID }) else { return }
        PeopleStoreActions.name(
            faces: cluster.faces,
            as: name,
            mergingInto: target,
            keepSeparate: keepSeparate,
            people: people,
            observations: observations,
            context: modelContext
        )
        try? modelContext.save()
        clusterNames[clusterID] = nil
    }

    /// Folds same-named people left over from earlier versions or other paths
    /// into the oldest one each time the People screen appears.
    private func mergeSameNamedPeople() {
        guard PeopleStoreActions.mergeDuplicateNames(people: people, observations: observations, context: modelContext) > 0 else { return }
        try? modelContext.save()
    }

    private func confirm(_ face: FaceObservation) {
        lastFaceChange = FaceUndoSnapshot(face)
        face.confirmed = true
        face.assignmentSource = "user"
        face.updatedAt = .now
        try? modelContext.save()
    }

    private func remove(_ face: FaceObservation) {
        var snapshot = FaceUndoSnapshot(face)
        let personID = face.personID
        PeopleStoreActions.remove(face: face)
        if let personID,
           !observations.contains(where: { $0 !== face && $0.personID == personID }),
           let person = people.first(where: { $0.id == personID }) {
            PeopleStoreActions.hide(person: person)
            snapshot.hiddenPersonID = person.id
        }
        lastFaceChange = snapshot
        try? modelContext.save()
    }

    private func undoFaceChange() {
        guard let snapshot = lastFaceChange else { return }
        lastFaceChange = nil
        guard let face = observations.first(where: { $0.id == snapshot.faceID }) else { return }
        // A merge since then may have deleted that person; leave the face
        // where it is rather than pointing it at nobody.
        if let personID = snapshot.personID, !people.contains(where: { $0.id == personID }) { return }
        face.personID = snapshot.personID
        face.clusterID = snapshot.clusterID
        face.confirmed = snapshot.confirmed
        face.assignmentSource = snapshot.assignmentSource
        face.rejectedPersonIDs = snapshot.rejectedPersonIDs
        face.updatedAt = .now
        if let hiddenID = snapshot.hiddenPersonID, let person = people.first(where: { $0.id == hiddenID }) {
            person.hidden = false
            person.updatedAt = .now
        }
        try? modelContext.save()
    }

    /// Opens the Library filtered to this person, like a person in Photos.
    private func showPhotos(of person: Person) {
        libraryPersonFilterID = person.id
        selection.clear()
        selection.requestedDestination = .library
        selection.shouldRevealSelectionInLibrary = false
    }

    private func rename() {
        guard let personID = renamingPersonID else { return }
        renamingPersonID = nil
        let value = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let person = people.first(where: { $0.id == personID }) else { return }
        // Same name as someone else: offer the merge, as naming a group does.
        if let target = PeopleStoreActions.mergeCandidate(forName: value, people: people, excluding: personID) {
            let pending = PendingRename(personID: personID, name: value, targetID: target.id, targetName: target.name ?? value)
            // Present after the rename alert has gone, or AppKit drops it.
            DispatchQueue.main.async { pendingRename = pending }
            return
        }
        person.name = value
        person.updatedAt = .now
        try? modelContext.save()
    }

    private func commitRename(_ pending: PendingRename, merge: Bool) {
        pendingRename = nil
        if merge {
            PeopleStoreActions.merge(sourceID: pending.personID, into: pending.targetID, people: people, observations: observations, context: modelContext)
        } else if let person = people.first(where: { $0.id == pending.personID }) {
            person.name = pending.name
            person.updatedAt = .now
            // Otherwise the same-name sweep would fold them together later.
            PeopleStoreActions.setKeepSeparate(person.id, true)
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
    /// The face's own ID. `Data` hashes only its first 80 bytes, which are the
    /// same JPEG header for every crop, so a data-derived key could show one
    /// person's face in another person's slot.
    let cacheKey: String
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
        .task(id: cacheKey) {
            let key = cacheKey as NSString
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

enum PeopleFaceZoom {
    /// How much of the photo around the face to keep, as a multiple of the
    /// face's longer side: enough to recognise the person, little enough that
    /// a neighbour in a group photo stays at the edge.
    static let context: CGFloat = 1.8

    /// The square pixel rect that zooms a photo to one face. `faceRect` is
    /// Vision's normalized, y-up bounding box; the result is in y-down pixels,
    /// shifted to stay inside the image and shrunk only if the image is smaller.
    static func cropRect(faceRect: CGRect, imageSize: CGSize) -> CGRect {
        let face = CGRect(
            x: faceRect.minX * imageSize.width,
            y: (1 - faceRect.maxY) * imageSize.height,
            width: faceRect.width * imageSize.width,
            height: faceRect.height * imageSize.height
        )
        let side = min(max(face.width, face.height) * context, imageSize.width, imageSize.height)
        let x = min(max(face.midX - side / 2, 0), imageSize.width - side)
        let y = min(max(face.midY - side / 2, 0), imageSize.height - side)
        return CGRect(x: x, y: y, width: side, height: side).integral
    }
}

/// The photo a face was found in, zoomed to that one face, the way Photos
/// asks "who is this". Falls back to the aligned face crop when the original
/// photo can't be read.
private struct FaceInPhotoView: View {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()
    let faceID: String
    let faceRect: CGRect
    @Environment(\.modelContext) private var modelContext
    let mediaID: String
    let fallbackCrop: Data
    let size: CGFloat
    @State private var image: NSImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if loadFailed {
                FaceCropView(data: fallbackCrop, cacheKey: faceID, size: size)
            } else {
                Color.gray.opacity(0.18)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.7), lineWidth: 1))
        .accessibilityHidden(true)
        .task(id: faceID) {
            // The cover face can change under the same card; never leave the
            // previous face showing.
            image = nil
            loadFailed = false
            let key = faceID as NSString
            if let cached = Self.cache.object(forKey: key) {
                image = cached
                return
            }
            let wantedID = mediaID
            var fetch = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.id == wantedID })
            fetch.fetchLimit = 1
            let descriptor = (try? modelContext.fetch(fetch))?.first.map(PeopleMediaDescriptor.init)
            guard let descriptor, let photo = await PeopleImageLoader.load(descriptor) else {
                loadFailed = true
                return
            }
            let rect = PeopleFaceZoom.cropRect(faceRect: faceRect, imageSize: CGSize(width: photo.width, height: photo.height))
            guard !Task.isCancelled, let cropped = photo.cropping(to: rect) else {
                loadFailed = true
                return
            }
            let zoomed = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
            Self.cache.setObject(zoomed, forKey: key)
            image = zoomed
        }
    }
}

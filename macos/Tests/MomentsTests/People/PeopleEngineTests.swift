import CoreGraphics
import Foundation
import SwiftData
import XCTest
@testable import Moments

private actor TestEventLog {
    private var events: [String] = []
    func append(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}

private final class TestCounter: @unchecked Sendable {
    var value = 0
}

@MainActor
final class PeopleEngineTests: XCTestCase {
    private func embedding(_ values: [Float]) -> Data {
        var data = Data()
        values.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    func testAlignmentMapsFiveSyntheticPoints() {
        let source = [
            CGPoint(x: 110, y: 80), CGPoint(x: 170, y: 82), CGPoint(x: 140, y: 120),
            CGPoint(x: 118, y: 154), CGPoint(x: 163, y: 153)
        ]
        let known = CGAffineTransform(a: 1.18, b: 0.12, c: -0.12, d: 1.18, tx: 4, ty: -8)
        let target = source.map { $0.applying(known) }
        guard let estimated = FaceAlignment.transform(from: source, to: target) else {
            return XCTFail("A non-degenerate five-point set should produce a transform")
        }
        for (actual, expected) in zip(source.map { $0.applying(estimated) }, target) {
            XCTAssertLessThan(hypot(actual.x - expected.x, actual.y - expected.y), 0.5)
        }
    }

    func testAlignedCropUsesTopHalfOfYDownImage() {
        let width = 400, height = 800
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let red = y < height / 2 // The first row in CGImage memory is the top of the image.
            for x in 0..<width {
                let offset = (y * width + x) * 4
                bytes[offset] = red ? 220 : 20
                bytes[offset + 1] = 0
                bytes[offset + 2] = red ? 20 : 220
                bytes[offset + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let crop = FaceAlignment.alignedCrop(image, points: FaceAlignment.template)!
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(crop, in: CGRect(x: -55, y: -55, width: 112, height: 112))
        XCTAssertGreaterThan(pixel[0], pixel[2])
    }

    func testAverageLinkSplitsTwoSyntheticClustersAndHonoursThreshold() {
        let vectors: [[Float]] = [[1, 0], [0.98, 0.05], [-1, 0], [-0.98, -0.05]]
        XCTAssertEqual(FaceClustering.averageLink(vectors, threshold: 0.65).count, 2)
        XCTAssertEqual(FaceClustering.averageLink(vectors, threshold: 2.1).count, 1)
        // The expected grouping is the result of the naive member-pair
        // average-link calculation for this four-vector synthetic set.
        XCTAssertEqual(FaceClustering.averageLink([[1, 0], [0.9, 0.1], [0, 1], [0, 0.9]], threshold: 0.2), [[0, 1], [2, 3]])
    }

    func testStoppedClusteringLeavesEveryPendingFaceUnassigned() {
        let faces = [
            PeopleFaceSnapshot(id: "pending-a", personID: nil, clusterID: "pending-pending-a", confirmed: false, assignmentSource: "auto", rejectedPersonIDs: "", embedding: embedding([1, 0])),
            PeopleFaceSnapshot(id: "pending-b", personID: nil, clusterID: "pending-pending-b", confirmed: false, assignmentSource: "auto", rejectedPersonIDs: "", embedding: embedding([0.99, 0.01])),
            PeopleFaceSnapshot(id: "pending-c", personID: nil, clusterID: "pending-pending-c", confirmed: false, assignmentSource: "auto", rejectedPersonIDs: "", embedding: embedding([-1, 0]))
        ]
        let checks = TestCounter()
        let result = PeopleScanController.makeAssignmentsResult(faces: faces, people: [], shouldStop: {
            // Stop at the first check: an interrupted run must persist no cluster ids.
            checks.value += 1
            return true
        })
        XCTAssertTrue(result.clusteringStopped)
        XCTAssertEqual(result.assignments.map(\.clusterID), faces.map(\.clusterID))
    }

    func testIncrementalAssignmentKeepsConfirmedPersonIDsStable() {
        let confirmed: [(id: String, centroid: [Float])] = [
            ("person-a", [1, 0, 0]), ("person-b", [0, 1, 0])
        ]
        XCTAssertEqual(FaceClustering.assignIncrementally([0.99, 0.02, 0], to: confirmed), "person-a")
        XCTAssertNil(FaceClustering.assignIncrementally([-1, 0, 0], to: confirmed))
    }

    func testRejectedFaceIsNeverReassigned() {
        let face = FaceObservation(
            mediaID: "synthetic-media",
            rect: (0, 0, 1, 1),
            embedding: embedding([1, 0]),
            cropData: Data([1]),
            quality: 1,
            personID: "synthetic-person",
            confirmed: true,
            assignmentSource: "user"
        )
        PeopleStoreActions.remove(face: face)
        XCTAssertTrue(face.rejectedPersonIDSet.contains("synthetic-person"))
        XCTAssertFalse(face.canAssign(to: "synthetic-person"))
        XCTAssertNil(FaceClustering.assignIncrementally(
            [1, 0],
            to: [(id: "synthetic-person", centroid: [1, 0])],
            rejecting: face.rejectedPersonIDSet
        ))
    }

    func testAutoAssignedFacesDoNotMoveUserCentroid() {
        let faces = [
            PeopleFaceSnapshot(id: "user-face", personID: "synthetic-person", clusterID: nil, confirmed: true, assignmentSource: "user", rejectedPersonIDs: "", embedding: embedding([1, 0])),
            PeopleFaceSnapshot(id: "auto-face", personID: "synthetic-person", clusterID: nil, confirmed: true, assignmentSource: "auto", rejectedPersonIDs: "", embedding: embedding([-1, 0])),
            PeopleFaceSnapshot(id: "candidate", personID: nil, clusterID: "pending-candidate", confirmed: false, assignmentSource: "auto", rejectedPersonIDs: "", embedding: embedding([1, 0]))
        ]
        let assignments = PeopleScanController.makeAssignments(faces: faces, people: [PeoplePersonSnapshot(id: "synthetic-person")])
        let candidate = assignments.first { $0.id == "candidate" }
        XCTAssertEqual(candidate?.personID, "synthetic-person")
        XCTAssertEqual(candidate?.assignmentSource, "auto")
        XCTAssertFalse(candidate?.confirmed ?? true)
    }

    func testZeroFaceItemIsMarkedScanned() async throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let store = PeopleScanStore(modelContainer: container)
        try await store.save(
            results: [PeopleScanResult(mediaID: "synthetic-zero-face", faces: [])],
            scannedIDs: ["synthetic-zero-face"],
            version: 1
        )
        let records = try container.mainContext.fetch(FetchDescriptor<FaceScanRecord>())
        XCTAssertEqual(records.map(\.id), ["synthetic-zero-face"])
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<FaceObservation>()).isEmpty)
    }

    func testUnavailableMediaIsLeftUnscanned() async throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let store = PeopleScanStore(modelContainer: container)
        let unavailable = PeopleMediaDescriptor(id: "synthetic-unavailable", bookmarkData: nil, photosLocalIdentifier: nil)
        let loaded = await PeopleImageLoader.load(unavailable)
        XCTAssertNil(loaded)
        try await store.save(
            results: [PeopleScanResult(mediaID: "synthetic-available", faces: [])],
            scannedIDs: ["synthetic-available"],
            version: 1
        )
        let records = try container.mainContext.fetch(FetchDescriptor<FaceScanRecord>())
        XCTAssertEqual(records.map(\.id), ["synthetic-available"])
        XCTAssertFalse(records.contains { $0.id == "synthetic-unavailable" })
    }

    func testScanCoordinatorWaitsForCancelledRunBeforeStartingNext() async {
        let coordinator = PeopleScanCoordinator()
        let log = TestEventLog()
        let first = Task {
            await coordinator.run {
                await log.append("first-start")
                try? await Task.sleep(nanoseconds: 50_000_000)
                await log.append("first-end")
            }
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        await coordinator.run {
            await log.append("second-start")
            await log.append("second-end")
        }
        _ = await first.value
        let events = await log.snapshot()
        XCTAssertEqual(events, ["first-start", "first-end", "second-start", "second-end"])
    }

    func testPersonFilterAndRuleUseFaceObservations() throws {
        let item = MediaItem(id: "synthetic-item")
        let other = MediaItem(id: "synthetic-other")
        let person = Person(id: "synthetic-person", name: "Synthetic")
        let observation = FaceObservation(
            mediaID: item.id,
            rect: (0.1, 0.1, 0.2, 0.2),
            embedding: Data(repeating: 0, count: 128 * MemoryLayout<Float>.size),
            cropData: Data([1, 2, 3]),
            quality: 0.9,
            personID: person.id,
            confirmed: true
        )
        let criteria = LibraryFilterCriteria(personID: person.id)
        XCTAssertEqual(LibraryFilterEngine.filteredItems([item, other], by: criteria, observations: [observation]).map(\.id), [item.id])
        let rule = UserGroupRule(field: .person, value: person.id)
        XCTAssertTrue(UserGroupRuleEngine.matches(item, ruleSet: UserGroupRuleSet(rules: [rule]), observations: [observation]))
        XCTAssertFalse(UserGroupRuleEngine.matches(other, ruleSet: UserGroupRuleSet(rules: [rule]), observations: [observation]))
    }

    func testMergeRemoveAndHideMutations() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let source = Person(id: "source", name: "Source")
        let target = Person(id: "target", name: "Target")
        let group = UserGroup(name: "Synthetic group", kind: .smart, rules: UserGroupRuleSet(rules: [UserGroupRule(field: .person, value: source.id)]))
        let observation = FaceObservation(
            mediaID: "synthetic-item",
            rect: (0, 0, 1, 1),
            embedding: Data(repeating: 0, count: 128 * MemoryLayout<Float>.size),
            cropData: Data([4, 5, 6]),
            quality: 0.9,
            personID: source.id,
            confirmed: true,
            rejectedPersonIDs: source.id
        )
        context.insert(source)
        context.insert(target)
        context.insert(group)
        context.insert(observation)
        UserDefaults.standard.set(source.id, forKey: "moments.library.person")
        defer { UserDefaults.standard.removeObject(forKey: "moments.library.person") }
        PeopleStoreActions.merge(sourceID: source.id, into: target.id, people: [source, target], observations: [observation], context: context)
        XCTAssertEqual(observation.personID, target.id)
        XCTAssertEqual(observation.rejectedPersonIDs, target.id)
        XCTAssertEqual(group.rules.rules.first?.value, target.id)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "moments.library.person"), target.id)
        PeopleStoreActions.remove(face: observation)
        XCTAssertNil(observation.personID)
        PeopleStoreActions.hide(person: target)
        XCTAssertTrue(target.hidden)
    }

    func testBackgroundWriteBackPreservesConcurrentUserConfirmation() async throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let person = Person(id: "synthetic-person", name: "Synthetic")
        let observation = FaceObservation(
            mediaID: "synthetic-item",
            rect: (0, 0, 1, 1),
            embedding: embedding([1, 0]),
            cropData: Data([1]),
            quality: 1,
            clusterID: "pending-face"
        )
        context.insert(person)
        context.insert(observation)
        try context.save()

        let store = PeopleScanStore(modelContainer: container)
        let snapshot = try await store.assignmentSnapshot()
        observation.personID = person.id
        observation.clusterID = nil
        observation.confirmed = true
        observation.assignmentSource = "user"
        observation.updatedAt = .now
        try context.save()

        try await store.apply(
            assignments: [PeopleFaceAssignment(id: observation.id, personID: nil, clusterID: "cluster-machine", confirmed: false, assignmentSource: "auto")],
            snapshots: snapshot.faces
        )
        XCTAssertEqual(observation.personID, person.id)
        XCTAssertNil(observation.clusterID)
        XCTAssertTrue(observation.confirmed)
        XCTAssertEqual(observation.assignmentSource, "user")
    }

    func testUserConfirmationOfAScanInsertedFaceSurvivesWriteBack() async throws {
        // On disk: an in-memory store shares one row cache and hides staleness.
        let folder = FileManager.default.temporaryDirectory.appending(path: "people-race-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let container = try MomentsPersistence.makeContainer(url: folder.appending(path: "Moments.store"))
        let person = Person(id: "synthetic-person", name: "Synthetic")
        container.mainContext.insert(person)
        try container.mainContext.save()
        let store = PeopleScanStore(modelContainer: container)
        // The scan inserts the face, then the user confirms it on the main context.
        try await store.save(
            results: [PeopleScanResult(mediaID: "synthetic-item", faces: [
                FaceObservationDraft(rect: (0, 0, 1, 1), quality: 1, embedding: embedding([1, 0]), cropData: Data([1]))
            ])],
            scannedIDs: ["synthetic-item"],
            version: 1
        )
        let face = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<FaceObservation>()).first)
        face.personID = person.id
        face.clusterID = nil
        face.confirmed = true
        face.assignmentSource = "user"
        face.updatedAt = .now
        try container.mainContext.save()

        let snapshot = try await store.assignmentSnapshot()
        try await store.apply(
            assignments: [PeopleFaceAssignment(id: face.id, personID: nil, clusterID: "cluster-machine", confirmed: false, assignmentSource: "auto")],
            snapshots: snapshot.faces
        )
        let stored = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<FaceObservation>()).first)
        XCTAssertEqual(stored.personID, person.id)
        XCTAssertTrue(stored.confirmed)
        XCTAssertEqual(stored.assignmentSource, "user")
    }

    func testUnavailableEmbedderDoesNoDetectionWork() async {
        struct Unavailable: FaceEmbedder {
            let isAvailable = false
            func embedding(for crop: CGImage) throws -> [Float] { throw FaceEmbedderError.unavailable }
        }
        let pipeline = PeopleScanPipeline(embedder: Unavailable())
        let values = await pipeline.scanDetailed([])
        XCTAssertTrue(values.isEmpty)
    }

    func testSFaceInputTensorIsRGBPlanarRawValues() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 112, height: 112, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 112, height: 112))
        let tensor = try XCTUnwrap(SFaceCoreMLEmbedder.inputTensor(from: try XCTUnwrap(context.makeImage())))
        let plane = 112 * 112
        XCTAssertEqual(tensor.count, 3 * plane)
        XCTAssertEqual(tensor[0], 255, accuracy: 1)           // channel 0 is red
        XCTAssertEqual(tensor[plane], 0, accuracy: 1)         // channel 1 is green
        XCTAssertEqual(tensor[2 * plane], 0, accuracy: 1)     // channel 2 is blue
    }

    func testNearestNeighbourChainMatchesNaiveAverageLink() {
        var generator = SyntheticRandom(seed: 7)
        for _ in 0..<6 {
            let centres = (0..<4).map { _ in (0..<16).map { _ in generator.next() * 2 - 1 } }
            let vectors: [[Float]] = (0..<60).map { index in
                centres[index % 4].map { $0 + (generator.next() - 0.5) * 0.6 }
            }
            let fast = FaceClustering.averageLink(vectors).map { $0.sorted() }.sorted { $0[0] < $1[0] }
            XCTAssertEqual(fast, naiveAverageLink(vectors, threshold: FaceClustering.defaultThreshold))
        }
    }

    func testNewPendingFaceJoinsExistingUnnamedCluster() {
        let faces = [
            PeopleFaceSnapshot(id: "member-a", personID: nil, clusterID: "cluster-member-a", confirmed: false, assignmentSource: "auto", rejectedPersonIDs: "", embedding: embedding([1, 0])),
            PeopleFaceSnapshot(id: "member-b", personID: nil, clusterID: "cluster-member-a", confirmed: false, assignmentSource: "auto", rejectedPersonIDs: "", embedding: embedding([0.98, 0.05])),
            PeopleFaceSnapshot(id: "newcomer", personID: nil, clusterID: "pending-newcomer", confirmed: false, assignmentSource: "auto", rejectedPersonIDs: "", embedding: embedding([0.99, 0.02])),
            PeopleFaceSnapshot(id: "stranger", personID: nil, clusterID: "pending-stranger", confirmed: false, assignmentSource: "auto", rejectedPersonIDs: "", embedding: embedding([-1, 0]))
        ]
        let result = PeopleScanController.makeAssignmentsResult(faces: faces, people: [], shouldStop: { false })
        let byID = Dictionary(uniqueKeysWithValues: result.assignments.map { ($0.id, $0.clusterID) })
        XCTAssertEqual(byID["newcomer"], "cluster-member-a")
        XCTAssertNotEqual(byID["stranger"], "cluster-member-a")
        XCTAssertEqual(byID["member-a"], "cluster-member-a")
    }

    private func naiveAverageLink(_ vectors: [[Float]], threshold: Float) -> [[Int]] {
        var clusters = vectors.indices.map { [$0] }
        func average(_ a: [Int], _ b: [Int]) -> Float {
            var total: Float = 0
            for i in a { for j in b { total += FaceClustering.cosineDistance(vectors[i], vectors[j]) } }
            return total / Float(a.count * b.count)
        }
        while clusters.count > 1 {
            var best: (Int, Int, Float)?
            for i in clusters.indices { for j in (i + 1)..<clusters.count {
                let d = average(clusters[i], clusters[j])
                if d < threshold, d < (best?.2 ?? .infinity) { best = (i, j, d) }
            } }
            guard let (i, j, _) = best else { break }
            clusters[i] += clusters[j]; clusters.remove(at: j)
        }
        return clusters.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }
}

/// Deterministic generator for synthetic test vectors.
private struct SyntheticRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 24)
    }
}

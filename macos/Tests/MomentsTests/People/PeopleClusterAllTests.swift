import Foundation
import XCTest
@testable import Moments

/// One pass groups every unnamed face, however many there are: the faces are
/// clustered in rounds of at most `chunkSize`, and each round pulls the close
/// faces of the later rounds into its new groups. Every person, face and vector
/// here is synthetic.
final class PeopleClusterAllTests: XCTestCase {
    private static let dimension = 128
    private static let peopleCount = 12
    private static let faceCount = 600
    private static let noise: Float = 0.035

    private struct SyntheticFace {
        let person: Int
        let snapshot: PeopleFaceSnapshot
    }

    private func embedding(_ values: [Float]) -> Data {
        var data = Data()
        values.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private func unit(_ vector: [Float]) -> [Float] {
        var squared: Float = 0
        for value in vector { squared += value * value }
        let norm: Float = sqrt(squared)
        guard norm > 0 else { return vector }
        return vector.map { (value: Float) -> Float in value / norm }
    }

    /// 12 random unit centroids, then `count` faces: each picks one person,
    /// adds Gaussian noise per dimension and is normalised again, like a face
    /// embedding. Every face has its own photo and its own creation date.
    private func makeFaces(count: Int, seed: UInt64 = 11) -> [SyntheticFace] {
        var random = ClusterTestRandom(seed: seed)
        var centroids: [[Float]] = []
        for _ in 0..<Self.peopleCount {
            var vector = [Float](repeating: 0, count: Self.dimension)
            for d in 0..<Self.dimension {
                vector[d] = Float(random.normal())
            }
            centroids.append(unit(vector))
        }
        var faces: [SyntheticFace] = []
        for index in 0..<count {
            let person: Int = random.below(Self.peopleCount)
            let centroid: [Float] = centroids[person]
            var noisy = [Float](repeating: 0, count: Self.dimension)
            for d in 0..<Self.dimension {
                noisy[d] = centroid[d] + Float(random.normal()) * Self.noise
            }
            let id = "synthetic-face-\(index)"
            let snapshot = PeopleFaceSnapshot(
                id: id,
                personID: nil,
                clusterID: "pending-\(id)",
                confirmed: false,
                assignmentSource: "auto",
                rejectedPersonIDs: "",
                embedding: embedding(unit(noisy)),
                createdAt: Date(timeIntervalSince1970: Double(index)),
                mediaID: "synthetic-photo-\(index)"
            )
            faces.append(SyntheticFace(person: person, snapshot: snapshot))
        }
        return faces
    }

    private func snapshots(_ faces: [SyntheticFace]) -> [PeopleFaceSnapshot] {
        faces.map { (face: SyntheticFace) -> PeopleFaceSnapshot in face.snapshot }
    }

    /// The fields the clustering may change, as comparable text.
    private func describable(_ assignments: [PeopleFaceAssignment]) -> [String] {
        assignments.map { (assignment: PeopleFaceAssignment) -> String in
            let person: String = assignment.personID ?? "-"
            let cluster: String = assignment.clusterID ?? "-"
            return "\(assignment.id)|\(person)|\(cluster)|\(assignment.confirmed)|\(assignment.assignmentSource)"
        }
    }

    func testChunksOfTwoHundredGroupEveryFace() {
        let faces = makeFaces(count: Self.faceCount)
        let result = PeopleScanController.makeAssignmentsResult(
            faces: snapshots(faces),
            people: [],
            shouldStop: { false },
            chunkSize: 200
        )
        XCTAssertFalse(result.clusteringStopped)
        XCTAssertEqual(result.assignments.count, Self.faceCount)
        let pending: [PeopleFaceAssignment] = result.assignments.filter { (assignment: PeopleFaceAssignment) -> Bool in
            assignment.clusterID?.hasPrefix("pending-") == true
        }
        XCTAssertEqual(pending.count, 0, "One pass should group every face, not only the newest chunk")
    }

    func testEachSyntheticPersonLandsInOneGroup() {
        let faces = makeFaces(count: Self.faceCount)
        let result = PeopleScanController.makeAssignmentsResult(
            faces: snapshots(faces),
            people: [],
            shouldStop: { false },
            chunkSize: 200
        )
        XCTAssertEqual(result.assignments.count, faces.count)
        var clusterByFaceID: [String: String] = [:]
        for assignment in result.assignments {
            if let clusterID = assignment.clusterID {
                clusterByFaceID[assignment.id] = clusterID
            }
        }
        var clusterIDsByPerson: [Int: [String]] = [:]
        var faceCountByPerson: [Int: Int] = [:]
        for face in faces {
            faceCountByPerson[face.person, default: 0] += 1
            if let clusterID = clusterByFaceID[face.snapshot.id] {
                clusterIDsByPerson[face.person, default: []].append(clusterID)
            }
        }
        for person in 0..<Self.peopleCount {
            let expected: Int = faceCountByPerson[person] ?? 0
            XCTAssertGreaterThan(expected, 0, "Every synthetic person should have faces")
            let clusterIDs: [String] = clusterIDsByPerson[person] ?? []
            XCTAssertEqual(clusterIDs.count, expected, "Person \(person) should have every face in a group")
            var countsByCluster: [String: Int] = [:]
            for clusterID in clusterIDs { countsByCluster[clusterID, default: 0] += 1 }
            let largest: Int = countsByCluster.values.max() ?? 0
            let share: Double = Double(largest) / Double(max(expected, 1))
            XCTAssertGreaterThanOrEqual(share, 0.95, "Person \(person) should share one group")
        }
        let distinctClusters: Set<String> = Set(result.assignments.compactMap { (assignment: PeopleFaceAssignment) -> String? in
            assignment.clusterID
        })
        XCTAssertLessThanOrEqual(distinctClusters.count, 15, "12 people should not become dozens of groups")
    }

    func testOneChunkGivesTheSameResultAsOneSinglePass() {
        let faces = makeFaces(count: Self.faceCount)
        let sample: [PeopleFaceSnapshot] = Array(snapshots(faces).prefix(150))
        let chunked = PeopleScanController.makeAssignmentsResult(
            faces: sample,
            people: [],
            shouldStop: { false },
            chunkSize: 200
        )
        let onePass = PeopleScanController.makeAssignmentsResult(
            faces: sample,
            people: [],
            shouldStop: { false },
            chunkSize: 3_000
        )
        XCTAssertFalse(chunked.clusteringStopped)
        XCTAssertFalse(onePass.clusteringStopped)
        XCTAssertEqual(describable(chunked.assignments), describable(onePass.assignments))
    }

    func testStopDuringClusteringKeepsTheInputAssignments() {
        // Twelve faces: the pending pass checks the stop once, the clustering
        // checks it at its first step, so the second call stops the run.
        let faces = makeFaces(count: 12)
        let counter = ClusterTestCounter()
        let result = PeopleScanController.makeAssignmentsResult(
            faces: snapshots(faces),
            people: [],
            shouldStop: { counter.next() > 1 },
            chunkSize: 5
        )
        XCTAssertTrue(result.clusteringStopped)
        XCTAssertEqual(result.assignments.count, faces.count)
        for (index, assignment) in result.assignments.enumerated() {
            let face: PeopleFaceSnapshot = faces[index].snapshot
            XCTAssertEqual(assignment.id, face.id)
            XCTAssertNil(assignment.personID)
            XCTAssertEqual(assignment.clusterID, face.clusterID)
            XCTAssertFalse(assignment.confirmed)
            XCTAssertEqual(assignment.assignmentSource, "auto")
        }
    }
}

/// Counts the stop checks; `nonisolated` in the app calls it from one scan task.
private final class ClusterTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Deterministic random generator (SplitMix64), copied from the stress library
/// so the test data is reproducible without importing it.
private struct ClusterTestRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// In [0, 1).
    mutating func unitInterval() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(max(1, bound)))
    }

    /// Standard normal (Box–Muller).
    mutating func normal() -> Double {
        let u: Double = max(unitInterval(), 1e-12)
        return sqrt(-2 * log(u)) * cos(2 * .pi * unitInterval())
    }
}

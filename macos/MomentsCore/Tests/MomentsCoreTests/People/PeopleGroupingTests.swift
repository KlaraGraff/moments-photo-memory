import Foundation
import XCTest
@testable import MomentsCore

final class PeopleGroupingTests: XCTestCase {
    // MARK: - Fixture decoding

    private struct FixtureFace: Decodable {
        let q: Double
        let photo: String
        let day: Double?
    }

    private struct FixtureExpected: Decodable {
        let groups: [[Int]]
        let questions: [[Int]]
        let loose: [Int]
    }

    private struct Fixture: Decodable {
        let embeddingsInt8Base64: String
        let dims: Int
        let faces: [FixtureFace]
        let expected: FixtureExpected
    }

    private static func decodeFixture() throws -> (faces: [PeopleGroupingFace], expected: FixtureExpected) {
        let data = Data(PeopleGroupingFixture.json.utf8)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.embeddingsInt8Base64))
        let dims = fixture.dims
        XCTAssertGreaterThan(dims, 0)
        let faceCount = fixture.faces.count
        XCTAssertEqual(bytes.count, faceCount * dims)
        var faces: [PeopleGroupingFace] = []
        faces.reserveCapacity(faceCount)
        for index in 0..<faceCount {
            var embedding: [Float] = []
            embedding.reserveCapacity(dims)
            for dimension in 0..<dims {
                let byte = bytes[index * dims + dimension]
                let signed = Int8(bitPattern: byte)
                embedding.append(Float(signed))
            }
            let face = fixture.faces[index]
            faces.append(
                PeopleGroupingFace(
                    embedding: embedding,
                    quality: face.q,
                    photoID: face.photo,
                    day: face.day
                )
            )
        }
        return (faces, fixture.expected)
    }

    // MARK: - a) the Python reference on the fixture

    func testMatchesPythonReferenceOnFixture() throws {
        let (faces, expected) = try Self.decodeFixture()
        let plan = try XCTUnwrap(PeopleGrouping.plan(faces))

        let expectedGroups: [Set<Int>] = expected.groups.map { (group: [Int]) -> Set<Int> in
            Set(group)
        }
        let actualGroups: [Set<Int>] = plan.groups.map { (group: [Int]) -> Set<Int> in
            Set(group)
        }
        let expectedSorted: [Set<Int>] = expectedGroups.sorted { (lhs: Set<Int>, rhs: Set<Int>) -> Bool in
            Self.ordered(lhs).lexicographicallyPrecedes(Self.ordered(rhs))
        }
        let actualSorted: [Set<Int>] = actualGroups.sorted { (lhs: Set<Int>, rhs: Set<Int>) -> Bool in
            Self.ordered(lhs).lexicographicallyPrecedes(Self.ordered(rhs))
        }
        if actualSorted != expectedSorted {
            let missing = expectedSorted.filter { (group: Set<Int>) -> Bool in
                !actualSorted.contains(group)
            }
            let extra = actualSorted.filter { (group: Set<Int>) -> Bool in
                !expectedSorted.contains(group)
            }
            let firstMissing = missing.first.map { (group: Set<Int>) -> String in
                Self.ordered(group).description
            } ?? "none"
            let firstExtra = extra.first.map { (group: Set<Int>) -> String in
                Self.ordered(group).description
            } ?? "none"
            XCTFail(
                "groups differ: \(actualSorted.count) vs \(expectedSorted.count) expected; "
                    + "first missing \(firstMissing); first extra \(firstExtra)"
            )
        }

        let expectedQuestions: [(Set<Int>, Set<Int>)] = expected.questions.map {
            (pair: [Int]) -> (Set<Int>, Set<Int>) in
            (Set(expected.groups[pair[0]]), Set(expected.groups[pair[1]]))
        }
        let actualQuestions: [(Set<Int>, Set<Int>)] = plan.questions.map { (pair: PeopleGroupingPair) -> (Set<Int>, Set<Int>) in
            (Set(plan.groups[pair.first]), Set(plan.groups[pair.second]))
        }
        if actualQuestions.count != expectedQuestions.count {
            XCTFail("question count \(actualQuestions.count) != expected \(expectedQuestions.count)")
        } else {
            for (index, actual) in actualQuestions.enumerated() {
                let wanted = expectedQuestions[index]
                let matches = actual.0 == wanted.0 && actual.1 == wanted.1
                    || actual.0 == wanted.1 && actual.1 == wanted.0
                if !matches {
                    XCTFail(
                        "question \(index) differs: \(Self.ordered(actual.0)) vs \(Self.ordered(actual.1)); "
                            + "expected \(Self.ordered(wanted.0)) vs \(Self.ordered(wanted.1))"
                    )
                    break
                }
            }
        }

        XCTAssertEqual(plan.loose, expected.loose.sorted(), "loose faces differ")
    }

    private static func ordered(_ set: Set<Int>) -> [Int] {
        set.sorted()
    }

    // MARK: - b) two faces of one photo never share a group via attach

    func testTwoFacesOfOnePhotoNeverShareAGroupViaAttach() throws {
        // A card of 3 faces near 0 degrees and a 2-face fragment near 70 degrees
        // whose centre is closer than `absorb`, so one signal would attach it.
        // The fragment's first face reuses the card's photo "p1", a photo with two
        // faces cannot hold one person twice, so the attach must be refused.
        let shared = try XCTUnwrap(PeopleGrouping.plan(Self.fragmentFaces(fragmentPhoto: "p1")))
        XCTAssertEqual(shared.groups.map { (group: [Int]) -> Set<Int> in Set(group) }, [Set([0, 1, 2])])
        XCTAssertEqual(shared.loose, [3, 4])

        // The same geometry with a fragment photo of its own attaches: without the
        // shared photo the rule merges them.
        let separate = try XCTUnwrap(PeopleGrouping.plan(Self.fragmentFaces(fragmentPhoto: "q1")))
        XCTAssertEqual(separate.groups.map { (group: [Int]) -> Set<Int> in Set(group) }, [Set([0, 1, 2, 3, 4])])
        XCTAssertTrue(separate.loose.isEmpty)
    }

    // MARK: - c) stop

    func testStopReturnsNil() {
        let faces: [PeopleGroupingFace] = Self.fragmentFaces(fragmentPhoto: "p1")
        let plan = PeopleGrouping.plan(faces, shouldStop: { true })
        XCTAssertNil(plan)
    }

    // MARK: - d) no date means no outing match

    func testNoDateFacesNeverMatchOnOuting() throws {
        // A card of three faces at 0 degrees and a 2-face fragment at about 68
        // degrees. The fragment's centre is in [absorb, absorb_wide) of the card,
        // its closest face is farther than face_close and the year buckets are
        // farther apart than absorb_time, so it needs two agreeing extra signals.
        // With a date it gets a shared outing and a kNN vote and attaches; with
        // day == nil there is no outing and no year bucket, so it stays loose.
        let withDate = try XCTUnwrap(PeopleGrouping.plan(Self.outingFaces(day: 1000)))
        XCTAssertEqual(withDate.groups.map { (group: [Int]) -> Set<Int> in Set(group) }, [Set([0, 1, 2, 3, 4])])
        XCTAssertTrue(withDate.loose.isEmpty, "with a date the shared outing attaches the fragment")

        let withoutDate = try XCTUnwrap(PeopleGrouping.plan(Self.outingFaces(day: nil)))
        XCTAssertEqual(
            withoutDate.groups.map { (group: [Int]) -> Set<Int> in Set(group) },
            [Set([0, 1, 2])],
            "no date: nothing matches on an outing or a year"
        )
        XCTAssertEqual(withoutDate.loose, [3, 4])
    }

    // MARK: - e) chunking keeps every face

    func testChunkingKeepsAllFaces() throws {
        let faceCount = 40
        var faces: [PeopleGroupingFace] = []
        faces.reserveCapacity(faceCount)
        // Four well-separated directions, ten faces each, so clustering has real
        // structure while the chunk size forces several chunks.
        for index in 0..<faceCount {
            let cluster = index % 4
            var embedding = [Float](repeating: 0, count: 4)
            embedding[cluster] = 1
            embedding[(cluster + 1) % 4] = Float(index) * 0.001
            faces.append(
                PeopleGroupingFace(
                    embedding: embedding,
                    quality: 0.9,
                    photoID: "p\(index)",
                    day: Double(index)
                )
            )
        }
        var parameters = PeopleGroupingParameters()
        parameters.chunkSize = 10
        let plan = try XCTUnwrap(PeopleGrouping.plan(faces, parameters: parameters))
        var seen = Set<Int>()
        var total = 0
        for group in plan.groups {
            for face in group {
                XCTAssertTrue(seen.insert(face).inserted, "face \(face) appears twice")
                total += 1
            }
        }
        for face in plan.loose {
            XCTAssertTrue(seen.insert(face).inserted, "face \(face) appears twice")
            total += 1
        }
        XCTAssertEqual(seen.count, faceCount, "every face appears exactly once")
        XCTAssertEqual(total, faceCount)
    }

    // MARK: - Shared hand-made input

    /// Unit vector at `degrees`.
    private static func vector(degrees: Double) -> [Float] {
        let radians = degrees * Double.pi / 180
        return [Float(cos(radians)), Float(sin(radians))]
    }

    /// Three faces near 0 degrees (photos p0, p1, p2) and a fragment of two
    /// faces near 70 degrees. The fragment's first face reuses `fragmentPhoto`,
    /// which is the card's photo p1.
    private static func fragmentFaces(fragmentPhoto: String) -> [PeopleGroupingFace] {
        var faces: [PeopleGroupingFace] = []
        for (index, degrees) in [-1.0, 0.0, 1.0].enumerated() {
            faces.append(
                PeopleGroupingFace(
                    embedding: vector(degrees: degrees),
                    quality: 0.9,
                    photoID: "p\(index)",
                    day: 1000
                )
            )
        }
        for (index, degrees) in [69.5, 70.5].enumerated() {
            let photo = index == 0 ? fragmentPhoto : "\(fragmentPhoto)-extra"
            faces.append(
                PeopleGroupingFace(
                    embedding: vector(degrees: degrees),
                    quality: 0.9,
                    photoID: photo,
                    day: 1000
                )
            )
        }
        return faces
    }

    /// Three faces near 0 degrees and a 2-face fragment near 68 degrees, all at
    /// the same optional `day`.
    private static func outingFaces(day: Double?) -> [PeopleGroupingFace] {
        var faces: [PeopleGroupingFace] = []
        for (index, degrees) in [-1.0, 0.0, 1.0].enumerated() {
            faces.append(
                PeopleGroupingFace(
                    embedding: vector(degrees: degrees),
                    quality: 0.9,
                    photoID: "a\(index)",
                    day: day
                )
            )
        }
        for (index, degrees) in [68.0, 69.0].enumerated() {
            faces.append(
                PeopleGroupingFace(
                    embedding: vector(degrees: degrees),
                    quality: 0.9,
                    photoID: "b\(index)",
                    day: day
                )
            )
        }
        return faces
    }
}

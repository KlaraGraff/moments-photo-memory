import Foundation
import XCTest
@testable import MomentsCore

/// The chunked index gives the same answers as one corpus built from
/// scratch, and a change to one photo folds one chunk. Synthetic data only.
final class SearchIndexTests: XCTestCase {
    private func all(_ texts: [String: [String]], _ query: String) -> Set<String>? {
        SearchCorpus(textsByID: texts).ids(matching: query)
    }

    func testMatchesLikeOneCorpus() {
        let texts: [String: [String]] = [
            "a": ["Harbor Town", "We found a crab"],
            "b": ["山顶小屋", "第一次看到彩虹"],
            "c": ["Café on the corner"],
            "d": [],
        ]
        let index = SearchIndex(textsByID: texts, chunkSize: 2)
        XCTAssertEqual(index.chunkCount, 2)
        for query in ["crab", "harbor crab", "彩虹", "cafe", "CAFÉ corner", "nothing", "a", "town 彩虹"] {
            XCTAssertEqual(index.ids(matching: query), all(texts, query), query)
        }
        XCTAssertNil(index.ids(matching: "  "))
    }

    func testAddingChangingAndRemovingPhotos() {
        var index = SearchIndex(textsByID: ["a": ["old words"], "b": ["kept"]], chunkSize: 2)
        XCTAssertEqual(index.update(["a": ["new words"]]), 1)
        XCTAssertEqual(index.ids(matching: "old"), [])
        XCTAssertEqual(index.ids(matching: "new"), ["a"])
        XCTAssertEqual(index.update(["a": ["new words"], "b": ["kept"]]), 0, "Unchanged texts cost nothing")
        XCTAssertEqual(index.update(["c": ["added later"], "b": nil, "gone": nil]), 2)
        XCTAssertEqual(index.ids(matching: "kept"), [])
        XCTAssertEqual(index.ids(matching: "later"), ["c"])
        XCTAssertFalse(index.contains("b"))
        XCTAssertEqual(index.count, 2)
    }

    /// Many random edits leave the index matching a corpus built from the
    /// same texts at once.
    func testRandomEditsMatchARebuild() {
        var generator = SearchIndexSeededGenerator(seed: 7)
        let words: [String] = ["sea", "Café", "海边", "rain", "下雨", "trip", "walk", "ＡＢＣ"]
        func randomTexts() -> [String] {
            (0..<Int.random(in: 0...3, using: &generator)).map { _ in
                (0..<Int.random(in: 1...3, using: &generator)).map { _ in words.randomElement(using: &generator) ?? "" }.joined(separator: " ")
            }
        }
        var expected: [String: [String]] = [:]
        var index = SearchIndex(chunkSize: 8)
        for _ in 0..<40 {
            var changes: [String: [String]?] = [:]
            for _ in 0..<Int.random(in: 1...20, using: &generator) {
                let id = "p\(Int.random(in: 0..<60, using: &generator))"
                if Bool.random(using: &generator) || expected[id] == nil {
                    let texts = randomTexts()
                    changes[id] = texts
                    expected[id] = texts
                } else {
                    changes[id] = .some(nil)
                    expected[id] = nil
                }
            }
            index.update(changes)
            XCTAssertEqual(index.count, expected.count)
            for query in ["sea", "cafe 海边", "rain walk", "abc", "下雨 trip sea"] {
                XCTAssertEqual(index.ids(matching: query), all(expected, query), query)
            }
        }
    }

    // MARK: What a save changed

    func testALookupSaysWhichPhotosDaysChaptersAndPlacesChanged() {
        let before = WrittenTextIndex.Lookup(sources: .init(
            photoTexts: [.init(id: "m1", mediaID: "p1", text: "crab")],
            collectionTexts: [.init(id: "d1", scope: .day, key: "2024-05-17", text: "rain")],
            placeTexts: [.init(placeName: "Harbor", text: "lighthouse")],
            tripNames: [.init(tripID: "trip-1", name: "Coast")]
        ))
        let after = WrittenTextIndex.Lookup(sources: .init(
            photoTexts: [.init(id: "m1", mediaID: "p1", text: "crab")],
            collectionTexts: [.init(id: "d1", scope: .day, key: "2024-05-17", text: "rain")],
            placeTexts: [.init(placeName: "Harbor", text: "lighthouse")],
            comments: [.init(memoryID: "m1", text: "a kite"), .init(memoryID: "d1", text: "umbrellas")],
            tripNames: [.init(tripID: "trip-1", name: "Coast road")]
        ))
        let changes = after.changes(from: before)
        XCTAssertEqual(changes.photoIDs, ["p1"], "A comment under a photo's memory")
        XCTAssertEqual(changes.dayKeys, ["2024-05-17"], "A comment under a day's memory")
        XCTAssertEqual(changes.chapterKeys, ["trip-1"], "A trip renamed")
        XCTAssertEqual(changes.placeKeys, [])
        XCTAssertTrue(after.changes(from: after).isEmpty)
        // Removing everything is a change too.
        let emptied = WrittenTextIndex.Lookup().changes(from: after)
        XCTAssertEqual(emptied.placeKeys, ["harbor"])
    }

    func testTheSameRecordsInAnotherOrderAreNoChange() {
        let first = WrittenTextIndex.Lookup(sources: .init(photoTexts: [
            .init(id: "m1", mediaID: "p1", text: "one"),
            .init(id: "m2", mediaID: "p1", text: "two"),
        ]))
        let second = WrittenTextIndex.Lookup(sources: .init(photoTexts: [
            .init(id: "m2", mediaID: "p1", text: "two"),
            .init(id: "m1", mediaID: "p1", text: "one"),
        ]))
        XCTAssertEqual(first, second)
    }

    func testATripNameFindsItsPhotos() {
        let lookup = WrittenTextIndex.Lookup(sources: .init(tripNames: [.init(tripID: "trip-1", name: "Coast Trip")]))
        XCTAssertEqual(lookup.texts(for: .init(id: "p1", chapterKeys: ["trip-1", "trip-1"])), ["Coast Trip"])
        XCTAssertEqual(lookup.texts(for: .init(id: "p2")), [])
    }

    // MARK: A book kept record by record

    private func sources(of records: [String: WrittenTextIndex.Book.Record]) -> WrittenTextIndex.Sources {
        var sources = WrittenTextIndex.Sources()
        for record in records.values {
            switch record {
            case .photo(let id, let mediaID, let text): sources.photoTexts.append(.init(id: id, mediaID: mediaID, text: text))
            case .collection(let id, let scope, let key, let text): sources.collectionTexts.append(.init(id: id, scope: scope, key: key, text: text))
            case .place(let name, let text): sources.placeTexts.append(.init(placeName: name, text: text))
            case .comment(let memoryID, let text): sources.comments.append(.init(memoryID: memoryID, text: text))
            case .tripName(let tripID, let name): sources.tripNames.append(.init(tripID: tripID, name: name))
            }
        }
        return sources
    }

    func testABookFollowsItsCommentsWhenAMemoryMoves() {
        var book = WrittenTextIndex.Book()
        book.set(["c1": .comment(memoryID: "m1", text: "kite"), "m1": .photo(id: "m1", mediaID: "p1", text: "beach")])
        XCTAssertEqual(book.lookup.byPhoto["p1"], ["beach", "kite"])
        let moved = book.set(["m1": .collection(id: "m1", scope: .day, key: "2024-05-17", text: "beach")])
        XCTAssertEqual(moved.photoIDs, ["p1"])
        XCTAssertEqual(moved.dayKeys, ["2024-05-17"])
        XCTAssertNil(book.lookup.byPhoto["p1"])
        XCTAssertEqual(book.lookup.byDay["2024-05-17"], ["beach", "kite"])
        XCTAssertTrue(book.set(["m1": .collection(id: "m1", scope: .day, key: "2024-05-17", text: "beach")]).isEmpty, "The same record again is no change")
        book.set(["m1": nil])
        XCTAssertEqual(book.lookup, WrittenTextIndex.Lookup(), "A comment whose memory is gone finds nothing")
        XCTAssertEqual(book.count, 1)
    }

    /// Many random saves leave the book equal to a lookup built from the
    /// same records at once, and each save reports what a rebuild would.
    func testRandomSavesMatchALookupBuiltAtOnce() {
        var generator = SearchIndexSeededGenerator(seed: 11)
        let words: [String] = ["sea", "Café", "海边", "rain", " ", "", "trip"]
        func word() -> String { words.randomElement(using: &generator) ?? "" }
        func pick(_ count: Int) -> Int { Int.random(in: 0..<count, using: &generator) }
        func randomRecord(for key: String) -> WrittenTextIndex.Book.Record {
            let memoryID = "mem-\(key)"
            switch pick(6) {
            case 0: return .photo(id: memoryID, mediaID: "p\(pick(8))", text: word())
            case 1: return .photo(id: nil, mediaID: "p\(pick(8))", text: word())
            case 2: return .collection(id: memoryID, scope: Bool.random(using: &generator) ? .day : .chapter, key: "k\(pick(4))", text: word())
            case 3: return .place(placeName: ["Harbor", " harbor ", "Hill", ""][pick(4)], text: word())
            case 4: return .comment(memoryID: "mem-r\(pick(30))", text: word())
            default: return .tripName(tripID: "k\(pick(4))", name: word())
            }
        }
        var records: [String: WrittenTextIndex.Book.Record] = [:]
        var book = WrittenTextIndex.Book()
        var previous = WrittenTextIndex.Lookup()
        for _ in 0..<300 {
            var changes: [String: WrittenTextIndex.Book.Record?] = [:]
            for _ in 0..<(1 + pick(5)) {
                let key = "r\(pick(30))"
                if pick(4) == 0 {
                    changes[key] = .some(nil)
                    records[key] = nil
                } else {
                    let record = randomRecord(for: key)
                    changes[key] = record
                    records[key] = record
                }
            }
            let reported = book.set(changes)
            let expected = WrittenTextIndex.Lookup(sources: sources(of: records))
            XCTAssertEqual(book.lookup, expected)
            XCTAssertEqual(reported, expected.changes(from: previous))
            XCTAssertEqual(book.count, records.count)
            previous = expected
        }
    }

    // MARK: 50,000 photos

    /// One photo's new text in a 50,000-photo index folds one chunk.
    func testFiftyThousandPhotosOneChange() {
        let count = 50_000
        var texts: [String: [String]] = [:]
        for index in 0..<count {
            texts["p\(index)"] = ["Bench Place \(index / 100)", "memory number \(index) at the beach 海边散步", "2024", "May 2024"]
        }
        let clock = ContinuousClock()
        var index = SearchIndex()
        let build = clock.measure { index = SearchIndex(textsByID: texts) }
        var changed = 0
        let one = clock.measure { changed = index.update(["p123": ["Bench Place 1", "a new comment about pancakes"]]) }
        var found: Set<String>? = nil
        let typed = clock.measure { found = index.ids(matching: "pancakes") }
        let miss = clock.measure { _ = index.ids(matching: "zzqx") }
        print("SEARCH-BENCH linux-index photos=\(count) chunks=\(index.chunkCount) build=\(build) one-change=\(one) hit=\(typed) miss=\(miss)")
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(found, ["p123"])
    }
}

/// A small deterministic generator, so the random test is the same each run.
private struct SearchIndexSeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

import Foundation
import XCTest
@testable import MomentsCore

/// Search finds every kind of text written in the app, each under the photos
/// it belongs to. All data is synthetic.
final class WrittenTextSearchTests: XCTestCase {
    /// Three days, two trips, two places; photo ids say where they are.
    private let photos: [WrittenTextIndex.Photo] = [
        .init(id: "beach-1", dayKey: "2024-05-17", chapterKeys: ["trip-coast"], placeNames: ["Harbor Town"]),
        .init(id: "beach-2", dayKey: "2024-05-17", chapterKeys: ["trip-coast"], placeNames: ["Harbor Town"]),
        .init(id: "hill-1", dayKey: "2024-05-18", chapterKeys: ["trip-coast", "chapter.party"], placeNames: ["山顶小屋"]),
        .init(id: "home-1", dayKey: "2024-06-01", chapterKeys: [], placeNames: []),
        .init(id: "undated", dayKey: nil, chapterKeys: [], placeNames: []),
    ]

    private func search(_ query: String, _ sources: WrittenTextIndex.Sources) -> Set<String> {
        let texts = WrittenTextIndex.textsByPhoto(photos: photos, sources: sources)
        var all: [String: [String]] = [:]
        for photo in photos { all[photo.id] = texts[photo.id] ?? [] }
        return SearchCorpus(textsByID: all).ids(matching: query) ?? Set(photos.map(\.id))
    }

    // MARK: Each kind of text

    func testAPhotoMemoryFindsItsPhoto() {
        let sources = WrittenTextIndex.Sources(photoTexts: [
            .init(id: "m1", mediaID: "beach-1", text: "We found a tiny crab under the pier"),
            .init(id: "m2", mediaID: "hill-1", text: "第一次看到这么大的彩虹"),
        ])
        XCTAssertEqual(search("crab", sources), ["beach-1"])
        XCTAssertEqual(search("CRAB pier", sources), ["beach-1"], "Several words, any case")
        XCTAssertEqual(search("彩虹", sources), ["hill-1"])
        XCTAssertEqual(search("crab 彩虹", sources), [], "Every word must be found on the same photo")
    }

    func testThePartnersMemoryIsFoundToo() {
        // Two memories on one photo, one by each person.
        let sources = WrittenTextIndex.Sources(photoTexts: [
            .init(id: "mine", mediaID: "beach-2", text: "Sunset walk"),
            .init(id: "theirs", mediaID: "beach-2", text: "她说海风是咸的"),
        ])
        XCTAssertEqual(search("海风", sources), ["beach-2"])
        XCTAssertEqual(search("sunset 海风", sources), ["beach-2"], "Words may come from both people's memories")
    }

    func testADayMemoryFindsEveryPhotoOfThatDay() {
        let sources = WrittenTextIndex.Sources(collectionTexts: [
            .init(id: "d1", scope: .day, key: "2024-05-17", text: "Rained all morning, then pancakes"),
            .init(id: "d2", scope: .day, key: "2024-06-01", text: "搬家的第一天"),
        ])
        XCTAssertEqual(search("pancakes", sources), ["beach-1", "beach-2"])
        XCTAssertEqual(search("rained pancakes", sources), ["beach-1", "beach-2"])
        XCTAssertEqual(search("搬家", sources), ["home-1"])
        XCTAssertEqual(search("pancakes 搬家", sources), [])
    }

    func testATripOrChapterMemoryFindsEveryPhotoInIt() {
        let sources = WrittenTextIndex.Sources(collectionTexts: [
            .init(id: "t1", scope: .chapter, key: "trip-coast", text: "Our first road trip along the coast"),
            .init(id: "t2", scope: .chapter, key: "chapter.party", text: "生日聚会"),
        ])
        XCTAssertEqual(search("road trip", sources), ["beach-1", "beach-2", "hill-1"])
        XCTAssertEqual(search("生日", sources), ["hill-1"])
        XCTAssertEqual(search("coast 生日", sources), ["hill-1"], "A photo in two chapters has both texts")
    }

    func testAPlaceNoteFindsEveryPhotoAtThatPlace() {
        let sources = WrittenTextIndex.Sources(placeTexts: [
            .init(placeName: "  harbor town ", text: "The bakery by the lighthouse"),
            .init(placeName: "山顶小屋", text: "要走两个小时的山路"),
        ])
        XCTAssertEqual(search("bakery", sources), ["beach-1", "beach-2"], "Place names match regardless of case and spaces")
        XCTAssertEqual(search("lighthouse bakery", sources), ["beach-1", "beach-2"])
        XCTAssertEqual(search("山路", sources), ["hill-1"])
    }

    func testACommentFindsThePhotoOfItsMemory() {
        let sources = WrittenTextIndex.Sources(
            photoTexts: [.init(id: "m1", mediaID: "hill-1", text: "View from the top")],
            comments: [
                .init(memoryID: "m1", text: "I was so out of breath"),
                .init(memoryID: "m1", text: "下次带上望远镜"),
                .init(memoryID: "gone", text: "orphan words"),
            ]
        )
        XCTAssertEqual(search("breath", sources), ["hill-1"])
        XCTAssertEqual(search("out of breath", sources), ["hill-1"])
        XCTAssertEqual(search("望远镜", sources), ["hill-1"])
        XCTAssertEqual(search("orphan", sources), [], "A comment whose memory is missing finds nothing")
    }

    func testACommentOnADayMemoryFindsThatDay() {
        let sources = WrittenTextIndex.Sources(
            collectionTexts: [.init(id: "d1", scope: .day, key: "2024-05-18", text: "Hike")],
            comments: [.init(memoryID: "d1", text: "Blisters everywhere")]
        )
        XCTAssertEqual(search("blisters", sources), ["hill-1"])
    }

    func testANotesOriginalWordsFindThePhoto() {
        // What someone typed before the AI organized it: no memory id.
        let sources = WrittenTextIndex.Sources(photoTexts: [
            .init(mediaID: "home-1", text: "new sofa arrived, cat already sleeping on it"),
            .init(mediaID: "beach-1", text: "原话：今天风特别大"),
        ])
        XCTAssertEqual(search("sofa cat", sources), ["home-1"])
        XCTAssertEqual(search("风特别大", sources), ["beach-1"])
    }

    // MARK: Rules shared by every kind

    func testEmptyAndMissingTextsFindNothing() {
        let sources = WrittenTextIndex.Sources(
            photoTexts: [.init(id: "m", mediaID: "beach-1", text: "   \n ")],
            collectionTexts: [.init(id: "d", scope: .day, key: "2099-01-01", text: "nobody was there")],
            placeTexts: [.init(placeName: "  ", text: "no place")]
        )
        let texts = WrittenTextIndex.textsByPhoto(photos: photos, sources: sources)
        XCTAssertTrue(texts.isEmpty, "Nothing written reaches a photo: \(texts)")
        XCTAssertEqual(search("nobody", sources), [])
    }

    func testAPlaceNamedTwiceAddsItsNoteOnce() {
        let photo = WrittenTextIndex.Photo(id: "p", placeNames: ["Harbor Town", "harbor town"])
        let texts = WrittenTextIndex.textsByPhoto(
            photos: [photo],
            sources: .init(placeTexts: [.init(placeName: "Harbor Town", text: "bakery")])
        )
        XCTAssertEqual(texts["p"], ["bakery"])
    }

    func testWordsIgnoreCaseAccentsAndWidth() {
        let corpus = SearchCorpus(textsByID: ["a": ["Café au lait in Zürich"], "b": ["ＡＢＣ全角"]])
        XCTAssertEqual(corpus.ids(matching: "cafe"), ["a"])
        XCTAssertEqual(corpus.ids(matching: "ZURICH"), ["a"])
        XCTAssertEqual(corpus.ids(matching: "abc"), ["b"])
        XCTAssertEqual(corpus.ids(matching: "全角"), ["b"])
    }

    func testAWordCannotSpanTwoTextsOrTwoPhotos() {
        let corpus = SearchCorpus(textsByID: ["a": ["sun", "set"], "b": ["sun"], "c": ["set"]])
        XCTAssertEqual(corpus.ids(matching: "sunset"), [])
        XCTAssertEqual(corpus.ids(matching: "sun set"), ["a"], "Separate words may come from separate texts")
    }

    func testAnEmptyQueryNarrowsNothing() {
        let corpus = SearchCorpus(textsByID: ["a": ["x"]])
        XCTAssertNil(corpus.ids(matching: ""))
        XCTAssertNil(corpus.ids(matching: " \u{3000} "), "A full-width space is a space")
        XCTAssertEqual(corpus.ids(matching: "x\u{3000}x"), ["a"])
    }

    func testPhotosWithNoTextAreCountedAndNeverMatch() {
        let corpus = SearchCorpus(textsByID: ["a": [], "b": ["hello"], "c": ["  "]])
        XCTAssertEqual(corpus.count, 3)
        XCTAssertEqual(corpus.ids(matching: "hello"), ["b"])
        XCTAssertEqual(corpus.ids(matching: "h"), ["b"])
    }

    func testMatchesTheOldRuleOnRandomText() {
        // The old search: every word is contained (case-insensitive) in one
        // of the photo's texts. Checked on generated text and queries.
        var generator = SeededGenerator(seed: 7)
        let alphabet: [String] = ["sea", "Sun", "海", "边", "cafe", "rain", "nap", "日落", "Ok"]
        var texts: [String: [String]] = [:]
        for index in 0..<300 {
            let count = Int.random(in: 0...3, using: &generator)
            texts["p\(index)"] = (0..<count).map { _ in
                (0..<Int.random(in: 1...4, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }.joined(separator: Bool.random(using: &generator) ? " " : "")
            }
        }
        let corpus = SearchCorpus(textsByID: texts)
        for _ in 0..<200 {
            let query = (0..<Int.random(in: 1...2, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }.joined(separator: " ")
            let words = query.split(separator: " ").map { $0.lowercased() }
            let expected = Set(texts.compactMap { (id: String, list: [String]) -> String? in
                words.allSatisfy { word in list.contains { $0.lowercased().contains(word) } } ? id : nil
            })
            XCTAssertEqual(corpus.ids(matching: query), expected, query)
        }
    }

    // MARK: Scale

    /// 50,000 synthetic photos with memories, day, trip and place texts. Prints
    /// the time to build the index and to answer one typed query, so the
    /// numbers can be compared with the app-side measurement.
    func testFiftyThousandPhotosIndexAndSearch() {
        let count = 50_000
        var photos: [WrittenTextIndex.Photo] = []
        photos.reserveCapacity(count)
        var sources = WrittenTextIndex.Sources()
        for index in 0..<count {
            let day = String(format: "2024-%02d-%02d", index / 4_000 % 12 + 1, index / 150 % 28 + 1)
            photos.append(.init(id: "p\(index)", dayKey: day, chapterKeys: ["trip-\(index / 500)"], placeNames: ["Place \(index / 40)"]))
            if index % 3 == 0 {
                sources.photoTexts.append(.init(id: "m\(index)", mediaID: "p\(index)", text: "memory number \(index) at the beach 海边散步"))
            }
            if index % 150 == 0 { sources.collectionTexts.append(.init(id: "d\(index)", scope: .day, key: day, text: "a long day \(index) 下雨")) }
            if index % 500 == 0 { sources.collectionTexts.append(.init(id: "t\(index)", scope: .chapter, key: "trip-\(index / 500)", text: "trip story \(index)")) }
            if index % 40 == 0 { sources.placeTexts.append(.init(placeName: "Place \(index / 40)", text: "place note \(index)")) }
        }
        let clock = ContinuousClock()
        var texts: [String: [String]] = [:]
        let gather = clock.measure { texts = WrittenTextIndex.textsByPhoto(photos: photos, sources: sources) }
        var corpus = SearchCorpus(textsByID: [:])
        let build = clock.measure { corpus = SearchCorpus(textsByID: texts) }
        var found: Set<String>? = nil
        let query = clock.measure { found = corpus.ids(matching: "nothing-matches-this") }
        var oneDay: Set<String>? = nil
        let typed = clock.measure { oneDay = corpus.ids(matching: "day 150 下雨") }
        print("SEARCH-BENCH linux photos=\(count) bytes=\(corpus.byteCount) gather=\(gather) build=\(build) miss=\(query) hit=\(typed)")
        XCTAssertEqual(corpus.count, texts.count)
        XCTAssertEqual(found, [])
        XCTAssertFalse(oneDay?.isEmpty ?? true)
    }
}

/// A small deterministic generator, so the random test is the same each run.
private struct SeededGenerator: RandomNumberGenerator {
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

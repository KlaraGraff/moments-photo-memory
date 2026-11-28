import Foundation
import XCTest
@testable import MomentsCore

/// Synthetic chapters only: made-up words, no places that exist.
final class MemoryBookTests: XCTestCase {
    private static let base = Date(timeIntervalSince1970: 1_778_000_000)

    private static func day(_ offset: Int, hour: Int = 9) -> Date {
        base.addingTimeInterval(Double(offset) * 86_400 + Double(hour) * 3_600)
    }

    static let strings = MemoryBookStrings(
        author: { $0 ? "Ada" : "Bo" },
        memoriesOf: "Memories of Ada and Bo",
        beforeWeBegin: "Before we begin",
        dayHeading: { number, _ in "Day \(number)" },
        dayDate: { date in "Date \(Int(date.timeIntervalSince(MemoryBookTests.base) / 86_400))" },
        undatedDay: "Without a date",
        dateRange: { _, _ in "Range" },
        photoCaption: { _, place in place ?? "Photo" },
        comment: { "Comment · \($0)" },
        picturesFolder: "Pictures"
    )

    private func sampleChapter() -> MemoryBookDocument {
        MemoryBookDocument(
            title: "Seaside Test",
            startDate: Self.day(0),
            endDate: Self.day(2),
            placeNames: ["North Cape", "Harbour"],
            chapterMemories: [
                MemoryBookNote(text: "First drive together.", isOwn: true),
                MemoryBookNote(text: "  ", isOwn: false),
            ],
            days: [
                MemoryBookDay(
                    id: "d0", dayKey: "2026-05-05", date: Self.day(0),
                    memories: [MemoryBookNote(text: "Rain in the morning.", isOwn: false)],
                    placeNotes: [MemoryBookPlaceNote(placeName: "Harbour", text: "Busy at six.", isOwn: false)],
                    photos: [
                        MemoryBookPhoto(id: "p1", date: Self.day(0, hour: 8), placeName: "Harbour", memories: [
                            MemoryBookMemory(text: "A bag of shrimp.", isOwn: true, comments: [MemoryBookComment(text: "You wanted it!", isOwn: false)]),
                            MemoryBookMemory(text: "Okay, I did.", isOwn: false),
                        ]),
                        MemoryBookPhoto(id: "p2", date: Self.day(0, hour: 9)),
                    ]
                ),
                MemoryBookDay(id: "d1", dayKey: "2026-05-06", date: Self.day(1), photos: [
                    MemoryBookPhoto(id: "p3", date: Self.day(1, hour: 11), memories: [MemoryBookMemory(text: "Uphill walk.", isOwn: true)]),
                    MemoryBookPhoto(id: "p4", date: Self.day(1, hour: 12), memories: [MemoryBookMemory(text: "Windy.", isOwn: false)]),
                    MemoryBookPhoto(id: "p5", date: Self.day(1, hour: 18), memories: [MemoryBookMemory(text: String(repeating: "Clouds parted. ", count: 8), isOwn: true)]),
                ]),
                MemoryBookDay(id: "d2", dayKey: "2026-05-07", date: Self.day(2), photos: [MemoryBookPhoto(id: "p6", date: Self.day(2))]),
            ]
        )
    }

    // MARK: - Plan

    func testOnlyPhotosWithMemoriesByDefaultAndEmptyDaysDrop() {
        let book = MemoryBookPlan.prepared(sampleChapter(), options: MemoryBookOptions())
        XCTAssertEqual(book.photos.map(\.id), ["p1", "p3", "p4", "p5"])
        XCTAssertEqual(book.days.map(\.id), ["d0", "d1"])
        // Day numbers count dated days in the whole chapter, so they match the app.
        XCTAssertEqual(book.days.map(\.number), [1, 2])
        XCTAssertEqual(book.chapterMemories.count, 1, "blank memories are dropped")

        let all = MemoryBookPlan.prepared(sampleChapter(), options: MemoryBookOptions(photos: .all))
        XCTAssertEqual(all.photos.count, 6)
        XCTAssertEqual(all.days.map(\.number), [1, 2, 3])
        XCTAssertEqual(MemoryBookPlan.photoCounts(sampleChapter()).withMemories, 4)
        XCTAssertEqual(MemoryBookPlan.photoCounts(sampleChapter()).all, 6)
    }

    func testEachKindOfWritingCanBeLeftOut() {
        let options = MemoryBookOptions(includesChapterAndDayMemories: false, includesPlaceNotes: false, includesComments: false)
        let book = MemoryBookPlan.prepared(sampleChapter(), options: options)
        XCTAssertTrue(book.chapterMemories.isEmpty)
        XCTAssertTrue(book.days.allSatisfy { $0.memories.isEmpty && $0.placeNotes.isEmpty })
        XCTAssertTrue(book.photos.flatMap(\.memories).allSatisfy { $0.comments.isEmpty })
        XCTAssertEqual(book.photos.flatMap(\.memories).count, 5, "photo memories always stay")
    }

    func testAChapterWithNoWritingIsNoticed() {
        let empty = MemoryBookDocument(title: "Empty", days: [MemoryBookDay(id: "d", photos: [MemoryBookPhoto(id: "p")])])
        XCTAssertTrue(MemoryBookPlan.hasNoWriting(empty))
        XCTAssertFalse(MemoryBookPlan.hasNoWriting(sampleChapter()))
    }

    func testShortMemoriesPairUpAndLongOrCommentedOnesStandAlone() {
        let book = MemoryBookPlan.prepared(sampleChapter(), options: MemoryBookOptions())
        XCTAssertEqual(MemoryBookPlan.rows(book.days[0].photos).map { $0.map(\.id) }, [["p1"]], "comments make a photo stand alone")
        XCTAssertEqual(MemoryBookPlan.rows(book.days[1].photos).map { $0.map(\.id) }, [["p3", "p4"], ["p5"]])
        let three = ["a", "b", "c"].map { MemoryBookPhoto(id: $0, memories: [MemoryBookMemory(text: "短", isOwn: true)]) }
        XCTAssertEqual(MemoryBookPlan.rows(three).map { $0.map(\.id) }, [["a", "b"], ["c"]])
    }

    // MARK: - Pagination

    func testPagesBreakWhenFullAndWhereADayStarts() {
        typealias Block = MemoryBookPagination.Block
        let blocks = [
            Block(height: 300, startsPage: true),
            Block(height: 300),
            Block(height: 300), // doesn't fit after the first two
            Block(height: 50, keepsWithNext: true, startsPage: true),
            Block(height: 200),
        ]
        XCTAssertEqual(MemoryBookPagination.pages(blocks, pageHeight: 700, spacing: 10), [[0, 1], [2], [3, 4]])
    }

    func testAHeadingIsNeverLeftAloneAtTheBottom() {
        typealias Block = MemoryBookPagination.Block
        let blocks = [Block(height: 600), Block(height: 40, keepsWithNext: true), Block(height: 200)]
        XCTAssertEqual(MemoryBookPagination.pages(blocks, pageHeight: 700, spacing: 10), [[0], [1, 2]])
    }

    func testABlockTallerThanAPageGetsAPageOfItsOwn() {
        typealias Block = MemoryBookPagination.Block
        let blocks = [Block(height: 100), Block(height: 1_000), Block(height: 100)]
        XCTAssertEqual(MemoryBookPagination.pages(blocks, pageHeight: 700, spacing: 10), [[0], [1], [2]])
    }

    // MARK: - PDF layout

    /// 14 points a line, about 7 points a character.
    static let measure: MemoryBookLayout.Measure = { text, width in
        let perLine = max(1, Int(width / 7))
        let lines = text.string.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + perLine - 1) / perLine) }
        return Double(lines) * 14
    }

    func testTheLayoutStartsWithTheCoverAndEachDayOnANewPage() {
        let book = MemoryBookPlan.prepared(sampleChapter(), options: MemoryBookOptions())
        let input = MemoryBookLayout.Input(document: book, strings: Self.strings, aspectRatios: ["p1": 0.75], coverPhotoID: "p1", coverFooterRight: "May 2026", madeWith: "Made with Moments")
        let pages = MemoryBookLayout.pages(input, measure: Self.measure)
        XCTAssertEqual(pages.count, 3)
        XCTAssertTrue(pages[0].text.contains("Seaside Test"))
        XCTAssertTrue(pages[0].text.contains("Before we begin"))
        XCTAssertEqual(pages[0].footer.left, "Made with Moments")
        XCTAssertTrue(pages[1].text.hasPrefix("Day 1"))
        XCTAssertTrue(pages[2].text.hasPrefix("Day 2"))
        XCTAssertEqual(pages[2].footer.left, "Seaside Test")
        XCTAssertEqual(pages[2].footer.right, "3")
        XCTAssertEqual(pages.flatMap(\.photoIDs), ["p1", "p1", "p3", "p4", "p5"], "the cover photo, then every photo once")
        // Both people's words, with their names.
        let all = pages.map(\.text).joined()
        XCTAssertTrue(all.contains("A bag of shrimp. — Ada"))
        XCTAssertTrue(all.contains("Okay, I did. — Bo"))
        XCTAssertTrue(all.contains("Bo: You wanted it!"))
    }

    func testNothingOverlapsOrLeavesThePage() {
        var chapter = sampleChapter()
        // Enough photos and words for several pages, with tall and wide photos.
        chapter.days.append(MemoryBookDay(id: "d9", dayKey: "2026-05-08", date: Self.day(3), photos: (0..<14).map { index in
            MemoryBookPhoto(id: "x\(index)", date: Self.day(3, hour: index), memories: [
                MemoryBookMemory(text: String(repeating: "word ", count: index * 25 + 1), isOwn: index.isMultiple(of: 2)),
            ])
        }))
        var ratios: [String: Double] = [:]
        for index in 0..<14 { ratios["x\(index)"] = index.isMultiple(of: 3) ? 0.6 : 1.8 }
        let metrics = MemoryBookLayoutMetrics.a4
        let book = MemoryBookPlan.prepared(chapter, options: MemoryBookOptions(photos: .all))
        let pages = MemoryBookLayout.pages(MemoryBookLayout.Input(document: book, strings: Self.strings, aspectRatios: ratios, madeWith: "M"), metrics: metrics, measure: Self.measure)
        XCTAssertGreaterThan(pages.count, 5)
        let content = MemoryBookRect(x: metrics.margin, y: metrics.margin, width: metrics.contentWidth, height: metrics.contentHeight)
        for (number, page) in pages.enumerated() {
            for (index, piece) in page.pieces.enumerated() {
                XCTAssertTrue(content.contains(piece.frame), "page \(number + 1): \(piece.content) leaves the text area")
                for other in page.pieces[(index + 1)...] {
                    XCTAssertFalse(piece.frame.intersects(other.frame), "page \(number + 1): pieces overlap")
                }
            }
        }
        XCTAssertEqual(Set(pages.flatMap(\.photoIDs)).count, book.photos.count, "every photo is placed")
    }

    func testChineseNamesGetAFullWidthColon() {
        XCTAssertEqual(MemoryBookLayout.nameSeparator("阿晴"), "：")
        XCTAssertEqual(MemoryBookLayout.nameSeparator("Bo"), ": ")
    }

    // MARK: - Markdown

    func testTheBookMarkdownHasBothPeopleAndNumberedPictures() {
        let book = MemoryBookPlan.prepared(sampleChapter(), options: MemoryBookOptions())
        let output = MemoryBookMarkdown.book(book, strings: Self.strings)
        XCTAssertEqual(output.pictures.map(\.fileName), ["001.jpg", "002.jpg", "003.jpg", "004.jpg"])
        XCTAssertEqual(output.pictures.map(\.photoID), ["p1", "p3", "p4", "p5"])
        let expectedStart = """
        # Seaside Test

        Range · Memories of Ada and Bo

        North Cape · Harbour

        ## Before we begin

        > First drive together. — Ada

        ## Day 1

        > Rain in the morning. — Bo

        **Harbour**: Busy at six. — Bo

        ![Harbour](Pictures/001.jpg)

        - Ada: A bag of shrimp.
          - Comment · Bo: You wanted it!
        - Bo: Okay, I did.
        """
        XCTAssertTrue(output.text.hasPrefix(expectedStart), output.text)
    }

    func testMarkdownKeepsWrittenWordsAsWords() {
        XCTAssertEqual(MemoryBookMarkdown.escape("a *b* [c](d) <e>"), "a \\*b\\* \\[c\\](d) \\<e\\>")
        XCTAssertEqual(MemoryBookMarkdown.paragraph("# not a heading\n- not a list\n1. not a number\n2026. a year"), [
            "\\# not a heading", "\\- not a list", "1\\. not a number", "2026\\. a year",
        ])
        XCTAssertEqual(MemoryBookMarkdown.paragraph("one\r\n\n\n\ntwo  \n"), ["one", "", "two"])
        let quoted = MemoryBookMarkdown.quotes([MemoryBookNote(text: "第一行\n\n第二行", isOwn: false)], strings: Self.strings)
        XCTAssertEqual(quoted, ["> 第一行", ">", "> 第二行 — Bo"])
        let list = MemoryBookMarkdown.memoryList([MemoryBookMemory(text: "line one\nline two", isOwn: true)], strings: Self.strings)
        XCTAssertEqual(list, ["- Ada: line one", "  line two"])
    }

    func testPictureNamesWidenForBigChapters() {
        let photos = (0..<1_200).map { MemoryBookPhoto(id: "p\($0)", memories: [MemoryBookMemory(text: "x", isOwn: true)]) }
        let book = MemoryBookDocument(title: "Big", days: [MemoryBookDay(id: "d", photos: photos)])
        let output = MemoryBookMarkdown.book(book, strings: Self.strings)
        XCTAssertEqual(output.pictures.first?.fileName, "0001.jpg")
        XCTAssertEqual(output.pictures.last?.fileName, "1200.jpg")
    }

    // MARK: - Export All Memories

    private func archiveInput() -> MemoryArchive.Input {
        MemoryArchive.Input(
            chapters: [
                MemoryArchive.Chapter(id: "later", title: "Later Trip", startDate: Self.day(10), memories: [MemoryBookNote(text: "Second trip.", isOwn: false)], dayKeys: ["2026-05-15"]),
                MemoryArchive.Chapter(id: "early", title: "Early Trip", startDate: Self.day(0), memories: [MemoryBookNote(text: "First trip.", isOwn: true)], dayKeys: ["2026-05-05", "2026-05-06"]),
                MemoryArchive.Chapter(id: "quiet", title: "Nothing Written", startDate: Self.day(20), dayKeys: ["2026-05-25"]),
            ],
            photos: [
                MemoryArchive.Photo(chapterID: "early", dayKey: "2026-05-06", photo: MemoryBookPhoto(id: "a", date: Self.day(1), placeName: "Cape", memories: [
                    MemoryBookMemory(text: "Windy.", isOwn: true, comments: [MemoryBookComment(text: "Very.", isOwn: false)]),
                ])),
                MemoryArchive.Photo(chapterID: nil, dayKey: "2026-05-08", photo: MemoryBookPhoto(id: "b", date: Self.day(3), memories: [MemoryBookMemory(text: "At home.", isOwn: false)])),
                MemoryArchive.Photo(chapterID: "later", dayKey: "2026-05-15", photo: MemoryBookPhoto(id: "c", date: Self.day(10), memories: [MemoryBookMemory(text: "Again.", isOwn: true)])),
                MemoryArchive.Photo(chapterID: "gone", dayKey: nil, photo: MemoryBookPhoto(id: "d", memories: [MemoryBookMemory(text: "No date.", isOwn: true)])),
            ],
            dayMemories: [
                MemoryArchive.DayMemories(dayKey: "2026-05-05", date: Self.day(0), memories: [MemoryBookNote(text: "Set off.", isOwn: false)]),
                MemoryArchive.DayMemories(dayKey: "2026-05-09", date: Self.day(4), memories: [MemoryBookNote(text: "Rest day.", isOwn: true)]),
            ],
            placeNotes: [MemoryBookPlaceNote(placeName: "Cape", text: "Bring a coat.", isOwn: false)]
        )
    }

    func testArchiveCountsOnlyWrittenText() {
        let counts = MemoryArchive.counts(archiveInput())
        XCTAssertEqual(counts, MemoryArchive.Counts(photoMemories: 4, chapterAndDayMemories: 4, placeNotes: 1, comments: 1))
        XCTAssertTrue(MemoryArchive.counts(MemoryArchive.Input()).isEmpty)
    }

    func testByChapterPutsEachThingOnceAndSkipsEmptyChapters() {
        let sections = MemoryArchive.sections(archiveInput(), order: .byChapter)
        XCTAssertEqual(sections.map { $0.chapter?.id }, ["early", "later", nil])
        XCTAssertEqual(sections[0].days.map(\.dayKey), ["2026-05-05", "2026-05-06"], "the day memory goes with the chapter that has that day")
        XCTAssertEqual(sections[0].days[0].memories.map(\.text), ["Set off."])
        // Not in a chapter: an unknown chapter counts as none, undated last.
        XCTAssertEqual(sections[2].days.map(\.dayKey), ["2026-05-08", "2026-05-09", nil])
        XCTAssertEqual(sections.flatMap { $0.days.flatMap(\.photos) }.map(\.id).sorted(), ["a", "b", "c", "d"])
    }

    func testByDateOpensEachChapterOnItsFirstDay() {
        let sections = MemoryArchive.sections(archiveInput(), order: .byDate)
        XCTAssertEqual(sections.count, 1)
        let days = sections[0].days
        XCTAssertEqual(days.map(\.dayKey), ["2026-05-05", "2026-05-06", "2026-05-08", "2026-05-09", "2026-05-15", nil])
        XCTAssertEqual(days[0].openings.map(\.title), ["Early Trip"])
        XCTAssertEqual(days[4].openings.map(\.title), ["Later Trip"])
        XCTAssertTrue(days.allSatisfy { $0.number == nil }, "the archive names days by date")
    }

    func testArchiveMarkdownReadsInOrder() {
        let strings = MemoryArchive.Strings(book: Self.strings, title: "Our memories", subtitle: "Ada and Bo · exported", notInAChapter: "Memories not in a chapter", placeNotes: "Place notes")
        let text = MemoryArchive.markdown(archiveInput(), order: .byChapter, strings: strings)
        let order = ["# Our memories", "## Early Trip · Range", "> First trip. — Ada", "### Date 0", "> Set off. — Bo", "### Date 1", "**Cape**", "- Ada: Windy.", "  - Comment · Bo: Very.", "## Later Trip", "## Memories not in a chapter", "### Without a date", "## Place notes", "**Cape**: Bring a coat. — Bo"]
        var position = text.startIndex
        for line in order {
            guard let found = text.range(of: line, range: position..<text.endIndex) else {
                return XCTFail("missing or out of order: \(line)\n\(text)")
            }
            position = found.upperBound
        }
        XCTAssertFalse(text.contains("Nothing Written"))
        let withoutComments = MemoryArchive.markdown(archiveInput(), order: .byDate, options: MemoryBookOptions(includesPlaceNotes: false, includesComments: false), strings: strings)
        XCTAssertFalse(withoutComments.contains("Very."))
        XCTAssertFalse(withoutComments.contains("Place notes"))
        XCTAssertTrue(withoutComments.contains("**Early Trip**"))
    }
}

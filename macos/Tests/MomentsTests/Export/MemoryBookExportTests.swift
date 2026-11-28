import AppKit
import CoreGraphics
import ImageIO
import MomentsCore
import PDFKit
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Moments

/// A memory book leaves the Mac as a file people print or keep, so it must
/// carry both people's words with their names, and nothing of the original
/// photos but their pixels: no location, camera, dates or file names.
/// Everything here is synthetic: generated pictures, coordinates near 0,0
/// and made-up names, in a temporary folder.
final class MemoryBookExportTests: XCTestCase {
    private var folder: URL!
    private let marker = "SyntheticSecretMarker"
    private let camera = "SyntheticCam"
    private let originalName = "IMG_SYNTH_0001.jpg"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "MemoryBookExportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: PDF

    func testAChapterExportsToAPDFWithBothAuthorsAndADayPerPage() async throws {
        let (book, sources, strings) = try syntheticChapter()
        let destination = folder.appending(path: "Out/Synthetic coast.pdf")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let result = try await MemoryBookExporter.export(book, sources: sources, format: .pdf, strings: strings, to: destination, progress: { _ in })
        XCTAssertEqual(result.url, destination)
        XCTAssertEqual(result.thumbnailsUsed, 0, "every synthetic photo has a readable picture")

        let pdf = try XCTUnwrap(PDFDocument(url: destination))
        let expected = MemoryBookLayout.pages(
            MemoryBookLayout.Input(document: book, strings: strings, aspectRatios: ratios(sources), coverPhotoID: book.photos.first?.id, madeWith: "Made with Moments"),
            metrics: MemoryBookPDF.metrics,
            measure: MemoryBookPDF.measure
        )
        // The cover, then each of the two days on a page of its own.
        XCTAssertGreaterThanOrEqual(expected.count, 3)
        XCTAssertEqual(pdf.pageCount, expected.count)
        let page = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(page.width, MemoryBookLayoutMetrics.a4.pageWidth, accuracy: 0.5)
        XCTAssertEqual(page.height, MemoryBookLayoutMetrics.a4.pageHeight, accuracy: 0.5)

        // Lines the layout broke are joined again before looking for words.
        let text = try XCTUnwrap(pdf.string).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for words in ["Robin", "Kai", "Bright cold morning on the pier", "The gulls stole the bread", "Before we go home", "Agreed, worth it"] {
            XCTAssertTrue(text.contains(words), "the PDF should contain “\(words)”")
        }
        XCTAssertFalse(text.contains(originalName))

        let data = try Data(contentsOf: destination)
        try assertNothingOfTheOriginal(in: data)
        // Each photo in the PDF is a JPEG with no metadata.
        let pictures = jpegStreams(in: data)
        for picture in pictures {
            try assertNoMetadata(picture)
        }
    }

    // MARK: Markdown

    func testAChapterExportsToAMarkdownFolderWithSmallerPicturesWithoutMetadata() async throws {
        let (book, sources, strings) = try syntheticChapter()
        let destination = folder.appending(path: "Out/Synthetic coast Memory Book", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        _ = try await MemoryBookExporter.export(book, sources: sources, format: .markdown, strings: strings, to: destination, progress: { _ in })

        let text = try String(contentsOf: destination.appending(path: "Synthetic coast.md"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# Synthetic coast\n"))
        for words in ["Robin", "Kai", "Bright cold morning on the pier", "The gulls stole the bread", "Agreed, worth it"] {
            XCTAssertTrue(text.contains(words), "the Markdown should contain “\(words)”")
        }
        XCTAssertFalse(text.contains(originalName))
        XCTAssertFalse(text.contains(folder.path))

        let pictures = try FileManager.default.contentsOfDirectory(at: destination.appending(path: "Pictures"), includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(pictures.map(\.lastPathComponent), ["001.jpg", "002.jpg", "003.jpg"])
        for picture in pictures {
            XCTAssertTrue(text.contains("Pictures/\(picture.lastPathComponent)"))
            let data = try Data(contentsOf: picture)
            try assertNothingOfTheOriginal(in: data)
            try assertNoMetadata(data)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(max(image.width, image.height), MemoryBookImages.markdownPixelSize)
        }
    }

    // MARK: Stopping

    func testStoppingLeavesNoFileBehind() async throws {
        let (book, sources, strings) = try syntheticChapter()
        let destination = folder.appending(path: "Stopped.pdf")
        let export = Task {
            try await MemoryBookExporter.export(book, sources: sources, format: .pdf, strings: strings, to: destination, progress: { _ in })
        }
        export.cancel()
        do {
            _ = try await export.value
            XCTFail("a stopped export should not finish")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: Pictures

    func testARePackedPhotoKeepsNoLocationCameraOrDate() throws {
        let original = try writeSyntheticPhoto(named: originalName, width: 3000, height: 2000)
        let originalData = try Data(contentsOf: original)
        // The fixture does carry what must be taken out.
        let originalProperties = try properties(originalData)
        XCTAssertNotNil(originalProperties[kCGImagePropertyGPSDictionary as String])

        let image = try XCTUnwrap(MemoryBookImages.decoded(url: original, maxPixelSize: 2_000))
        let packed = try XCTUnwrap(MemoryBookImages.jpeg(image, maxPixelSize: 1_600))
        try assertNoMetadata(packed)
        try assertNothingOfTheOriginal(in: packed)
        let forPDF = try XCTUnwrap(MemoryBookImages.forPDF(image, frame: MemoryBookRect(x: 0, y: 0, width: 240, height: 160)))
        // 240 points at 300 dpi, never more.
        XCTAssertGreaterThanOrEqual(forPDF.width, 999)
        XCTAssertLessThanOrEqual(forPDF.width, 1_001)
    }

    // MARK: Gathering

    @MainActor
    func testExportAllMemoriesGathersBothPeoplesWordsFromTheLibrary() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let day = Date(timeIntervalSince1970: 86_400 * 3 + 43_200)
        let photo = MediaItem(id: "synthetic-photo", captureDate: day, latitude: 0.001, longitude: 0.001, width: 1200, height: 800, localDayKey: "1970-01-04")
        context.insert(photo)
        let own = Memory(text: "Bright cold morning on the pier", author: .me, authorAccountID: MomentsAccount.localID, createdAt: day, mediaItem: photo)
        let theirs = Memory(text: "The gulls stole the bread", author: .partner, authorAccountID: "synthetic-partner", createdAt: day.addingTimeInterval(60), mediaItem: photo)
        context.insert(own)
        context.insert(theirs)
        context.insert(Comment(memoryID: theirs.id, text: "Agreed, worth it", authorAccountID: MomentsAccount.localID, createdAt: day.addingTimeInterval(120)))
        context.insert(CollectionMemory(scope: .day, scopeKey: "1970-01-04", text: "A long walk along the water", authorAccountID: "synthetic-partner", createdAt: day))
        context.insert(PlaceNote(placeName: "Synthetic Harbour", text: "Fish stall by the steps", authorAccountID: MomentsAccount.localID))
        let blank = MediaItem(id: "synthetic-blank", captureDate: day)
        context.insert(blank)
        context.insert(Memory(text: "   ", mediaItem: blank))
        try context.save()

        let input = try MemoryBookCollector.archive(container: container)
        let counts = MemoryArchive.counts(input)
        XCTAssertEqual(counts.photoMemories, 2)
        XCTAssertEqual(counts.chapterAndDayMemories, 1)
        XCTAssertEqual(counts.placeNotes, 1)
        XCTAssertEqual(counts.comments, 1)
        XCTAssertEqual(input.photos.map(\.photo.id), ["synthetic-photo"])
        XCTAssertEqual(input.photos.first?.photo.memories.map(\.isOwn), [true, false])

        let strings = MemoryArchive.Strings(
            book: MemoryBookExporter.strings(myName: "Robin", partnerName: "Kai"),
            title: "Our memories",
            subtitle: "Robin and Kai",
            notInAChapter: "Memories not in a chapter",
            placeNotes: "Place descriptions"
        )
        let text = MemoryArchive.markdown(input, order: .byDate, strings: strings)
        for words in ["Robin", "Kai", "Bright cold morning on the pier", "The gulls stole the bread", "Agreed, worth it", "A long walk along the water", "Fish stall by the steps"] {
            XCTAssertTrue(text.contains(words), "the archive should contain “\(words)”")
        }
        // No coordinates, ids or file names go into the words.
        XCTAssertFalse(text.contains("0.001"))
        XCTAssertFalse(text.contains("synthetic-photo"))

        let destination = folder.appending(path: "Our memories.md")
        try MemoryBookExporter.exportArchive(text, to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), text)
    }

    // MARK: Helpers

    /// Two days: two photos and a day memory on the first, one photo with
    /// a comment on the second, a chapter memory and a place note.
    private func syntheticChapter() throws -> (MemoryBookDocument, [String: MemoryBookImages.Source], MemoryBookStrings) {
        let first = Date(timeIntervalSince1970: 86_400 * 3 + 36_000)
        let second = first.addingTimeInterval(86_400)
        var sources: [String: MemoryBookImages.Source] = [:]
        for (index, id) in ["photo-a", "photo-b", "photo-c"].enumerated() {
            let url = try writeSyntheticPhoto(named: index == 0 ? originalName : "IMG_SYNTH_000\(index + 1).jpg", width: 2400, height: 1600)
            sources[id] = MemoryBookImages.Source(
                id: id,
                original: PeopleMediaDescriptor(id: id, bookmarkData: nil, photosLocalIdentifier: nil),
                sharedPreview: url,
                thumbnail: ThumbnailSource(id: id),
                aspectRatio: 1.5
            )
        }
        let document = MemoryBookDocument(
            title: "Synthetic coast",
            startDate: first,
            endDate: second,
            placeNames: ["Synthetic Harbour"],
            chapterMemories: [MemoryBookNote(text: "Before we go home, write it all down.", isOwn: false)],
            days: [
                MemoryBookDay(
                    id: "day-1",
                    dayKey: "1970-01-04",
                    date: first,
                    memories: [MemoryBookNote(text: "A long walk along the water.", isOwn: true)],
                    placeNotes: [MemoryBookPlaceNote(placeName: "Synthetic Harbour", text: "Fish stall by the steps.", isOwn: true)],
                    photos: [
                        MemoryBookPhoto(id: "photo-a", date: first, placeName: "Synthetic Harbour", memories: [MemoryBookMemory(text: "Bright cold morning on the pier.", isOwn: true)]),
                        MemoryBookPhoto(id: "photo-b", date: first.addingTimeInterval(600), placeName: "Synthetic Harbour", memories: [MemoryBookMemory(text: "The gulls stole the bread.", isOwn: false)]),
                    ]
                ),
                MemoryBookDay(
                    id: "day-2",
                    dayKey: "1970-01-05",
                    date: second,
                    photos: [
                        MemoryBookPhoto(id: "photo-c", date: second, memories: [
                            MemoryBookMemory(text: "The long way back over the hill, slower than planned.", isOwn: false, comments: [MemoryBookComment(text: "Agreed, worth it.", isOwn: true)]),
                        ]),
                    ]
                ),
            ]
        )
        let book = MemoryBookPlan.prepared(document, options: MemoryBookOptions())
        return (book, sources, MemoryBookExporter.strings(myName: "Robin", partnerName: "Kai"))
    }

    private func ratios(_ sources: [String: MemoryBookImages.Source]) -> [String: Double] {
        sources.compactMapValues(\.aspectRatio)
    }

    /// A gradient saved as a JPEG that carries everything a camera would:
    /// a location (near 0,0), camera make and model, dates and a note.
    private func writeSyntheticPhoto(named name: String, width: Int, height: Int) throws -> URL {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let gradient = try XCTUnwrap(CGGradient(
            colorsSpace: space,
            colors: [CGColor(srgbRed: 0.95, green: 0.72, blue: 0.56, alpha: 1), CGColor(srgbRed: 0.25, green: 0.44, blue: 0.51, alpha: 1)] as CFArray,
            locations: [0, 1]
        ))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let image = try XCTUnwrap(context.makeImage())
        let url = folder.appending(path: name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata: [String: Any] = [
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 0.001,
                kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 0.002,
                kCGImagePropertyGPSLongitudeRef as String: "E",
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: camera,
                kCGImagePropertyTIFFModel as String: camera + " One",
                kCGImagePropertyTIFFImageDescription as String: marker,
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "1970:01:04 10:00:00",
                kCGImagePropertyExifUserComment as String: marker,
            ],
        ]
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func properties(_ data: Data) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    private func assertNoMetadata(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let found = try properties(data)
        XCTAssertNil(found[kCGImagePropertyGPSDictionary as String], "no location", file: file, line: line)
        let tiff = found[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        XCTAssertNil(tiff[kCGImagePropertyTIFFMake as String], "no camera", file: file, line: line)
        XCTAssertNil(tiff[kCGImagePropertyTIFFModel as String], "no camera", file: file, line: line)
        XCTAssertNil(tiff[kCGImagePropertyTIFFImageDescription as String], file: file, line: line)
        let exif = found[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal as String], "no capture date", file: file, line: line)
        XCTAssertNil(exif[kCGImagePropertyExifUserComment as String], file: file, line: line)
    }

    /// The camera's words, the note and the original file name never make
    /// it into the exported bytes, compressed or not.
    private func assertNothingOfTheOriginal(in data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        for words in [marker, camera, originalName, folder.path] {
            XCTAssertNil(data.range(of: Data(words.utf8)), "found “\(words)”", file: file, line: line)
        }
    }

    /// The JPEG streams a PDF holds its photos in.
    private func jpegStreams(in data: Data) -> [Data] {
        let start = Data([0xFF, 0xD8, 0xFF])
        let end = Data("endstream".utf8)
        var found: [Data] = []
        var cursor = data.startIndex
        let keyword = Data("stream".utf8)
        while let open = data.range(of: start, in: cursor..<data.endIndex) {
            cursor = open.upperBound
            // Only where a stream starts, not three bytes that happen to
            // match inside compressed data.
            let before = data[max(data.startIndex, open.lowerBound - 8)..<open.lowerBound]
            guard before.range(of: keyword) != nil,
                  let close = data.range(of: end, in: open.lowerBound..<data.endIndex) else { continue }
            found.append(data.subdata(in: open.lowerBound..<close.lowerBound))
            cursor = close.upperBound
        }
        return found
    }
}

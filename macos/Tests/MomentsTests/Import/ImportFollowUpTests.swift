import AVFoundation
import CoreVideo
import Foundation
import SwiftData
import XCTest
import MomentsCore
@testable import Moments

/// #36: videos keep their own place and time zone, and a cancelled folder
/// import resumes without reading its saved files again. Synthetic media only.
@MainActor
final class ImportFollowUpTests: XCTestCase {
    // MARK: Video location and time zone

    func testVideoReadsQuickTimeLocationAndOffset() async throws {
        let folder = try SyntheticMediaFixture.makeFolder()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let url = folder.appending(path: "synthetic-video.mov")
        try await Self.writeVideo(to: url, location: "+00.0100+000.0200+010.000/", creationDate: "2026-01-01T12:00:00+0200")

        let metadata = try await MediaMetadataReader().read(url: url)

        XCTAssertEqual(metadata.kind, .video)
        XCTAssertEqual(try XCTUnwrap(metadata.latitude), 0.01, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(metadata.longitude), 0.02, accuracy: 1e-6)
        XCTAssertEqual(metadata.timeZoneOffsetMinutes, 120)
        XCTAssertEqual(metadata.timeZoneIdentifier, TimeZone(secondsFromGMT: 7_200)?.identifier)
        XCTAssertEqual(metadata.captureDateSource, .asset)
        XCTAssertEqual(metadata.timeConfidence, .exact)
        // 12:00 at +02:00 is 10:00 UTC.
        XCTAssertEqual(metadata.exactCaptureDate, Date(timeIntervalSince1970: 1_767_261_600))
    }

    func testVideoWithoutQuickTimeLocationHasNoCoordinate() async throws {
        let folder = try SyntheticMediaFixture.makeFolder()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let url = folder.appending(path: "synthetic-plain.mov")
        try await Self.writeVideo(to: url, location: nil, creationDate: nil)

        let metadata = try await MediaMetadataReader().read(url: url)

        XCTAssertNil(metadata.latitude)
        XCTAssertNil(metadata.longitude)
        XCTAssertNil(metadata.timeZoneOffsetMinutes)
    }

    func testFolderImportPlacesAVideoByItsOwnLocation() async throws {
        let folder = try SyntheticMediaFixture.makeFolder()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        try await Self.writeVideo(
            to: folder.appending(path: "synthetic-evening.mov"),
            location: "+00.0100+000.0200/",
            // 23:30 at -03:00 is 2 January in UTC but 1 January where it
            // was filmed.
            creationDate: "2026-01-01T23:30:00-0300"
        )
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = Self.importer(store: ImportResumeStore(directory: nil))

        let summary = try await importer.importFolder(folder, container: container)
        let item = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<MediaItem>()).first)

        XCTAssertEqual(item.kind, .video)
        XCTAssertEqual(try XCTUnwrap(item.latitude), 0.01, accuracy: 1e-6)
        XCTAssertEqual(item.localTimeZoneOffsetMinutes, -180)
        XCTAssertEqual(item.localDayKey, "2026-01-01")
        let reasons = summary.flags.first { $0.fileName == "synthetic-evening.mov" }?.reasons ?? []
        XCTAssertFalse(reasons.contains(.missingLocation), "A video with its own location is not placed by its neighbours")
    }

    func testVideoCaptureDatePrefersAStatedZone() {
        let stated = QuickTimeMetadata.CreationDate(date: Date(timeIntervalSince1970: 100), offsetMinutes: 60, isWallClock: false)
        let wallClock = QuickTimeMetadata.CreationDate(date: Date(timeIntervalSince1970: 200), offsetMinutes: nil, isWallClock: true)
        let header = Date(timeIntervalSince1970: 300)

        XCTAssertEqual(
            MediaMetadataReader.videoCaptureDate(quickTime: .init(location: nil, creationDate: stated, assetCreationDate: header)),
            stated
        )
        // The movie header's UTC time beats a zone-less wall-clock value.
        XCTAssertEqual(
            MediaMetadataReader.videoCaptureDate(quickTime: .init(location: nil, creationDate: wallClock, assetCreationDate: header)),
            QuickTimeMetadata.CreationDate(date: header, offsetMinutes: nil, isWallClock: false)
        )
        // With only a wall-clock value, the import resolves it from the place.
        XCTAssertEqual(
            MediaMetadataReader.videoCaptureDate(quickTime: .init(location: nil, creationDate: wallClock, assetCreationDate: nil)),
            wallClock
        )
        XCTAssertNil(MediaMetadataReader.videoCaptureDate(quickTime: .init(location: nil, creationDate: nil, assetCreationDate: nil)))
    }

    // MARK: Cancel and resume

    func testCancelledImportResumesWithoutReadingSavedFilesAndMatchesACleanImport() async throws {
        let folder = try SyntheticMediaFixture.makeFolder()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let checkpoints = FileManager.default.temporaryDirectory.appending(path: "moments-resume-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: checkpoints) }
        let base = Date(timeIntervalSince1970: 1_767_225_600)
        let names = (1...7).map { "synthetic-\($0).jpg" }
        for (index, name) in names.enumerated() {
            try SyntheticMediaFixture.writeJPEG(
                at: folder.appending(path: name),
                date: base.addingTimeInterval(Double(index) * 3_600),
                latitude: 0.001 * Double(index + 1),
                longitude: 0.002,
                marker: index + 1
            )
        }

        // First run: cancelled right after the third read, with batches of
        // two, so one batch was written and one read was still pending.
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let firstReads = ReadLog()
        let first = Self.importer(
            store: ImportResumeStore(directory: checkpoints),
            batchSize: 2,
            reads: firstReads,
            cancelAfter: 3
        )
        // Its own task: the cancel must not reach the test's task.
        let firstRun = Task { try await first.importFolder(folder, container: container) }
        do {
            _ = try await firstRun.value
            XCTFail("The first run should have been cancelled")
        } catch is CancellationError {}
        let firstRead = await firstReads.names
        XCTAssertEqual(firstRead, Array(names.prefix(3)))
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<MediaItem>()).count, 0, "Nothing reaches the library before the end")

        // One saved file changes after the cancel: it is read again.
        let changed = folder.appending(path: names[0])
        try SyntheticMediaFixture.writeJPEG(at: changed, date: base, latitude: 0.001, longitude: 0.002, marker: 91)
        try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(-86_400)], ofItemAtPath: changed.path)

        // Resume with a fresh store over the same folder on disk, as after
        // quitting the app.
        let resumeReads = ReadLog()
        let resumeStore = ImportResumeStore(directory: checkpoints)
        let resumed = Self.importer(store: resumeStore, batchSize: 2, reads: resumeReads)
        let resumedSummary = try await resumed.importFolder(folder, container: container)
        let resumedRead = await resumeReads.names
        XCTAssertEqual(resumedRead, [names[0]] + Array(names.suffix(4)), "Saved, unchanged files are not hashed again")
        XCTAssertEqual(resumedSummary.importedCount, 7)
        let leftovers = await resumeStore.entries(forFolder: FolderImporter.folderKey(folder))
        XCTAssertTrue(leftovers.isEmpty, "A finished import removes its checkpoint")
        let checkpointFiles = (try? FileManager.default.contentsOfDirectory(atPath: checkpoints.path)) ?? []
        XCTAssertTrue(checkpointFiles.isEmpty)

        // The same folder imported in one go gives the same library.
        let cleanContainer = try MomentsPersistence.makeContainer(inMemory: true)
        let clean = Self.importer(store: ImportResumeStore(directory: nil))
        let cleanSummary = try await clean.importFolder(folder, container: cleanContainer)
        XCTAssertEqual(cleanSummary.importedCount, resumedSummary.importedCount)
        XCTAssertEqual(cleanSummary.tripCount, resumedSummary.tripCount)
        XCTAssertEqual(try Self.snapshot(container), try Self.snapshot(cleanContainer))
    }

    func testReimportAfterAFinishedImportReadsEveryFileAgain() async throws {
        let folder = try SyntheticMediaFixture.makeFolder()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        try SyntheticMediaFixture.writeJPEG(at: folder.appending(path: "synthetic-a.jpg"), date: Date(timeIntervalSince1970: 1_767_225_600), marker: 1)
        let store = ImportResumeStore(directory: nil)
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        _ = try await Self.importer(store: store).importFolder(folder, container: container)

        let reads = ReadLog()
        let summary = try await Self.importer(store: store, reads: reads).importFolder(folder, container: container)

        let read = await reads.names
        XCTAssertEqual(read, ["synthetic-a.jpg"], "No checkpoint outlives a finished import")
        XCTAssertEqual(summary.skippedCount, 1)
    }

    func testResumeStoreKeepsFoldersApartAndALaterBatchWins() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "moments-resume-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportResumeStore(directory: directory)
        func entry(_ name: String, size: Int64) -> ImportResumeEntry {
            ImportResumeEntry(
                fingerprint: ImportFileFingerprint(fileSize: size, modificationTime: 1),
                metadata: ImportedMediaMetadata(
                    id: name, bookmarkData: Data(), fileName: name, contentHash: name,
                    captureDate: Date(timeIntervalSince1970: 0), captureDateSource: .exif,
                    timeZoneOffsetMinutes: 0, latitude: nil, longitude: nil,
                    width: 1, height: 1, kind: .photo, duration: nil
                )
            )
        }
        await store.append(["/a/1.jpg": entry("one", size: 1), "/a/2.jpg": entry("two", size: 2)], forFolder: "/a")
        await store.append(["/a/1.jpg": entry("one-changed", size: 3)], forFolder: "/a")
        await store.append(["/b/1.jpg": entry("other", size: 4)], forFolder: "/b")

        // A fresh store reads the batches back from disk.
        let reopened = ImportResumeStore(directory: directory)
        let a = await reopened.entries(forFolder: "/a")
        let b = await reopened.entries(forFolder: "/b")
        XCTAssertEqual(a["/a/1.jpg"]?.metadata.id, "one-changed")
        XCTAssertEqual(a["/a/1.jpg"]?.fingerprint.fileSize, 3)
        XCTAssertEqual(a["/a/2.jpg"]?.metadata.id, "two")
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(Array(b.keys), ["/b/1.jpg"])

        // A checkpoint nobody resumed for over a month is removed.
        await reopened.removeStale(in: directory, now: .now.addingTimeInterval(ImportResumeStore.maximumAge + 60))
        let afterA = await reopened.entries(forFolder: "/a")
        XCTAssertTrue(afterA.isEmpty)
    }

    func testSharedResumeStoreStaysOutOfApplicationSupportInTests() {
        let directory = ImportResumeStore.defaultDirectory.standardizedFileURL.path
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        XCTAssertTrue(directory.hasPrefix(temporary), "Tests never write into the user's Application Support")
    }

    // MARK: Helpers

    private static func importer(
        store: ImportResumeStore,
        batchSize: Int = 200,
        reads: ReadLog? = nil,
        cancelAfter: Int? = nil
    ) -> FolderImporter {
        FolderImporter(
            geocoder: FollowUpGeocoder(),
            geocodeCache: ImportGeocodeCache(),
            geocodeDelay: { true },
            timeZoneDelay: {},
            resumeStore: store,
            resumeBatchSize: batchSize,
            readMetadata: { url in
                let metadata = try await MediaMetadataReader().read(url: url)
                if let reads {
                    let count = await reads.record(url.lastPathComponent)
                    if let cancelAfter, count == cancelAfter {
                        // The read runs in the import's own task.
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
                return metadata
            }
        )
    }

    private struct ItemSnapshot: Equatable {
        let id: String
        let captureDate: Date?
        let latitude: Double?
        let longitude: Double?
        let localDayKey: String?
        let timeZoneIdentifier: String?
        let tripName: String?
        let placeName: String?
        let reviewReasons: String?
    }

    private static func snapshot(_ container: ModelContainer) throws -> [ItemSnapshot] {
        try container.mainContext.fetch(FetchDescriptor<MediaItem>())
            .map { item in
                ItemSnapshot(
                    id: item.id,
                    captureDate: item.captureDate,
                    latitude: item.latitude,
                    longitude: item.longitude,
                    localDayKey: item.localDayKey,
                    timeZoneIdentifier: item.timeZoneIdentifier,
                    tripName: item.trip?.name,
                    placeName: item.place?.name,
                    reviewReasons: item.importReviewReasonsRaw
                )
            }
            .sorted { $0.id < $1.id }
    }

    /// One second of a single colour, H.264 in a QuickTime file, with
    /// optional QuickTime location and creation-date metadata.
    private static func writeVideo(to url: URL, location: String?, creationDate: String?) async throws {
        let width = 64, height = 48
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var items: [AVMetadataItem] = []
        if let location {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataLocationISO6709
            item.value = location as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            items.append(item)
        }
        if let creationDate {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataCreationDate
            item.value = creationDate as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            items.append(item)
        }
        writer.metadata = items
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<15 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * rowBytes + x * 4
                    base[offset] = 40; base[offset + 1] = 120; base[offset + 2] = 200; base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
    }
}

/// The file names a test importer read, in order.
private actor ReadLog {
    private(set) var names: [String] = []

    func record(_ name: String) -> Int {
        names.append(name)
        return names.count
    }
}

private struct FollowUpGeocoder: ImportGeocoder {
    func reverseGeocode(coordinate: MomentsCore.GeoPoint) async throws -> ImportGeocodeResult {
        ImportGeocodeResult(city: "Synthetic City", area: "Synthetic Area", timeZoneIdentifier: "UTC")
    }
}

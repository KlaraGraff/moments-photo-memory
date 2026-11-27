import Foundation
import SwiftData
import UniformTypeIdentifiers
import XCTest
import MomentsCore
@testable import Moments

/// Folder import beyond choosing one folder: more file formats, files and
/// folders dropped on the window, Try again after a failure, and a folder
/// that moved. All files are synthetic, in a temporary folder.
@MainActor
final class FolderImportFollowUpTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_767_225_600)

    func testTiffAndGifAreImportedAndARawBesideItsJpegIsLeftOut() async throws {
        let folder = try makeFolder()
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("synthetic-tiff.tiff"), date: date, marker: 10, type: .tiff)
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("synthetic-gif.GIF"), marker: 20, type: .gif)
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("synthetic-pair.JPG"), date: date.addingTimeInterval(60), marker: 30)
        // The RAW half of a RAW+JPEG shot. Never read, so any bytes do.
        try Data("synthetic raw".utf8).write(to: folder.appendingPathComponent("synthetic-pair.CR3"))
        try Data("synthetic note".utf8).write(to: folder.appendingPathComponent("synthetic-notes.txt"))
        let container = try MomentsPersistence.makeContainer(inMemory: true)

        let summary = try await makeImporter().importFolder(folder, container: container)

        let names = Set(try container.mainContext.fetch(FetchDescriptor<MediaItem>()).compactMap(\.originalFileName))
        XCTAssertEqual(names, ["synthetic-tiff.tiff", "synthetic-gif.GIF", "synthetic-pair.JPG"])
        XCTAssertEqual(summary.importedCount, 3)
    }

    func testDroppedFilesImportOnlyThoseFiles() async throws {
        let folder = try makeFolder()
        let files = try (1...3).map { index -> URL in
            let url = folder.appendingPathComponent("synthetic-drop-\(index).jpg")
            try SyntheticMediaFixture.writeJPEG(at: url, date: date.addingTimeInterval(Double(index) * 60), marker: index)
            return url
        }
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let controller = makeController(container)

        controller.importDropped([files[0], files[2], folder.appendingPathComponent("synthetic-missing.txt")])
        try await wait(controller) { $0.state == .finished }

        let names = Set(try container.mainContext.fetch(FetchDescriptor<MediaItem>()).compactMap(\.originalFileName))
        XCTAssertEqual(names, ["synthetic-drop-1.jpg", "synthetic-drop-3.jpg"])
        let sources = try container.mainContext.fetch(FetchDescriptor<ImportSource>())
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.locationKey, ImportSources.locationKey(for: folder))
    }

    func testDroppedFoldersAreImportedOneAfterAnother() async throws {
        let first = try makeFolder()
        let second = try makeFolder()
        try SyntheticMediaFixture.writeJPEG(at: first.appendingPathComponent("synthetic-first.jpg"), date: date, marker: 1)
        try SyntheticMediaFixture.writeJPEG(at: second.appendingPathComponent("synthetic-second.jpg"), date: date.addingTimeInterval(60), marker: 2)
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let controller = makeController(container)

        controller.importDropped([first, second])
        try await wait(controller) { $0.state == .finished }

        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<MediaItem>()), 2)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<ImportSource>()), 2)
        XCTAssertEqual(controller.progress.completed, 2)
    }

    func testDroppingNothingImportableSaysSoWithoutATryAgain() throws {
        let folder = try makeFolder()
        let note = folder.appendingPathComponent("synthetic-notes.txt")
        try Data("synthetic".utf8).write(to: note)
        let controller = makeController(try MomentsPersistence.makeContainer(inMemory: true))

        controller.importDropped([note])

        guard case .failed(let message) = controller.state else { return XCTFail("Expected a failure, got \(controller.state)") }
        XCTAssertEqual(message, FolderImportError.noSupportedFiles.localizedDescription)
        XCTAssertFalse(controller.canRetry)
    }

    func testTryAgainRunsAFailedImportAgain() async throws {
        let folder = try makeFolder()
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let controller = makeController(container)

        // Nothing to import yet: the import fails.
        controller.start(folder: folder)
        try await wait(controller) { if case .failed = $0.state { return true }; return false }
        XCTAssertTrue(controller.canRetry)

        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("synthetic-retry.jpg"), date: date, marker: 4)
        controller.resume()
        try await wait(controller) { $0.state == .finished }
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<MediaItem>()), 1)
    }

    func testAFolderMovedOnTheSameDiskIsFollowedQuietly() async throws {
        let parent = try makeFolder()
        let folder = parent.appendingPathComponent("synthetic-before", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("synthetic-moved.jpg"), date: date, marker: 5)
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let controller = makeController(container)
        controller.start(folder: folder)
        try await wait(controller) { $0.state == .finished }

        let moved = parent.appendingPathComponent("synthetic-after", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: moved)
        await controller.checkFolderLocations()

        XCTAssertEqual(controller.missingFolders, [])
        let source = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<ImportSource>()).first)
        XCTAssertEqual(source.locationKey, ImportSources.locationKey(for: moved))
    }

    func testAMissingFolderIsShownAndLocatingItRelinksItsPhotos() async throws {
        let parent = try makeFolder()
        let folder = parent.appendingPathComponent("synthetic-trip", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("synthetic-a.jpg"), date: date, marker: 6)
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("synthetic-b.jpg"), date: date.addingTimeInterval(60), marker: 7)
        let defaults = try makeDefaults()
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let controller = makeController(container, defaults: defaults)
        controller.start(folder: folder)
        try await wait(controller) { $0.state == .finished }

        // Copied to another disk and the original deleted: the bookmark
        // has nothing to follow.
        let copy = parent.appendingPathComponent("synthetic-trip-copy", isDirectory: true)
        try FileManager.default.copyItem(at: folder, to: copy)
        try FileManager.default.removeItem(at: folder)
        try SyntheticMediaFixture.writeJPEG(at: copy.appendingPathComponent("synthetic-c.jpg"), date: date.addingTimeInterval(120), marker: 8)
        await controller.checkFolderLocations()
        let missing = try XCTUnwrap(controller.missingFolders.first)
        XCTAssertEqual(controller.missingFolders.count, 1)
        XCTAssertEqual(missing.name, "synthetic-trip")

        controller.relocate(missing, to: copy)
        XCTAssertEqual(controller.missingFolders, [])
        try await wait(controller) { $0.state == .finished }

        let context = ModelContext(container)
        let items = try context.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(items.count, 3, "the moved photos are not imported twice; the new one is added")
        for item in items {
            let bookmark = try XCTUnwrap(item.originalBookmarkData)
            let resolved = try OriginalMediaBookmark.resolve(bookmark).url.standardizedFileURL
            XCTAssertEqual(resolved.deletingLastPathComponent().resolvingSymlinksInPath().path, copy.resolvingSymlinksInPath().path)
        }
        let sources = try context.fetch(FetchDescriptor<ImportSource>())
        XCTAssertEqual(sources.count, 1, "the moved folder stays one source")
        XCTAssertEqual(sources.first?.id, missing.id)
        XCTAssertEqual(sources.first?.locationKey, ImportSources.locationKey(for: copy))
        XCTAssertEqual(sources.first?.name, "synthetic-trip-copy")
        await controller.checkFolderLocations()
        XCTAssertEqual(controller.missingFolders, [])
    }

    func testAClosedMissingFolderNoteStaysClosed() async throws {
        let parent = try makeFolder()
        let folder = parent.appendingPathComponent("synthetic-gone", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("synthetic-gone.jpg"), date: date, marker: 9)
        let defaults = try makeDefaults()
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let controller = makeController(container, defaults: defaults)
        controller.start(folder: folder)
        try await wait(controller) { $0.state == .finished }
        try FileManager.default.removeItem(at: folder)

        await controller.checkFolderLocations()
        let missing = try XCTUnwrap(controller.missingFolders.first)
        controller.dismissMissingFolder(missing)
        XCTAssertEqual(controller.missingFolders, [])

        let relaunched = makeController(container, defaults: defaults)
        await relaunched.checkFolderLocations()
        XCTAssertEqual(relaunched.missingFolders, [])
    }

    // MARK: - Helpers

    private func makeFolder() throws -> URL {
        let folder = try SyntheticMediaFixture.makeFolder()
        addTeardownBlock { SyntheticMediaFixture.removeFolder(folder) }
        return folder
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "Moments-FolderImportFollowUpTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeImporter() -> FolderImporter {
        FolderImporter(
            geocoder: FollowUpSyntheticGeocoder(),
            geocodeCache: ImportGeocodeCache(),
            geocodeDelay: { true },
            timeZoneDelay: {},
            // In memory only.
            resumeStore: ImportResumeStore(directory: nil)
        )
    }

    private func makeController(_ container: ModelContainer, defaults: UserDefaults? = nil) -> ImportController {
        let controller = ImportController(
            userDefaults: defaults ?? (try? makeDefaults()) ?? .standard,
            makeImporter: { [unowned self] in self.makeImporter() }
        )
        controller.configure(container: container, startsBackgroundWork: false)
        return controller
    }

    private func wait(_ controller: ImportController, _ predicate: @escaping (ImportController) -> Bool) async throws {
        for _ in 0..<1_000 {
            if predicate(controller) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the folder import, state \(controller.state)")
    }
}

private struct FollowUpSyntheticGeocoder: ImportGeocoder {
    func reverseGeocode(coordinate: MomentsCore.GeoPoint) async throws -> ImportGeocodeResult {
        ImportGeocodeResult(city: "Synthetic City", area: "Synthetic Area", timeZoneIdentifier: "UTC")
    }
}

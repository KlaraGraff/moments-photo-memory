import CoreGraphics
import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

@MainActor
final class PhotosImportTests: XCTestCase {
    func testSyntheticAssetMetadataMapsPhotosFieldsWithoutLibraryAccess() {
        let asset = PhotosAssetDescriptor(
            localIdentifier: "synthetic-local-a",
            cloudIdentifier: "synthetic-cloud-a",
            creationDate: Date(timeIntervalSince1970: 1_767_225_600),
            location: GeoPoint(latitude: 0.01, longitude: 0.02),
            mediaType: .image,
            mediaSubtypes: [.live, .screenshot, .burst],
            duration: nil,
            pixelWidth: 1200,
            pixelHeight: 800,
            isFavorite: true,
            albumIdentifiers: ["synthetic-album-a"]
        )

        let mapped = PhotosMetadataMapper().map(asset)
        XCTAssertEqual(mapped.metadata.kind, .live)
        XCTAssertEqual(mapped.metadata.captureDateSource, .asset)
        XCTAssertEqual(mapped.metadata.timeConfidence, .exact)
        XCTAssertEqual(mapped.metadata.latitude, 0.01)
        XCTAssertEqual(mapped.metadata.longitude, 0.02)
        XCTAssertEqual(mapped.metadata.width, 1200)
        XCTAssertTrue(mapped.isScreenshot)
        XCTAssertTrue(mapped.isFavorite)
        XCTAssertTrue(mapped.asset.mediaSubtypes.contains(.burst))
        XCTAssertFalse(mapped.metadata.id.contains(asset.localIdentifier))
    }

    func testSyntheticSelectionPreviewSupportsAlbumsAndDateRange() async throws {
        let firstDate = Date(timeIntervalSince1970: 1_767_225_600)
        let source = SyntheticPhotosSource(assets: [
            PhotosAssetDescriptor(localIdentifier: "synthetic-local-a", creationDate: firstDate, mediaType: .image, pixelWidth: 10, pixelHeight: 10, albumIdentifiers: ["synthetic-album-a"]),
            PhotosAssetDescriptor(localIdentifier: "synthetic-local-b", creationDate: firstDate.addingTimeInterval(86_400), mediaType: .image, pixelWidth: 10, pixelHeight: 10, albumIdentifiers: ["synthetic-album-b"])
        ])
        let importer = PhotosImporter(source: source)

        let albumPreview = try await importer.preview(selection: .albums(["synthetic-album-a"]))
        let datePreview = try await importer.preview(selection: .dateRange(start: firstDate, end: firstDate.addingTimeInterval(1)))
        XCTAssertEqual(albumPreview.count, 1)
        XCTAssertEqual(datePreview.count, 1)
    }

    func testSyntheticPhotosImportIsIdempotentAndStoresReferences() async throws {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let source = SyntheticPhotosSource(assets: [
            PhotosAssetDescriptor(localIdentifier: "synthetic-local-a", creationDate: date, mediaType: .image, pixelWidth: 100, pixelHeight: 80),
            PhotosAssetDescriptor(localIdentifier: "synthetic-local-b", creationDate: date.addingTimeInterval(60), mediaType: .video, duration: 4, pixelWidth: 1920, pixelHeight: 1080)
        ], status: .limited)
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = PhotosImporter(source: source, geocoder: SyntheticPhotosGeocoder(), geocodeCache: ImportGeocodeCache())

        let first = try await importer.importPhotos(selection: .all, container: container)
        let second = try await importer.importPhotos(selection: .all, container: container)
        let items = try container.mainContext.fetch(FetchDescriptor<MediaItem>())

        XCTAssertEqual(first.importedCount, 2)
        XCTAssertEqual(second.importedCount, 0)
        XCTAssertEqual(second.skippedCount, 2)
        XCTAssertEqual(Set(items.compactMap(\.photosLocalIdentifier)), ["synthetic-local-a", "synthetic-local-b"])
        XCTAssertTrue(items.allSatisfy { $0.source == .photos })
        XCTAssertNil(items.first?.originalBookmarkData)
    }

    func testIncrementalRefreshDoesNotDuplicateTripsOrPlaces() async throws {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let source = SyntheticPhotosSource(assets: [
            PhotosAssetDescriptor(localIdentifier: "synthetic-local-a", creationDate: date, location: GeoPoint(latitude: 0.01, longitude: 0.02), mediaType: .image, pixelWidth: 100, pixelHeight: 80),
            PhotosAssetDescriptor(localIdentifier: "synthetic-local-b", creationDate: date.addingTimeInterval(60), location: GeoPoint(latitude: 0.01, longitude: 0.02), mediaType: .image, pixelWidth: 100, pixelHeight: 80)
        ])
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = PhotosImporter(source: source, geocoder: SyntheticPhotosGeocoder(), geocodeCache: ImportGeocodeCache())

        let first = try await importer.importPhotos(selection: .all, container: container)
        let context = container.mainContext
        let tripCount = try context.fetch(FetchDescriptor<Trip>()).count
        let placeCount = try context.fetch(FetchDescriptor<Place>()).count
        let second = try await importer.importPhotos(selection: .identifiers(["synthetic-local-a", "synthetic-local-b"]), container: container)

        XCTAssertGreaterThan(tripCount, 0)
        XCTAssertGreaterThan(placeCount, 0)
        XCTAssertEqual(first.importedCount, 2)
        XCTAssertEqual(second.tripCount, 0)
        XCTAssertEqual(second.placeCount, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).count, tripCount)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Place>()).count, placeCount)
    }

    func testIncrementalRefreshReusesOverlappingTripAndNamedPlaceClusters() async throws {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let coordinate = GeoPoint(latitude: 0.01, longitude: 0.02)
        let source = SyntheticPhotosSource(assets: [
            PhotosAssetDescriptor(localIdentifier: "synthetic-refresh-old", creationDate: date, location: coordinate, mediaType: .image, pixelWidth: 100, pixelHeight: 80)
        ])
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = PhotosImporter(source: source, geocoder: SyntheticPhotosGeocoder(), geocodeCache: ImportGeocodeCache())

        _ = try await importer.importPhotos(selection: .all, container: container)
        let context = ModelContext(container)
        let originalTrip = try XCTUnwrap(context.fetch(FetchDescriptor<Trip>()).first)
        let originalCityCount = try context.fetch(FetchDescriptor<Place>()).filter { $0.kind == .city }.count
        let originalAreaCount = try context.fetch(FetchDescriptor<Place>()).filter { $0.kind == .area }.count
        let originalPlaceCount = try context.fetch(FetchDescriptor<Place>()).count

        source.assets = [
            PhotosAssetDescriptor(localIdentifier: "synthetic-refresh-new", creationDate: date.addingTimeInterval(120), location: coordinate, mediaType: .image, pixelWidth: 100, pixelHeight: 80)
        ]
        let summary = try await importer.importPhotos(selection: .identifiers(["synthetic-refresh-new"]), container: container)

        let refreshedContext = ModelContext(container)
        let trips = try refreshedContext.fetch(FetchDescriptor<Trip>())
        let places = try refreshedContext.fetch(FetchDescriptor<Place>())
        let newItem = try XCTUnwrap(refreshedContext.fetch(FetchDescriptor<MediaItem>()).first { $0.photosLocalIdentifier == "synthetic-refresh-new" })
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(newItem.tripID, originalTrip.id)
        XCTAssertEqual(trips.first?.endDate, date.addingTimeInterval(120))
        XCTAssertEqual(places.filter { $0.kind == .city }.count, originalCityCount)
        XCTAssertEqual(places.filter { $0.kind == .area }.count, originalAreaCount)
        XCTAssertEqual(places.count, originalPlaceCount)
        XCTAssertEqual(summary.tripCount, 0)
    }

    func testIncrementalRefreshDoesNotAttachDistantAssetToConfirmedTrip() async throws {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let source = SyntheticPhotosSource(assets: [
            PhotosAssetDescriptor(
                localIdentifier: "synthetic-confirmed-old",
                creationDate: date,
                location: GeoPoint(latitude: 0.01, longitude: 0.02),
                mediaType: .image,
                pixelWidth: 100,
                pixelHeight: 80
            )
        ])
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = PhotosImporter(source: source, geocoder: SyntheticPhotosGeocoder(), geocodeCache: ImportGeocodeCache())

        _ = try await importer.importPhotos(selection: .all, container: container)
        let context = ModelContext(container)
        let confirmed = try XCTUnwrap(context.fetch(FetchDescriptor<Trip>()).first)
        confirmed.name = "Synthetic Paris"
        confirmed.suggestionStatusRaw = "confirmed"
        try context.save()

        source.assets = [
            PhotosAssetDescriptor(
                localIdentifier: "synthetic-confirmed-new",
                creationDate: date.addingTimeInterval(60 * 60),
                location: GeoPoint(latitude: 0.01, longitude: 3.5),
                mediaType: .image,
                pixelWidth: 100,
                pixelHeight: 80
            )
        ]
        _ = try await importer.importPhotos(selection: .identifiers(["synthetic-confirmed-new"]), container: container)

        let refreshed = ModelContext(container)
        let trips = try refreshed.fetch(FetchDescriptor<Trip>())
        let newItem = try XCTUnwrap(refreshed.fetch(FetchDescriptor<MediaItem>()).first { $0.photosLocalIdentifier == "synthetic-confirmed-new" })
        let original = try XCTUnwrap(trips.first { $0.id == confirmed.id })
        XCTAssertEqual(trips.count, 2)
        XCTAssertNotEqual(newItem.tripID, original.id)
        XCTAssertEqual(original.name, "Synthetic Paris")
        XCTAssertEqual(original.suggestionStatusRaw, "confirmed")
    }

    func testIncrementalRefreshPreservesUserOwnedFields() async throws {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let source = SyntheticPhotosSource(assets: [
            PhotosAssetDescriptor(localIdentifier: "synthetic-local-a", creationDate: date, location: GeoPoint(latitude: 0.01, longitude: 0.02), mediaType: .image, pixelWidth: 100, pixelHeight: 80, isFavorite: true)
        ])
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = PhotosImporter(source: source, geocoder: SyntheticPhotosGeocoder(), geocodeCache: ImportGeocodeCache())

        _ = try await importer.importPhotos(selection: .all, container: container)
        let context = container.mainContext
        let item = try XCTUnwrap(context.fetch(FetchDescriptor<MediaItem>()).first)
        let originalCaptureDate = try XCTUnwrap(item.captureDate)
        item.setFavorite(true, context: context)
        item.importReviewReasonsRaw = ImportReviewReason.nearDuplicate.rawValue
        item.reviewDecisionRaw = ImportReviewDecision.accepted.rawValue
        item.userCorrectedCaptureDateUTC = date.addingTimeInterval(86_400)
        item.localDayKey = "synthetic-corrected-day"
        item.timeZoneIdentifier = "Asia/Tokyo"
        try context.save()

        source.assets = [
            PhotosAssetDescriptor(localIdentifier: "synthetic-local-a", creationDate: nil, location: nil, mediaType: .image, pixelWidth: 100, pixelHeight: 80, isFavorite: false)
        ]
        _ = try await importer.importPhotos(selection: .identifiers(["synthetic-local-a"]), container: container)

        // The importer saves through its own context; read the result through a fresh one.
        var refreshed = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<MediaItem>()).first)
        XCTAssertEqual(refreshed.captureDate, originalCaptureDate)
        XCTAssertTrue(refreshed.isFavorite)

        // A dated refresh without location adds a reason but keeps the resolved ones.
        source.assets = [
            PhotosAssetDescriptor(localIdentifier: "synthetic-local-a", creationDate: date, location: nil, mediaType: .image, pixelWidth: 100, pixelHeight: 80, isFavorite: false)
        ]
        _ = try await importer.importPhotos(selection: .identifiers(["synthetic-local-a"]), container: container)

        refreshed = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<MediaItem>()).first)
        XCTAssertTrue(refreshed.isFavorite)
        XCTAssertTrue(refreshed.importReviewReasons.contains(.nearDuplicate))
        XCTAssertTrue(refreshed.importReviewReasons.contains(.missingLocation))
        XCTAssertEqual(refreshed.reviewDecisionRaw, ImportReviewDecision.accepted.rawValue)
        XCTAssertEqual(refreshed.captureDate, originalCaptureDate)
        XCTAssertEqual(refreshed.localDayKey, "synthetic-corrected-day")
        XCTAssertEqual(refreshed.timeZoneIdentifier, "Asia/Tokyo")
    }

    func testPhotosChangesOnlyQueueInsertedAssetsInsideLastScope() async throws {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let source = SyntheticPhotosSource(assets: [
            PhotosAssetDescriptor(localIdentifier: "synthetic-existing", creationDate: date, mediaType: .image, pixelWidth: 10, pixelHeight: 10, albumIdentifiers: ["synthetic-album-a"])
        ])
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = PhotosImporter(source: source, geocoder: SyntheticPhotosGeocoder(), geocodeCache: ImportGeocodeCache())
        let controller = PhotosImportController(importer: importer)
        controller.configure(container: container)
        controller.start(selection: .albums(["synthetic-album-a"]))
        try await waitForController(controller) { $0.state == .finished }

        source.assets += [
            PhotosAssetDescriptor(localIdentifier: "synthetic-in-scope", creationDate: date.addingTimeInterval(60), mediaType: .image, pixelWidth: 10, pixelHeight: 10, albumIdentifiers: ["synthetic-album-a"]),
            PhotosAssetDescriptor(localIdentifier: "synthetic-out-of-scope", creationDate: date.addingTimeInterval(60), mediaType: .image, pixelWidth: 10, pixelHeight: 10, albumIdentifiers: ["synthetic-album-b"])
        ]
        let event = PhotosChangeEvent(
            insertedLocalIdentifiers: ["synthetic-in-scope", "synthetic-out-of-scope"],
            changedLocalIdentifiers: ["synthetic-out-of-scope"]
        )
        XCTAssertEqual(event.newAssetCount, 2)
        source.emit(event)
        try await waitForController(controller) { !$0.pendingNewAssetIdentifiers.isEmpty }

        XCTAssertEqual(controller.pendingNewAssetIdentifiers, ["synthetic-in-scope"])

        let dateSource = SyntheticPhotosSource(assets: [
            PhotosAssetDescriptor(localIdentifier: "synthetic-date-existing", creationDate: date, mediaType: .image, pixelWidth: 10, pixelHeight: 10)
        ])
        let dateContainer = try MomentsPersistence.makeContainer(inMemory: true)
        let dateImporter = PhotosImporter(source: dateSource, geocoder: SyntheticPhotosGeocoder(), geocodeCache: ImportGeocodeCache())
        let dateController = PhotosImportController(importer: dateImporter)
        dateController.configure(container: dateContainer)
        let end = date.addingTimeInterval(3_600)
        dateController.start(selection: .dateRange(start: date, end: end))
        try await waitForController(dateController) { $0.state == .finished }
        dateSource.assets += [
            PhotosAssetDescriptor(localIdentifier: "synthetic-date-in-scope", creationDate: date.addingTimeInterval(120), mediaType: .image, pixelWidth: 10, pixelHeight: 10),
            PhotosAssetDescriptor(localIdentifier: "synthetic-date-out-of-scope", creationDate: date.addingTimeInterval(7_200), mediaType: .image, pixelWidth: 10, pixelHeight: 10)
        ]
        dateSource.emit(PhotosChangeEvent(insertedLocalIdentifiers: ["synthetic-date-in-scope", "synthetic-date-out-of-scope"]))
        try await waitForController(dateController) { !$0.pendingNewAssetIdentifiers.isEmpty }
        XCTAssertEqual(dateController.pendingNewAssetIdentifiers, ["synthetic-date-in-scope"])
    }

    func testPhotosChangesKeepBatchWhenAnotherEventArrivesDuringScopeCheck() async throws {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let source = SyntheticPhotosSource(assets: [
            PhotosAssetDescriptor(localIdentifier: "synthetic-scope-existing", creationDate: date, mediaType: .image, pixelWidth: 10, pixelHeight: 10, albumIdentifiers: ["synthetic-scope-album"])
        ])
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = PhotosImporter(source: source, geocoder: SyntheticPhotosGeocoder(), geocodeCache: ImportGeocodeCache())
        let controller = PhotosImportController(importer: importer)
        controller.configure(container: container)
        controller.start(selection: .albums(["synthetic-scope-album"]))
        try await waitForController(controller) { $0.state == .finished }

        source.assets += [
            PhotosAssetDescriptor(localIdentifier: "synthetic-scope-first", creationDate: date.addingTimeInterval(60), mediaType: .image, pixelWidth: 10, pixelHeight: 10, albumIdentifiers: ["synthetic-scope-album"]),
            PhotosAssetDescriptor(localIdentifier: "synthetic-scope-second", creationDate: date.addingTimeInterval(120), mediaType: .image, pixelWidth: 10, pixelHeight: 10, albumIdentifiers: ["synthetic-scope-album"])
        ]
        source.identifierFetchDelayNanoseconds = 300_000_000
        source.emit(PhotosChangeEvent(insertedLocalIdentifiers: ["synthetic-scope-first"]))
        try await waitForController(controller) { _ in source.identifierFetchStarted }
        source.emit(PhotosChangeEvent(insertedLocalIdentifiers: ["synthetic-scope-second"]))

        try await waitForController(controller) {
            $0.pendingNewAssetIdentifiers == ["synthetic-scope-first", "synthetic-scope-second"]
        }
    }

    func testLastImportScopeRestoresWithoutPersistingAssetIdentifiers() async throws {
        let suiteName = "Moments-PhotosImportTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let source = SyntheticPhotosSource(assets: [
            PhotosAssetDescriptor(localIdentifier: "synthetic-persisted-old", creationDate: date, mediaType: .image, pixelWidth: 10, pixelHeight: 10, albumIdentifiers: ["synthetic-persisted-album"])
        ])
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = PhotosImporter(source: source, geocoder: SyntheticPhotosGeocoder(), geocodeCache: ImportGeocodeCache())
        let firstController = PhotosImportController(importer: importer, userDefaults: defaults)
        firstController.configure(container: container)
        firstController.start(selection: .albums(["synthetic-persisted-album"]))
        try await waitForController(firstController) { $0.state == .finished }

        let secondController = PhotosImportController(importer: importer, userDefaults: defaults)
        secondController.configure(container: container)
        await secondController.requestAccess()
        source.assets.append(PhotosAssetDescriptor(localIdentifier: "synthetic-persisted-new", creationDate: date.addingTimeInterval(60), mediaType: .image, pixelWidth: 10, pixelHeight: 10, albumIdentifiers: ["synthetic-persisted-album"]))
        source.emit(PhotosChangeEvent(insertedLocalIdentifiers: ["synthetic-persisted-new"]))
        try await waitForController(secondController) { $0.pendingNewAssetIdentifiers == ["synthetic-persisted-new"] }

        let persisted = try XCTUnwrap(defaults.data(forKey: "Moments.photosImport.lastScope"))
        let persistedText = String(decoding: persisted, as: UTF8.self)
        XCTAssertTrue(persistedText.contains("synthetic-persisted-album"))
        XCTAssertFalse(persistedText.contains("synthetic-persisted-old"))
        XCTAssertFalse(persistedText.contains("synthetic-persisted-new"))
    }

    func testPendingPhotoChangesRemainAfterFailedImport() async throws {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let source = SyntheticPhotosSource(assets: [
            PhotosAssetDescriptor(localIdentifier: "synthetic-existing", creationDate: date, mediaType: .image, pixelWidth: 10, pixelHeight: 10)
        ])
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = PhotosImporter(source: source, geocoder: SyntheticPhotosGeocoder(), geocodeCache: ImportGeocodeCache())
        let controller = PhotosImportController(importer: importer)
        controller.configure(container: container)
        controller.start(selection: .all)
        try await waitForController(controller) { $0.state == .finished }

        source.assets.append(PhotosAssetDescriptor(localIdentifier: "synthetic-new", creationDate: date.addingTimeInterval(60), mediaType: .image, pixelWidth: 10, pixelHeight: 10))
        source.emit(PhotosChangeEvent(insertedLocalIdentifiers: ["synthetic-new"]))
        try await waitForController(controller) { $0.pendingNewAssetIdentifiers == ["synthetic-new"] }
        source.failIdentifierFetch = true
        controller.importPendingChanges()
        try await waitForController(controller) { if case .failed = $0.state { return true }; return false }

        XCTAssertEqual(controller.pendingNewAssetIdentifiers, ["synthetic-new"])
    }

    func testPendingPhotoChangesArePrunedAndNoAssetsRefreshSucceeds() async throws {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let source = SyntheticPhotosSource(assets: [
            PhotosAssetDescriptor(localIdentifier: "synthetic-existing", creationDate: date, mediaType: .image, pixelWidth: 10, pixelHeight: 10)
        ])
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = PhotosImporter(source: source, geocoder: SyntheticPhotosGeocoder(), geocodeCache: ImportGeocodeCache())
        let controller = PhotosImportController(importer: importer)
        controller.configure(container: container)
        controller.start(selection: .all)
        try await waitForController(controller) { $0.state == .finished }

        source.assets.append(PhotosAssetDescriptor(localIdentifier: "synthetic-pending", creationDate: date.addingTimeInterval(60), mediaType: .image, pixelWidth: 10, pixelHeight: 10))
        source.emit(PhotosChangeEvent(insertedLocalIdentifiers: ["synthetic-pending"]))
        try await waitForController(controller) { $0.pendingNewAssetIdentifiers == ["synthetic-pending"] }
        source.assets = []
        controller.importPendingChanges()
        try await waitForController(controller) { $0.state == .finished && $0.pendingNewAssetIdentifiers.isEmpty }

        source.assets = [PhotosAssetDescriptor(localIdentifier: "synthetic-deleted-pending", creationDate: date.addingTimeInterval(120), mediaType: .image, pixelWidth: 10, pixelHeight: 10)]
        source.emit(PhotosChangeEvent(insertedLocalIdentifiers: ["synthetic-deleted-pending"]))
        try await waitForController(controller) { $0.pendingNewAssetIdentifiers == ["synthetic-deleted-pending"] }
        source.assets = []
        source.emit(PhotosChangeEvent(deletedLocalIdentifiers: ["synthetic-deleted-pending"]))
        try await waitForController(controller) { $0.pendingNewAssetIdentifiers.isEmpty }
        XCTAssertEqual(controller.pendingDeletedAssetCount, 1)
    }

    func testFolderOverlapIsAReviewCandidateAndNeverMerged() async throws {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        context.insert(MediaItem(
            id: "synthetic-folder-item",
            captureDate: date,
            latitude: 0.01,
            longitude: 0.02,
            width: 100,
            height: 80,
            source: .file,
            title: "synthetic-folder.jpg"
        ))
        try context.save()

        let source = SyntheticPhotosSource(assets: [
            PhotosAssetDescriptor(localIdentifier: "synthetic-local-a", creationDate: date.addingTimeInterval(0.5), location: GeoPoint(latitude: 0.01, longitude: 0.02), mediaType: .image, pixelWidth: 100, pixelHeight: 80)
        ])
        let importer = PhotosImporter(source: source, geocoder: SyntheticPhotosGeocoder(), geocodeCache: ImportGeocodeCache())
        let summary = try await importer.importPhotos(selection: .all, container: container)
        let items = try context.fetch(FetchDescriptor<MediaItem>())

        XCTAssertEqual(summary.importedCount, 1)
        XCTAssertTrue(summary.flags.first?.reasons.contains(.nearDuplicate) == true)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.filter { $0.source == .photos }.count, 1)
    }

    func testDeletedAssetIsMarkedMissingWithoutDeletingTheMediaItem() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        context.insert(MediaItem(id: "synthetic-photos-item", source: .photos, photosLocalIdentifier: "synthetic-local-a"))
        try context.save()
        let importer = PhotosImporter(source: SyntheticPhotosSource(assets: []))

        XCTAssertEqual(try importer.markMissing(localIdentifiers: ["synthetic-local-a"], in: container), 1)
        let item = try context.fetch(FetchDescriptor<MediaItem>()).first
        XCTAssertEqual(item?.photosAssetMissing, true)
    }
}

@MainActor
private func waitForController(
    _ controller: PhotosImportController,
    _ predicate: @escaping (PhotosImportController) -> Bool
) async throws {
    for _ in 0..<200 {
        if predicate(controller) { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for Photos import controller")
}

private final class SyntheticPhotosSource: PhotosAssetSource {
    var assets: [PhotosAssetDescriptor]
    var status: PhotosAuthorizationStatus
    var failIdentifierFetch = false
    var identifierFetchDelayNanoseconds: UInt64 = 0
    var identifierFetchStarted = false
    private var changeHandler: (@Sendable (PhotosChangeEvent) -> Void)?

    init(assets: [PhotosAssetDescriptor], status: PhotosAuthorizationStatus = .authorized) {
        self.assets = assets
        self.status = status
    }

    var authorizationStatus: PhotosAuthorizationStatus { status }

    func requestAuthorization() async -> PhotosAuthorizationStatus { status }

    func fetchAlbums() async throws -> [PhotosAlbumDescriptor] { [] }

    func fetchAssets(selection: PhotosImportSelection) async throws -> [PhotosAssetDescriptor] {
        switch selection {
        case .all: return assets
        case .identifiers(let ids):
            if failIdentifierFetch { throw SyntheticPhotosSourceError.failed }
            identifierFetchStarted = true
            if identifierFetchDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: identifierFetchDelayNanoseconds)
            }
            return assets.filter { ids.contains($0.localIdentifier) }
        case .albums(let ids): return assets.filter { !$0.albumIdentifiers.filter(ids.contains).isEmpty }
        case .dateRange(let start, let end): return assets.filter { asset in
            guard let date = asset.creationDate else { return false }
            return date >= start && date <= end
        }
        }
    }

    func observeChanges(_ handler: @escaping @Sendable (PhotosChangeEvent) -> Void) -> any PhotosChangeObservation {
        changeHandler = handler
        return SyntheticObservation()
    }

    func emit(_ event: PhotosChangeEvent) {
        changeHandler?(event)
    }

    func thumbnailData(forLocalIdentifier localIdentifier: String, targetSize: CGSize, networkAccessAllowed: Bool) async throws -> Data? {
        nil
    }

    func thumbnailImage(forLocalIdentifier localIdentifier: String, targetSize: CGSize, networkAccessAllowed: Bool) async -> CGImage? {
        nil
    }
}

private enum SyntheticPhotosSourceError: Error {
    case failed
}

private final class SyntheticObservation: PhotosChangeObservation {
    func invalidate() {}
}

private struct SyntheticPhotosGeocoder: ImportGeocoder {
    func reverseGeocode(coordinate: GeoPoint) async throws -> ImportGeocodeResult {
        ImportGeocodeResult(city: "Synthetic City", area: "Synthetic Area", timeZoneIdentifier: "UTC")
    }
}

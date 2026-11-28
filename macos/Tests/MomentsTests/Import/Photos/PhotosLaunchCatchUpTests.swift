import CoreGraphics
import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// What Moments finds out about Apple Photos when it opens: photos added or
/// deleted while it was closed, and a library restored on another Mac. All
/// data is synthetic; the Photos library is a fake source.
@MainActor
final class PhotosLaunchCatchUpTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_767_225_600)

    func testLaunchOffersPhotosAddedWhileClosedInsideTheLastScope() async throws {
        let defaults = try makeDefaults()
        let source = LaunchPhotosSource(assets: [asset("synthetic-launch-old", album: "synthetic-album-a")])
        source.token = token("t1")
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let first = makeController(source, defaults: defaults, container: container)
        first.start(selection: .albums(["synthetic-album-a"]))
        try await wait(first) { $0.state == .finished }
        XCTAssertEqual(defaults.data(forKey: Self.tokenKey), token("t1"))

        // Moments is closed; two photos arrive, one outside the imported album.
        source.assets += [
            asset("synthetic-launch-in-scope", album: "synthetic-album-a", offset: 60),
            asset("synthetic-launch-out-of-scope", album: "synthetic-album-b", offset: 60)
        ]
        source.token = token("t2")
        source.historyResult = PhotosHistory(
            batches: [PhotosChangeBatch(inserted: ["synthetic-launch-in-scope", "synthetic-launch-out-of-scope"])],
            token: token("t2")
        )

        let relaunched = makeController(source, defaults: defaults, container: container)
        await relaunched.catchUpAtLaunch()
        XCTAssertEqual(source.historyTokens, [token("t1")])
        XCTAssertEqual(relaunched.pendingNewAssetIdentifiers, ["synthetic-launch-in-scope"])
        // Nothing waiting may be skipped next time: the token stays put.
        XCTAssertEqual(defaults.data(forKey: Self.tokenKey), token("t1"))

        relaunched.importPendingChanges()
        try await wait(relaunched) { $0.state == .finished }
        XCTAssertTrue(relaunched.pendingNewAssetIdentifiers.isEmpty)
        XCTAssertEqual(defaults.data(forKey: Self.tokenKey), token("t2"))
        XCTAssertEqual(relaunched.summary?.importedCount, 1)
    }

    func testFirstLaunchWithoutATokenOffersNothingAndSavesOne() async throws {
        let defaults = try makeDefaults()
        let source = LaunchPhotosSource(assets: [asset("synthetic-baseline", album: nil)])
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let first = makeController(source, defaults: defaults, container: container)
        first.start(selection: .all)
        try await wait(first) { $0.state == .finished }
        // A version of Moments from before change tokens: none was saved.
        defaults.removeObject(forKey: Self.tokenKey)
        source.token = token("t-baseline")

        let relaunched = makeController(source, defaults: defaults, container: container)
        await relaunched.catchUpAtLaunch()
        XCTAssertTrue(source.historyTokens.isEmpty)
        XCTAssertTrue(relaunched.pendingNewAssetIdentifiers.isEmpty)
        XCTAssertEqual(relaunched.missingAssetCount, 0)
        XCTAssertEqual(defaults.data(forKey: Self.tokenKey), token("t-baseline"))
    }

    func testLaunchNeverAsksForAccess() async throws {
        let defaults = try makeDefaults()
        let source = LaunchPhotosSource(assets: [asset("synthetic-never", album: nil)])
        source.token = token("t1")
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let first = makeController(source, defaults: defaults, container: container)
        first.start(selection: .all)
        try await wait(first) { $0.state == .finished }
        let requestsAfterImport = source.authorizationRequests

        // Photos access was taken back while Moments was closed.
        source.status = .denied
        let relaunched = makeController(source, defaults: defaults, container: container)
        await relaunched.catchUpAtLaunch()
        XCTAssertEqual(source.authorizationRequests, requestsAfterImport)
        XCTAssertTrue(source.historyTokens.isEmpty)
    }

    func testLaunchDoesNothingBeforeAnyImport() async throws {
        let defaults = try makeDefaults()
        let source = LaunchPhotosSource(assets: [asset("synthetic-never", album: nil)])
        source.token = token("t1")
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let controller = makeController(source, defaults: defaults, container: container)
        await controller.catchUpAtLaunch()
        XCTAssertEqual(source.authorizationRequests, 0)
        XCTAssertTrue(source.historyTokens.isEmpty)
        XCTAssertNil(defaults.data(forKey: Self.tokenKey))
    }

    func testPhotosDeletedWhileClosedAreMarkedAndTheNoticeCanBeClosed() async throws {
        let defaults = try makeDefaults()
        let source = LaunchPhotosSource(assets: [
            asset("synthetic-keep", album: nil),
            asset("synthetic-gone-a", album: nil, offset: 60),
            asset("synthetic-gone-b", album: nil, offset: 120)
        ])
        source.token = token("t1")
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let first = makeController(source, defaults: defaults, container: container)
        first.start(selection: .all)
        try await wait(first) { $0.state == .finished }
        XCTAssertFalse(first.showsMissingNotice)

        source.assets.removeAll { $0.localIdentifier.hasPrefix("synthetic-gone") }
        source.historyResult = PhotosHistory(
            batches: [PhotosChangeBatch(deleted: ["synthetic-gone-a"]), PhotosChangeBatch(deleted: ["synthetic-gone-b"])],
            token: token("t2")
        )
        let relaunched = makeController(source, defaults: defaults, container: container)
        await relaunched.catchUpAtLaunch()

        XCTAssertEqual(relaunched.missingAssetCount, 2)
        XCTAssertTrue(relaunched.showsMissingNotice)
        XCTAssertTrue(source.cloudLookups.isEmpty, "two deletions are not another Mac")
        let items = try ModelContext(container).fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(items.count, 3, "a photo deleted in Photos stays in the library")
        XCTAssertEqual(Set(items.filter { $0.photosAssetMissing == true }.compactMap(\.photosLocalIdentifier)), ["synthetic-gone-a", "synthetic-gone-b"])
        XCTAssertEqual(defaults.data(forKey: Self.tokenKey), token("t2"))

        relaunched.dismissMissingNotice()
        XCTAssertFalse(relaunched.showsMissingNotice)
        // Closed stays closed after the next launch, until another photo goes.
        let again = makeController(source, defaults: defaults, container: container)
        source.historyResult = PhotosHistory(batches: [], token: token("t2"))
        await again.catchUpAtLaunch()
        XCTAssertEqual(again.missingAssetCount, 2)
        XCTAssertFalse(again.showsMissingNotice)
        XCTAssertTrue(source.cloudLookups.isEmpty, "photos already marked are not another Mac")

        source.assets.removeAll()
        source.emit(PhotosChangeEvent(deletedLocalIdentifiers: ["synthetic-keep"]))
        try await wait(again) { $0.missingAssetCount == 3 }
        XCTAssertTrue(again.showsMissingNotice)
    }

    func testALibraryRestoredOnAnotherMacIsRelinkedThroughTheCloudIdentifier() async throws {
        let defaults = try makeDefaults()
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        // The library as the old Mac imported it.
        let oldMac = LaunchPhotosSource(assets: [
            asset("old-mac/a", album: nil, cloud: "cloud-a"),
            asset("old-mac/b", album: nil, offset: 60, cloud: "cloud-b"),
            asset("old-mac/c", album: nil, offset: 120, cloud: "cloud-c")
        ])
        oldMac.token = token("old-mac")
        let onOldMac = makeController(oldMac, defaults: defaults, container: container)
        onOldMac.start(selection: .all)
        try await wait(onOldMac) { $0.state == .finished }
        XCTAssertEqual(onOldMac.summary?.importedCount, 3)

        // This Mac's Photos has a and b under new identifiers; c is not here.
        let source = LaunchPhotosSource(assets: [
            asset("new-mac/a", album: nil, cloud: "cloud-a"),
            asset("new-mac/b", album: nil, offset: 60, cloud: "cloud-b"),
            asset("new-mac/new", album: nil, offset: 180, cloud: "cloud-new")
        ])
        source.token = token("new-mac")
        source.cloudMap = ["cloud-a": "new-mac/a", "cloud-b": "new-mac/b", "cloud-new": "new-mac/new"]
        // The old Mac's token means nothing here.
        source.historyResult = nil

        let controller = makeController(source, defaults: defaults, container: container)
        await controller.catchUpAtLaunch()

        XCTAssertEqual(source.historyTokens, [token("old-mac")])
        XCTAssertEqual(source.cloudLookups, [["cloud-a", "cloud-b", "cloud-c"]])
        XCTAssertEqual(controller.relinkedCount, 2)
        let items = try Dictionary(uniqueKeysWithValues: ModelContext(container).fetch(FetchDescriptor<MediaItem>()).compactMap { item in
            item.photosCloudIdentifier.map { ($0, item) }
        })
        XCTAssertEqual(items["cloud-a"]?.photosLocalIdentifier, "new-mac/a")
        XCTAssertEqual(items["cloud-b"]?.photosLocalIdentifier, "new-mac/b")
        XCTAssertNotEqual(items["cloud-a"]?.photosAssetMissing, true)
        XCTAssertEqual(items["cloud-c"]?.photosAssetMissing, true)
        XCTAssertEqual(controller.missingAssetCount, 1)
        XCTAssertEqual(defaults.data(forKey: Self.tokenKey), token("new-mac"))

        // Importing everything again finds the relinked photos already there.
        controller.start(selection: .all)
        try await wait(controller) { $0.state == .finished }
        XCTAssertEqual(controller.summary?.importedCount, 1)
        XCTAssertEqual(controller.summary?.skippedCount, 2)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<MediaItem>()), 4)

        controller.dismissRelinked()
        XCTAssertEqual(controller.relinkedCount, 0)
    }

    func testAFewDeletionsDoNotStartAFullComparison() async throws {
        let defaults = try makeDefaults()
        let source = LaunchPhotosSource(assets: (0..<10).map { asset("synthetic-many-\($0)", album: nil, offset: Double($0) * 60) })
        source.token = token("t1")
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let first = makeController(source, defaults: defaults, container: container)
        first.start(selection: .all)
        try await wait(first) { $0.state == .finished }

        source.assets.removeAll { $0.localIdentifier == "synthetic-many-3" }
        source.historyResult = PhotosHistory(batches: [PhotosChangeBatch(deleted: ["synthetic-many-3"])], token: token("t2"))
        let relaunched = makeController(source, defaults: defaults, container: container)
        await relaunched.catchUpAtLaunch()

        XCTAssertTrue(source.cloudLookups.isEmpty)
        XCTAssertEqual(relaunched.relinkedCount, 0)
        XCTAssertEqual(relaunched.missingAssetCount, 1)
    }

    func testAFailedImportStaysInTheStatusBarAndTryAgainRunsItAgain() async throws {
        let defaults = try makeDefaults()
        let source = LaunchPhotosSource(assets: [asset("synthetic-retry", album: nil)])
        source.failFetch = true
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let controller = makeController(source, defaults: defaults, container: container)
        controller.start(selection: .all)
        try await wait(controller) { if case .failed = $0.state { return true }; return false }
        XCTAssertTrue(controller.showsResult)
        XCTAssertTrue(PhotosImportStatusRows.hasContent(controller))

        source.failFetch = false
        controller.retry()
        try await wait(controller) { $0.state == .finished }
        XCTAssertTrue(controller.showsResult)
        XCTAssertEqual(controller.summary?.importedCount, 1)

        controller.dismissResult()
        XCTAssertFalse(controller.showsResult)
        XCTAssertFalse(PhotosImportStatusRows.hasContent(controller))
    }

    // MARK: - Helpers

    private static let tokenKey = "Moments.photosImport.changeToken"

    private func makeDefaults() throws -> UserDefaults {
        let name = "Moments-PhotosLaunchCatchUpTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeController(_ source: LaunchPhotosSource, defaults: UserDefaults, container: ModelContainer) -> PhotosImportController {
        let importer = PhotosImporter(source: source, geocoder: LaunchSyntheticGeocoder(), geocodeCache: ImportGeocodeCache())
        let controller = PhotosImportController(importer: importer, userDefaults: defaults)
        controller.configure(container: container)
        return controller
    }

    private func asset(_ id: String, album: String?, offset: TimeInterval = 0, cloud: String? = nil) -> PhotosAssetDescriptor {
        PhotosAssetDescriptor(
            localIdentifier: id,
            cloudIdentifier: cloud,
            creationDate: date.addingTimeInterval(offset),
            mediaType: .image,
            pixelWidth: 10,
            pixelHeight: 10,
            albumIdentifiers: album.map { [$0] } ?? []
        )
    }

    private func token(_ value: String) -> Data { Data("synthetic-token-\(value)".utf8) }

    private func wait(
        _ controller: PhotosImportController,
        _ predicate: @escaping (PhotosImportController) -> Bool
    ) async throws {
        for _ in 0..<300 {
            if predicate(controller) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the Photos import controller")
    }
}

/// A fake Photos library with a change history and cloud identifiers.
private final class LaunchPhotosSource: PhotosAssetSource {
    var assets: [PhotosAssetDescriptor]
    var status: PhotosAuthorizationStatus
    var token: Data?
    /// What `history(since:)` returns; `nil` throws, as for a token Photos
    /// no longer knows.
    var historyResult: PhotosHistory?
    var cloudMap: [String: String] = [:]
    var failFetch = false
    private(set) var historyTokens: [Data] = []
    private(set) var cloudLookups: [[String]] = []
    private(set) var authorizationRequests = 0
    private var changeHandler: (@Sendable (PhotosChangeEvent) -> Void)?

    init(assets: [PhotosAssetDescriptor], status: PhotosAuthorizationStatus = .authorized) {
        self.assets = assets
        self.status = status
    }

    var authorizationStatus: PhotosAuthorizationStatus { status }

    func requestAuthorization() async -> PhotosAuthorizationStatus {
        authorizationRequests += 1
        return status
    }

    func fetchAssets(selection: PhotosImportSelection) async throws -> [PhotosAssetDescriptor] {
        if failFetch { throw LaunchSyntheticError.failed }
        switch selection {
        case .all: return assets
        case .identifiers(let ids):
            let wanted = Set(ids)
            return assets.filter { wanted.contains($0.localIdentifier) }
        case .albums(let ids): return assets.filter { !$0.albumIdentifiers.filter(ids.contains).isEmpty }
        case .dateRange(let start, let end): return assets.filter { asset in
            guard let date = asset.creationDate else { return false }
            return date >= start && date <= end
        }
        }
    }

    func observeChanges(_ handler: @escaping @Sendable (PhotosChangeEvent) -> Void) -> any PhotosChangeObservation {
        changeHandler = handler
        return LaunchSyntheticObservation()
    }

    func emit(_ event: PhotosChangeEvent) {
        changeHandler?(event)
    }

    func thumbnailData(forLocalIdentifier localIdentifier: String, targetSize: CGSize, networkAccessAllowed: Bool) async throws -> Data? {
        nil
    }

    func currentChangeToken() -> Data? { token }

    func history(since token: Data) async throws -> PhotosHistory {
        historyTokens.append(token)
        guard let historyResult else { throw PhotosHistoryError.unavailable }
        return historyResult
    }

    func localIdentifiers(forCloudIdentifiers identifiers: [String]) async -> [String: String] {
        cloudLookups.append(identifiers)
        return cloudMap.filter { identifiers.contains($0.key) }
    }
}

private enum LaunchSyntheticError: Error {
    case failed
}

private final class LaunchSyntheticObservation: PhotosChangeObservation {
    func invalidate() {}
}

private struct LaunchSyntheticGeocoder: ImportGeocoder {
    func reverseGeocode(coordinate: GeoPoint) async throws -> ImportGeocodeResult {
        ImportGeocodeResult(city: "Synthetic City", area: "Synthetic Area", timeZoneIdentifier: "UTC")
    }
}

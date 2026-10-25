import Foundation
import SwiftData
import XCTest
@testable import Moments

@MainActor
final class PhotosSchemaMigrationTests: XCTestCase {
    func testSyntheticV3StoreMigratesToV4AndKeepsPhotosFieldsOptional() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "moments-v3-v4-\(UUID().uuidString)", directoryHint: .isDirectory)
        let storeURL = folder.appending(path: "Moments.store")
        defer { try? FileManager.default.removeItem(at: folder) }

        let legacy = try MomentsPersistence.makeV3Container(url: storeURL)
        let oldContext = legacy.mainContext
        oldContext.insert(SchemaV3.MediaItem(id: "synthetic-v3-item", title: "Synthetic item"))
        try oldContext.save()

        let current = try MomentsPersistence.makeContainer(url: storeURL)
        let items = try current.mainContext.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items.first?.photosLocalIdentifier)
        XCTAssertNil(items.first?.photosCloudIdentifier)
        XCTAssertNil(items.first?.perceptualHash)
    }
}

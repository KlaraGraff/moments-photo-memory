import Foundation
import SwiftData
import XCTest
@testable import Moments

@MainActor
final class SchemaMigrationTests: XCTestCase {
    func testFrozenSchemaV2StoreMigratesToV3AndLeavesImportFieldsNil() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moments-schema-v2-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Moments.store")
        defer {
            try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(atPath: storeURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: storeURL.path + "-wal")
        }

        let v2Container = try MomentsPersistence.makeV2Container(url: storeURL)
        let v2Context = v2Container.mainContext
        v2Context.insert(SchemaV2.MediaItem(id: "frozen-v2-item", title: "Synthetic V2 item"))
        try v2Context.save()

        let v3Container = try MomentsPersistence.makeContainer(url: storeURL)
        let migrated = try v3Container.mainContext.fetch(FetchDescriptor<MediaItem>())

        XCTAssertEqual(migrated.map(\.id), ["frozen-v2-item"])
        XCTAssertNil(migrated.first?.originalBookmarkData)
        XCTAssertNil(migrated.first?.originalFileName)
        XCTAssertNil(migrated.first?.originalContentHash)
        XCTAssertNil(migrated.first?.originalCaptureDateUTC)
        XCTAssertNil(migrated.first?.captureDateHintUTC)
        XCTAssertNil(migrated.first?.localDayKey)
        XCTAssertNil(migrated.first?.timeZoneIdentifier)
        XCTAssertNil(migrated.first?.timeConfidenceRaw)
        XCTAssertNil(migrated.first?.sourceReferencesRaw)
        XCTAssertNil(migrated.first?.pairedVideoContentHash)
        XCTAssertNil(migrated.first?.pairedVideoBookmarkData)
        XCTAssertNil(migrated.first?.importReviewReasonsRaw)
        XCTAssertNil(migrated.first?.reviewDecisionRaw)
        XCTAssertNil(migrated.first?.duration)
    }
}

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

extension SchemaMigrationTests {
    func testFrozenSchemaV5StoreMigratesToV6AndAddsEmptyPeopleTables() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "moments-v5-v6-\(UUID().uuidString)", directoryHint: .isDirectory)
        let storeURL = folder.appending(path: "Moments.store")
        defer { try? FileManager.default.removeItem(at: folder) }

        let legacy = try MomentsPersistence.makeV5Container(url: storeURL)
        let oldContext = legacy.mainContext
        oldContext.insert(SchemaV5.MediaItem(id: "frozen-v5-item", title: "Synthetic V5 item"))
        oldContext.insert(SchemaV5.UserGroup(id: "frozen-v5-group", name: "Synthetic group"))
        try oldContext.save()

        let current = try MomentsPersistence.makeContainer(url: storeURL)
        let items = try current.mainContext.fetch(FetchDescriptor<MediaItem>())
        let groups = try current.mainContext.fetch(FetchDescriptor<UserGroup>())
        XCTAssertEqual(items.map(\.id), ["frozen-v5-item"])
        XCTAssertEqual(groups.map(\.id), ["frozen-v5-group"])
        XCTAssertTrue(try current.mainContext.fetch(FetchDescriptor<Person>()).isEmpty)
        XCTAssertTrue(try current.mainContext.fetch(FetchDescriptor<FaceObservation>()).isEmpty)
    }
}

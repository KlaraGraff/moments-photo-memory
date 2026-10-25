import Foundation
import SwiftData
import XCTest
@testable import Moments

@MainActor
final class MomentsTests: XCTestCase {
    func testMediaMemoryRelationship() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let item = MediaItem(id: "relationship-demo", title: "Relationship demo")
        let memory = Memory(text: "A shared synthetic memory", author: .partner, mediaItem: item)
        context.insert(item)
        context.insert(memory)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(fetched.first?.memories.first?.text, "A shared synthetic memory")
        XCTAssertEqual(fetched.first?.memories.first?.author, .partner)
        XCTAssertTrue(fetched.first?.memories.first?.mediaItem === fetched.first)
    }

    func testDemoSeedingCreatesSyntheticItemsAndRelationships() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let url = repositoryRoot().appendingPathComponent("demo/sample-data.json")
        try DemoSeeder.seedIfNeeded(context: context, data: Data(contentsOf: url))

        let items = try context.fetch(FetchDescriptor<MediaItem>())
        let trips = try context.fetch(FetchDescriptor<Trip>())
        let tags = try context.fetch(FetchDescriptor<Tag>())
        let memories = try context.fetch(FetchDescriptor<Memory>())
        XCTAssertEqual(items.count, 27)
        XCTAssertEqual(trips.count, 2)
        XCTAssertGreaterThan(tags.count, 0)
        XCTAssertTrue(tags.allSatisfy { !$0.items.isEmpty })
        XCTAssertEqual(items.first?.source, .demo)
        XCTAssertEqual(memories.count, 1)
        XCTAssertFalse(trips.allSatisfy { $0.items.isEmpty })
        XCTAssertTrue(items.allSatisfy { $0.latitude == nil || (0...0.02).contains($0.latitude!) })
    }

    func testMemorySurvivesModelContainerReopen() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moments-model-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        do {
            let container = try MomentsPersistence.makeContainer(url: storeURL)
            let context = container.mainContext
            let item = MediaItem(id: "reopen-demo", title: "Reopen demo")
            context.insert(item)
            context.insert(Memory(text: "Persisted across a reopen", mediaItem: item))
            try context.save()
        }
        do {
            let reopened = try MomentsPersistence.makeContainer(url: storeURL)
            let memories = try reopened.mainContext.fetch(FetchDescriptor<Memory>())
            XCTAssertEqual(memories.count, 1)
            XCTAssertEqual(memories.first?.text, "Persisted across a reopen")
            XCTAssertEqual(memories.first?.mediaItem?.id, "reopen-demo")
        }
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }
}

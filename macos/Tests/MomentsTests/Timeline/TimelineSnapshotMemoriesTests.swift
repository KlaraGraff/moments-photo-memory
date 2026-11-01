import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// The Timeline and Chapters pages group every `Memory` into one dictionary
/// instead of reading `item.memories` per photo. The grouped path must build
/// exactly the snippets the relationship path builds.
@MainActor
final class TimelineSnapshotMemoriesTests: XCTestCase {
    func testGroupedMemoriesBuildTheSameSnippetsAsTheRelationship() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let inserted = Self.insertPhotos(30, in: context)
        Self.insertMemories(for: inserted, in: context)
        try context.save()

        // Read the photos back, so `item.memories` is the inverse SwiftData
        // stores, not what the test happens to hold in memory.
        let photos = try context.fetch(FetchDescriptor<MediaItem>(sortBy: [SortDescriptor(\.id)]))
        XCTAssertEqual(photos.count, 30)
        let records = try context.fetch(FetchDescriptor<Memory>(sortBy: [SortDescriptor(\.updatedAt)]))
        XCTAssertFalse(records.isEmpty)

        let grouped = TimelineScreen.memoriesByPhotoID(records)
        let expectedTotal: Int = photos.reduce(0) { (count: Int, item: MediaItem) -> Int in
            count + item.memories.count
        }
        let groupedTotal: Int = grouped.reduce(0) { (count: Int, entry: Dictionary<PersistentIdentifier, [Memory]>.Element) -> Int in
            count + entry.value.count
        }
        XCTAssertEqual(groupedTotal, expectedTotal)

        for item in photos {
            let fromRelationship = TimelineItemSnapshot(item: item, placeHint: nil)
            let fromGroup = TimelineItemSnapshot(
                item: item,
                placeHint: nil,
                memories: grouped[item.persistentModelID] ?? []
            )
            XCTAssertEqual(fromGroup, fromRelationship, "photo \(item.id)")
            XCTAssertEqual(fromGroup.memories, fromRelationship.memories, "snippets of \(item.id)")
        }
    }

    func testPhotoWithoutMemoriesGetsAnEmptyList() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let lonely = MediaItem(id: "lonely-photo", title: "Synthetic alone")
        context.insert(lonely)
        let withMemory = MediaItem(id: "photo-with-memory")
        context.insert(withMemory)
        context.insert(Memory(text: "Only one", mediaItem: withMemory))
        try context.save()

        let records = try context.fetch(FetchDescriptor<Memory>())
        let grouped = TimelineScreen.memoriesByPhotoID(records)

        let noMemories: [Memory] = grouped[lonely.persistentModelID] ?? []
        let empty = TimelineItemSnapshot(item: lonely, placeHint: nil, memories: noMemories)
        XCTAssertTrue(empty.memories.isEmpty)
        XCTAssertEqual(empty, TimelineItemSnapshot(item: lonely, placeHint: nil))
    }

    // MARK: - Synthetic data

    private static func insertPhotos(_ count: Int, in context: ModelContext) -> [MediaItem] {
        var photos: [MediaItem] = []
        for index in 0..<count {
            let id: String = "synthetic-photo-\(index)"
            let title: String = "Synthetic \(index)"
            let step: Double = Double(index)
            let seconds: Double = step * 3_600
            let date: Date = Date(timeIntervalSince1970: 1_700_000_000 + seconds)
            let latitude: Double = step * 0.01
            let longitude: Double = step * 0.02
            let item = MediaItem(
                id: id,
                captureDate: date,
                latitude: latitude,
                longitude: longitude,
                title: title
            )
            context.insert(item)
            photos.append(item)
        }
        return photos
    }

    private static func insertMemories(for photos: [MediaItem], in context: ModelContext) {
        let createdAt = Date(timeIntervalSince1970: 1_700_500_000)
        for (index, item) in photos.enumerated() {
            let count: Int = memoryCount(forPhotoAt: index)
            let offset: Double = Double(index) * 60
            for line in 0..<count {
                let text: String = "Synthetic line \(index)-\(line)"
                // A photo's first two memories share a createdAt, so only the
                // text decides their order and the ids must still match.
                let lineOffset: Double = line >= 2 ? 3_600 : 0
                let moment: Date = createdAt.addingTimeInterval(offset + lineOffset)
                let author: MemoryAuthor = line == 1 ? .partner : .me
                let memory = Memory(text: text, author: author, createdAt: moment, mediaItem: item)
                context.insert(memory)
            }
        }

        // A memory whose `mediaID` names another photo: it must still be
        // grouped under its own `mediaItem`, exactly as `item.memories` is.
        guard photos.count > 1 else { return }
        let owner: MediaItem = photos[0]
        let wrongID: String = photos[1].id
        let mislabelled = Memory(
            text: "Mislabelled memory",
            author: .partner,
            createdAt: createdAt,
            mediaItem: owner
        )
        mislabelled.mediaID = wrongID
        context.insert(mislabelled)
    }

    /// 30 photos with 0, 1 or 3 memories as the plan of the test describes.
    private static func memoryCount(forPhotoAt index: Int) -> Int {
        let remainder = index % 3
        switch remainder {
        case 0: return 0
        case 1: return 1
        default: return 3
        }
    }
}

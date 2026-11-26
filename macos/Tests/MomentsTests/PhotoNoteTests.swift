import Foundation
import SwiftData
import XCTest
@testable import Moments

@MainActor
final class PhotoNoteTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// Held for the whole test: a ModelContext whose container is released crashes.
    private var container: ModelContainer?

    private func makeContext() throws -> ModelContext {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    @discardableResult
    private func insertItem(
        _ id: String,
        minutes: Double = 0,
        place: Place? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        tripID: String? = nil,
        in context: ModelContext
    ) -> MediaItem {
        let item = MediaItem(
            id: id,
            captureDate: base.addingTimeInterval(minutes * 60),
            latitude: latitude,
            longitude: longitude,
            title: id,
            tripID: tripID,
            place: place
        )
        context.insert(item)
        return item
    }

    // MARK: Words are the memory

    func testOwnWordsAddToOwnMemoryAndNeverToThePartners() throws {
        let context = try makeContext()
        let item = insertItem("a", in: context)
        context.insert(Memory(text: "Partner words", author: .partner, authorAccountID: "partner-account", createdAt: base, mediaItem: item))
        try context.save()

        XCTAssertNotNil(NoteApplier.writeOwnWords("  First  ", on: item, context: context, now: base.addingTimeInterval(60)))
        NoteApplier.writeOwnWords("Second", on: item, context: context, now: base.addingTimeInterval(120))
        NoteApplier.writeOwnWords("Second", on: item, context: context, now: base.addingTimeInterval(180))
        XCTAssertNil(NoteApplier.writeOwnWords("   ", on: item, context: context))
        try context.save()

        XCTAssertEqual(item.ownMemory?.text, "First\nSecond", "Repeated words are not added twice")
        XCTAssertEqual(item.ownMemory?.authorAccountID, MomentsAccount.localID)
        XCTAssertEqual(item.writtenMemories.map(\.text), ["Partner words", "First\nSecond"], "Both people, oldest first")
        XCTAssertEqual(item.writtenMemories.map(\.isOwn), [false, true])
        XCTAssertTrue(item.hasWrittenMemory)
    }

    func testEarlierUnorganizedWordsBecomeMemoriesOnce() throws {
        let context = try makeContext()
        let waitingItem = insertItem("waiting", in: context)
        let failedItem = insertItem("failed", in: context)
        let doneItem = insertItem("done", in: context)
        let partnerItem = insertItem("partner", in: context)
        context.insert(PhotoNote(mediaID: "waiting", text: "No key yet", createdAt: base, status: .waiting))
        context.insert(PhotoNote(mediaID: "failed", text: "Offline words", createdAt: base, status: .failed))
        let organized = PhotoNote(mediaID: "done", text: "Organized words", createdAt: base, status: .done)
        var wroteMemory = PhotoNoteUndoRecord()
        wroteMemory.memories = [PhotoNoteUndoRecord.TextChange(recordID: "m", previousText: nil, created: true, writtenText: "Organized")]
        organized.undoRecord = wroteMemory
        context.insert(organized)
        let placeOnlyItem = insertItem("placeOnly", in: context)
        let placeOnly = PhotoNote(mediaID: "placeOnly", text: "This is Old Lane", createdAt: base, status: .done)
        var fixedPlace = PhotoNoteUndoRecord()
        fixedPlace.overrides = [PhotoNoteUndoRecord.OverrideChange(mediaID: "placeOnly", previousName: nil, created: true, writtenName: "Old Lane")]
        placeOnly.undoRecord = fixedPlace
        context.insert(placeOnly)
        context.insert(PhotoNote(mediaID: "partner", authorAccountID: "partner-account", text: "Theirs", createdAt: base, status: .waiting))
        try context.save()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PhotoNoteTests.\(UUID().uuidString)"))

        XCTAssertEqual(PhotoNoteService.writeEarlierWords(context: context, defaults: defaults), 3)
        XCTAssertEqual(placeOnlyItem.ownMemory?.text, "This is Old Lane", "A note that only fixed the place kept its words nowhere else")
        XCTAssertEqual(waitingItem.ownMemory?.text, "No key yet")
        XCTAssertEqual(failedItem.ownMemory?.text, "Offline words")
        XCTAssertTrue(doneItem.memories.isEmpty, "A note that wrote a memory is left alone")
        XCTAssertTrue(partnerItem.memories.isEmpty, "The partner's words are theirs to write")

        // Once only: a memory cleared afterwards stays cleared.
        context.delete(try XCTUnwrap(waitingItem.ownMemory))
        try context.save()
        XCTAssertEqual(PhotoNoteService.writeEarlierWords(context: context, defaults: defaults), 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Memory>()).filter { $0.mediaID == "waiting" }.isEmpty)
    }

    func testAuthorNamesFallBackToMeAndPartner() throws {
        XCTAssertEqual(AuthorNames.label(isOwn: true, myName: "  ", partnerName: "Sam"), String(localized: "Me"))
        XCTAssertEqual(AuthorNames.label(isOwn: false, myName: "Alex", partnerName: ""), String(localized: "Partner"))
        XCTAssertEqual(AuthorNames.label(isOwn: true, myName: " Alex ", partnerName: "Sam"), "Alex")
        XCTAssertEqual(AuthorNames.label(isOwn: false, myName: "Alex", partnerName: "Sam"), "Sam")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PhotoNoteTests.\(UUID().uuidString)"))
        defaults.set("Sam", forKey: AuthorNames.partnerNameKey)
        XCTAssertEqual(AuthorNames.label(isOwn: false, defaults: defaults), "Sam")
        XCTAssertTrue(AuthorNames.isLocal(nil))
        XCTAssertTrue(AuthorNames.isLocal(MomentsAccount.localID))
        XCTAssertFalse(AuthorNames.isLocal("partner-account"))
        XCTAssertTrue(Memory(text: "old", author: .me).isOwn)
        XCTAssertFalse(Memory(text: "old", author: .partner).isOwn)
        XCTAssertFalse(Memory(text: "x", author: .me, authorAccountID: "partner-account").isOwn, "The account wins over the old label")
    }

    func testSearchAndMemoryFilterReadBothPeoplesMemories() throws {
        let context = try makeContext()
        let shared = insertItem("shared", in: context)
        let empty = insertItem("empty", in: context)
        context.insert(Memory(text: "Lanterns by the river", author: .partner, authorAccountID: "partner-account", createdAt: base, updatedAt: base.addingTimeInterval(10), mediaItem: shared))
        context.insert(Memory(text: "Cold hands", author: .me, authorAccountID: MomentsAccount.localID, createdAt: base, updatedAt: base, mediaItem: shared))
        context.insert(Memory(text: "  ", author: .me, authorAccountID: MomentsAccount.localID, mediaItem: empty))
        try context.save()

        // The older memory is found too, not only the newest one.
        XCTAssertTrue(LibraryFilterEngine.matches(shared, criteria: LibraryFilterCriteria(searchText: "cold")))
        XCTAssertTrue(LibraryFilterEngine.matches(shared, criteria: LibraryFilterCriteria(searchText: "lanterns")))
        XCTAssertTrue(LibraryFilterEngine.matches(shared, criteria: LibraryFilterCriteria(memoryFilter: .hasMemory)))
        XCTAssertFalse(LibraryFilterEngine.matches(empty, criteria: LibraryFilterCriteria(memoryFilter: .hasMemory)))
        XCTAssertTrue(LibraryFilterEngine.matches(empty, criteria: LibraryFilterCriteria(memoryFilter: .noMemory)))
        XCTAssertEqual(shared.ownMemory?.text, "Cold hands", "Your own field shows your words, never the partner's")
    }

    func testForgettingAISettingsClearsWhatTheOrganizerKept() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PhotoNoteTests.\(UUID().uuidString)"))
        for key in PhotoNoteService.aiSettingKeys { defaults.set("x", forKey: key) }
        defaults.set("Sam", forKey: AuthorNames.partnerNameKey)

        PhotoNoteService.forgetAISettings(defaults: defaults)

        for key in PhotoNoteService.aiSettingKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertEqual(defaults.string(forKey: AuthorNames.partnerNameKey), "Sam", "Only the AI settings go")
    }

    // MARK: Migration

    func testFrozenV6StoreWithPeopleOpensWithNoteEntities() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "moments-v6-\(UUID().uuidString)", directoryHint: .isDirectory)
        let storeURL = folder.appending(path: "Moments.store")
        defer { try? FileManager.default.removeItem(at: folder) }

        let legacy = try MomentsPersistence.makeV6Container(url: storeURL)
        let oldContext = legacy.mainContext
        let item = SchemaV6.MediaItem(id: "frozen-v6-item", title: "Synthetic V6 item")
        oldContext.insert(item)
        oldContext.insert(SchemaV6.Memory(text: "Synthetic memory", mediaItem: item))
        oldContext.insert(SchemaV6.Person(id: "person-1", name: "Synthetic person"))
        oldContext.insert(SchemaV6.FaceScanRecord(id: "frozen-v6-item"))
        try oldContext.save()

        let current = try MomentsPersistence.makeContainer(url: storeURL)
        let context = current.mainContext
        XCTAssertEqual(try context.fetch(FetchDescriptor<MediaItem>()).map(\.id), ["frozen-v6-item"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Memory>()).map(\.text), ["Synthetic memory"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Person>()).map(\.name), ["Synthetic person"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<FaceScanRecord>()).map(\.id), ["frozen-v6-item"])
        XCTAssertTrue(try context.fetch(FetchDescriptor<PhotoNote>()).isEmpty)

        context.insert(PhotoNote(mediaID: "frozen-v6-item", text: "Synthetic note"))
        context.insert(CollectionMemory(scope: .trip, scopeKey: "trip-1", text: "Synthetic trip memory"))
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<PhotoNote>()).count, 1)
    }

    func testFrozenV5StoreOpensWithNoteEntities() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "moments-v5-\(UUID().uuidString)", directoryHint: .isDirectory)
        let storeURL = folder.appending(path: "Moments.store")
        defer { try? FileManager.default.removeItem(at: folder) }

        let legacy = try MomentsPersistence.makeV5Container(url: storeURL)
        let oldContext = legacy.mainContext
        let item = SchemaV5.MediaItem(id: "frozen-v5-item", title: "Synthetic V5 item")
        oldContext.insert(item)
        oldContext.insert(SchemaV5.Memory(text: "Synthetic memory", mediaItem: item))
        oldContext.insert(SchemaV5.UserGroup(name: "Synthetic group"))
        try oldContext.save()

        let current = try MomentsPersistence.makeContainer(url: storeURL)
        let context = current.mainContext
        XCTAssertEqual(try context.fetch(FetchDescriptor<MediaItem>()).map(\.id), ["frozen-v5-item"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Memory>()).map(\.text), ["Synthetic memory"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<UserGroup>()).map(\.name), ["Synthetic group"])
        XCTAssertTrue(try context.fetch(FetchDescriptor<PhotoNote>()).isEmpty)

        context.insert(PhotoNote(mediaID: "frozen-v5-item", text: "Synthetic note"))
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<PhotoNote>()).count, 1)
    }
}

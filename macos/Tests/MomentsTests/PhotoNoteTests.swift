import Foundation
import SwiftData
import XCTest
@testable import Moments

private struct StubOrganizer: NoteOrganizing {
    var label = "Stub"
    var outcome: Result<NoteOrganizerResult, NoteOrganizerError>

    func organize(_ context: NoteOrganizerContext) async throws -> NoteOrganizerResult {
        try outcome.get()
    }
}

/// Records what a model was given, to prove only the allowed facts are sent.
private final class CapturingOrganizer: NoteOrganizing, @unchecked Sendable {
    var label: String { "Capture" }
    var received: NoteOrganizerContext?

    func organize(_ context: NoteOrganizerContext) async throws -> NoteOrganizerResult {
        received = context
        return NoteOrganizerResult(memory: "ok")
    }
}

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

    // MARK: Parsing and building

    func testParserReadsFencedJSONAndDropsEmptyFields() throws {
        let reply = """
        Here you go:
        ```json
        {"placeName": " Old Lane ", "placeDescription": "", "memory": "We climbed slowly.", "memoryScope": "day"}
        ```
        """
        let result = try NoteOrganizerParser.parse(reply)
        XCTAssertEqual(result, NoteOrganizerResult(placeName: "Old Lane", placeDescription: nil, memory: "We climbed slowly.", memoryScope: "day"))
        XCTAssertThrowsError(try NoteOrganizerParser.parse("no json here"))
    }

    func testBuilderSkipsUnchangedPlaceAndPlacelessDescription() {
        var counter = 0
        let makeID = { () -> String in counter += 1; return "s\(counter)" }

        let same = NoteSuggestionBuilder.suggestions(
            from: NoteOrganizerResult(placeName: "harbor ", placeDescription: "Windy.", memory: "Nice", memoryScope: "bogus"),
            currentPlaceName: "Harbor",
            nearbyMediaIDs: ["n1"],
            makeID: makeID
        )
        XCTAssertEqual(same.map(\.kind), [.placeDescription, .memory])
        XCTAssertEqual(same.first?.placeName, "Harbor")
        XCTAssertEqual(same.last?.scope, .photo, "An unknown scope falls back to this photo")

        let corrected = NoteSuggestionBuilder.suggestions(
            from: NoteOrganizerResult(placeName: "Old Lane", placeDescription: "Steep steps."),
            currentPlaceName: "Harbor",
            nearbyMediaIDs: ["n1", "n2"],
            makeID: makeID
        )
        XCTAssertEqual(corrected.map(\.kind), [.placeCorrection, .placeDescription])
        XCTAssertEqual(corrected[0].previousPlaceName, "Harbor")
        XCTAssertTrue(corrected[0].applyToNearby)
        XCTAssertEqual(corrected[0].nearbyMediaIDs, ["n1", "n2"])
        XCTAssertEqual(corrected[1].placeName, "Old Lane", "The description belongs to the corrected place")

        let noPlace = NoteSuggestionBuilder.suggestions(
            from: NoteOrganizerResult(placeDescription: "Quiet."),
            currentPlaceName: nil,
            nearbyMediaIDs: []
        )
        XCTAssertTrue(noPlace.isEmpty)
    }

    func testNearbyUsesTimeWindowAndPlaceOrDistance() throws {
        let context = try makeContext()
        let harbor = Place(name: "Harbor")
        context.insert(harbor)
        let item = insertItem("a", place: harbor, latitude: 0.001, longitude: 0.001, in: context)
        insertItem("samePlace", minutes: 60, place: harbor, in: context)
        insertItem("close", minutes: -30, latitude: 0.0015, longitude: 0.001, in: context)
        insertItem("far", minutes: 10, latitude: 0.05, longitude: 0.05, in: context)
        insertItem("late", minutes: 200, place: harbor, in: context)
        let corrected = insertItem("ownCorrection", minutes: 5, place: harbor, in: context)
        context.insert(PlaceOverride(mediaID: "ownCorrection", nameOverride: "Pier", mediaItem: corrected))
        let all = try context.fetch(FetchDescriptor<MediaItem>())

        XCTAssertEqual(NoteApplier.nearbyMediaIDs(for: item, among: all), ["close", "samePlace"])
    }

    func testNotesNeverSeeTheImportsInternalSpotHandle() throws {
        let context = try makeContext()
        let city = Place(id: "city-1", name: "Marrakesh", kind: .city)
        let spot = Place(id: "spot-26b47e", name: "Spot 26b47e", parent: city)
        let orphan = Place(id: "spot-6cd466", name: "Spot 6cd466")
        for place in [city, spot, orphan] { context.insert(place) }
        let named = insertItem("named", place: spot, in: context)
        let unnamed = insertItem("unnamed", place: orphan, in: context)

        XCTAssertEqual(named.namedPlace, "Marrakesh")
        XCTAssertNil(unnamed.namedPlace)
        XCTAssertNil(NoteApplier.context(for: PhotoNote(mediaID: "unnamed", text: "x"), item: unnamed).placeName)
        context.insert(PlaceOverride(mediaID: "unnamed", nameOverride: "Riad", mediaItem: unnamed))
        XCTAssertEqual(unnamed.namedPlace, "Riad")
    }

    // MARK: Applying and undoing

    func testPlaceCorrectionCoversNearbyPhotosAndUndoRestoresThem() throws {
        let context = try makeContext()
        let harbor = Place(name: "Harbor")
        context.insert(harbor)
        let item = insertItem("a", place: harbor, in: context)
        let neighbour = insertItem("b", minutes: 5, place: harbor, in: context)
        context.insert(PlaceOverride(mediaID: "b", nameOverride: "Pier", mediaItem: neighbour))
        try context.save()

        let note = PhotoNote(mediaID: "a", text: "Not the harbor, it is Old Lane", status: .ready)
        note.suggestions = [NoteSuggestion(id: "c", kind: .placeCorrection, text: "Old Lane", previousPlaceName: "Harbor", applyToNearby: true, nearbyMediaIDs: ["b"])]
        context.insert(note)

        XCTAssertEqual(try NoteApplier.accept(["c"], of: note, item: item, context: context), 1)
        try context.save()
        XCTAssertEqual(item.effectivePlaceName, "Old Lane")
        XCTAssertEqual(neighbour.effectivePlaceName, "Old Lane")
        XCTAssertEqual(note.status, .done)

        try NoteApplier.undo(note, context: context)
        try context.save()
        XCTAssertNil(item.localPlaceOverride, "An override created from the note is removed")
        XCTAssertEqual(item.effectivePlaceName, "Harbor")
        XCTAssertEqual(neighbour.effectivePlaceName, "Pier", "An existing override gets its old name back")
        XCTAssertEqual(note.status, .ready)
        XCTAssertEqual(note.suggestions.first?.decision, .pending)
        XCTAssertEqual(note.text, "Not the harbor, it is Old Lane", "The original words are never touched")
    }

    func testRevisingAWrittenItemRewritesItAndKeepsUndo() throws {
        let context = try makeContext()
        let harbor = Place(name: "Harbor")
        context.insert(harbor)
        let item = insertItem("a", place: harbor, in: context)
        let neighbour = insertItem("b", minutes: 5, place: harbor, in: context)
        try context.save()

        let note = PhotoNote(mediaID: "a", text: "It is Old Lane", status: .ready)
        note.suggestions = [
            NoteSuggestion(id: "c", kind: .placeCorrection, text: "Old Lane", previousPlaceName: "Harbor", applyToNearby: true, nearbyMediaIDs: ["b"]),
            NoteSuggestion(id: "m", kind: .memory, text: "Quiet morning", scope: .photo)
        ]
        context.insert(note)
        try NoteApplier.accept(["c", "m"], of: note, item: item, context: context)
        try context.save()

        try NoteApplier.revise("c", of: note, to: "Old Lane Café", item: item, context: context)
        try context.save()
        XCTAssertEqual(item.effectivePlaceName, "Old Lane Café")
        XCTAssertEqual(neighbour.effectivePlaceName, "Old Lane Café")
        XCTAssertEqual(item.memories.map(\.text), ["Quiet morning"], "Other written items stay written")
        XCTAssertEqual(note.status, .done)

        try NoteApplier.undo(note, context: context)
        try context.save()
        XCTAssertEqual(item.effectivePlaceName, "Harbor")
        XCTAssertEqual(neighbour.effectivePlaceName, "Harbor")
    }

    func testMemoryAppendsToOwnMemoryLeavesPartnerAloneAndUndoes() throws {
        let context = try makeContext()
        let mine = insertItem("mine", in: context)
        let theirs = insertItem("theirs", in: context)
        context.insert(Memory(text: "First line", author: .me, authorAccountID: MomentsAccount.localID, mediaItem: mine))
        context.insert(Memory(text: "Partner words", author: .partner, authorAccountID: "partner-account", mediaItem: theirs))
        try context.save()

        let first = PhotoNote(mediaID: "mine", text: "x", status: .ready)
        first.suggestions = [NoteSuggestion(id: "m1", kind: .memory, text: "Second line", scope: .photo)]
        context.insert(first)
        try NoteApplier.accept(["m1"], of: first, item: mine, context: context)

        let second = PhotoNote(mediaID: "theirs", text: "y", status: .ready)
        second.suggestions = [NoteSuggestion(id: "m2", kind: .memory, text: "My view", scope: .photo)]
        context.insert(second)
        try NoteApplier.accept(["m2"], of: second, item: theirs, context: context)
        try context.save()

        XCTAssertEqual(mine.memories.map(\.text), ["First line\nSecond line"])
        XCTAssertEqual(Set(theirs.memories.map(\.text)), ["Partner words", "My view"])

        try NoteApplier.undo(first, context: context)
        try NoteApplier.undo(second, context: context)
        try context.save()
        XCTAssertEqual(mine.memories.map(\.text), ["First line"])
        XCTAssertEqual(theirs.memories.map(\.text), ["Partner words"])
    }

    func testUndoLeavesLaterEditsAlone() throws {
        let context = try makeContext()
        let item = insertItem("a", in: context)
        let note = PhotoNote(mediaID: "a", text: "x", status: .ready)
        note.suggestions = [
            NoteSuggestion(id: "m", kind: .memory, text: "From the note", scope: .photo),
            NoteSuggestion(id: "c", kind: .placeCorrection, text: "Old Lane")
        ]
        context.insert(note)
        try NoteApplier.accept(["m", "c"], of: note, item: item, context: context)
        try context.save()

        item.memories.first?.text = "From the note, then edited by hand"
        item.localPlaceOverride?.nameOverride = "Renamed later"
        try NoteApplier.undo(note, context: context)
        try context.save()

        XCTAssertEqual(item.memories.map(\.text), ["From the note, then edited by hand"])
        XCTAssertEqual(item.effectivePlaceName, "Renamed later")
    }

    func testDayTripAndPlaceDescriptionWritesAndUndo() throws {
        let context = try makeContext()
        let item = insertItem("a", tripID: "trip-1", in: context)
        let note = PhotoNote(mediaID: "a", text: "z", status: .ready)
        note.suggestions = [
            NoteSuggestion(id: "d", kind: .memory, text: "A long day", scope: .day),
            NoteSuggestion(id: "t", kind: .memory, text: "Best trip", scope: .trip),
            NoteSuggestion(id: "p", kind: .placeDescription, text: "Steep steps.", placeName: "Old Lane"),
            NoteSuggestion(id: "s", kind: .memory, text: "Skipped")
        ]
        context.insert(note)
        NoteApplier.reject("s", of: note)
        try NoteApplier.accept(["d", "t", "p"], of: note, item: item, context: context)
        try context.save()

        let collection = try context.fetch(FetchDescriptor<CollectionMemory>())
        XCTAssertEqual(Set(collection.map(\.scopeKey)), [PhotoNoteDay.key(for: base), "trip-1"])
        let placeNotes = try context.fetch(FetchDescriptor<PlaceNote>())
        XCTAssertEqual(placeNotes.map(\.placeKey), ["old lane"])
        XCTAssertTrue(item.memories.isEmpty)
        XCTAssertEqual(note.status, .done)

        try NoteApplier.undo(note, context: context)
        try context.save()
        XCTAssertTrue(try context.fetch(FetchDescriptor<CollectionMemory>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<PlaceNote>()).isEmpty)
        XCTAssertEqual(note.suggestions.first { $0.id == "s" }?.decision, .rejected, "Undo keeps skipped suggestions skipped")
    }

    // MARK: Service

    func testSaveKeepsWordsAndTurnsResultIntoSuggestions() async throws {
        let context = try makeContext()
        let harbor = Place(name: "Harbor")
        context.insert(harbor)
        let item = insertItem("a", place: harbor, latitude: 0.001, longitude: 0.002, in: context)
        try context.save()
        let capture = CapturingOrganizer()
        let service = PhotoNoteService(makeOrganizers: { [capture] })

        let note = try XCTUnwrap(service.save("  It was Old Lane  ", for: item, context: context))
        XCTAssertEqual(note.text, "It was Old Lane")
        XCTAssertTrue(service.isRunning(note), "A just-saved note counts as organizing at once")
        for _ in 0..<1000 where service.isRunning(note) { await Task.yield() }
        XCTAssertFalse(service.isRunning(note))

        XCTAssertEqual(capture.received?.noteText, "It was Old Lane")
        XCTAssertEqual(capture.received?.placeName, "Harbor")
        XCTAssertEqual(note.organizerLabel, "Capture")
        XCTAssertEqual(note.suggestions.map(\.kind), [.memory])
        XCTAssertEqual(note.status, .done, "The result is written without asking")
        XCTAssertEqual(note.suggestions.map(\.decision), [.accepted])
        XCTAssertEqual(item.memories.map(\.text), ["ok"])
        XCTAssertFalse(note.undoRecord.isEmpty, "What was written can be undone")
        XCTAssertNil(service.save("   ", for: item, context: context), "Blank words are not saved")
    }

    func testUnavailableModelsLeaveNoteWaitingAndFallbackIsTried() async throws {
        let context = try makeContext()
        let item = insertItem("a", in: context)

        let waiting = PhotoNote(mediaID: "a", text: "Lovely")
        context.insert(waiting)
        let offline = PhotoNoteService(makeOrganizers: {
            [StubOrganizer(outcome: .failure(.unavailable("Apple Intelligence is off")))]
        })
        await offline.organize(waiting, item: item, context: context)
        XCTAssertEqual(waiting.status, .waiting)
        XCTAssertEqual(waiting.failureReason, "Apple Intelligence is off")

        let fallback = PhotoNoteService(makeOrganizers: {
            [
                StubOrganizer(outcome: .failure(.unavailable("off"))),
                StubOrganizer(label: "Cloud", outcome: .success(NoteOrganizerResult()))
            ]
        })
        await fallback.organize(waiting, item: item, context: context)
        XCTAssertEqual(waiting.status, .nothingFound)
        XCTAssertEqual(waiting.organizerLabel, "Cloud")

        let failing = PhotoNoteService(makeOrganizers: { [StubOrganizer(outcome: .failure(.badResponse))] })
        await failing.organize(waiting, item: item, context: context)
        XCTAssertEqual(waiting.status, .failed)
        XCTAssertEqual(waiting.text, "Lovely")
    }

    func testFactoryOrderFollowsSettings() {
        var settings = AISettings()
        XCTAssertEqual(NoteOrganizerFactory.organizers(settings: settings, apiKey: { _ in nil }).count, 1)
        settings.fallback = .useCloud
        XCTAssertEqual(NoteOrganizerFactory.organizers(settings: settings, apiKey: { _ in nil }).count, 2)
        settings.engine = .cloud
        let cloudOnly = NoteOrganizerFactory.organizers(settings: settings, apiKey: { _ in "k" })
        XCTAssertEqual(cloudOnly.map(\.label), ["Claude"])
    }

    func testOpenAICompatibleEndpoint() {
        XCTAssertEqual(OpenAICompatibleOrganizer.endpoint(from: "https://example.com/v1/")?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(OpenAICompatibleOrganizer.endpoint(from: "https://example.com/v1/chat/completions")?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertNil(OpenAICompatibleOrganizer.endpoint(from: "  "))
    }

    func testMissingKeyIsReportedBeforeAnyRequest() async {
        let organizer = ClaudeOrganizer(apiKey: nil, model: "claude-opus-5-5")
        do {
            _ = try await organizer.organize(NoteOrganizerContext(noteText: "x"))
            XCTFail("Expected missingKey")
        } catch {
            XCTAssertEqual(error as? NoteOrganizerError, .missingKey)
        }
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

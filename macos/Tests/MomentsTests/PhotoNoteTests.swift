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

/// Answers URLSession requests without touching the network.
private final class StubURLProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    static var failure: URLError?

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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

    /// A throwaway defaults domain, removed after the test.
    private func makeDefaults() throws -> UserDefaults {
        let name = "PhotoNoteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
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

    /// Waits on the service, not the note: a note no model could take is deleted.
    private func waitUntilDone(_ note: PhotoNote, _ service: PhotoNoteService) async {
        for _ in 0..<1000 where !service.runningNoteIDs.isEmpty { await Task.yield() }
    }

    func testOrganizeSendsOnlyTheWordsAndWritesPlaceFixesButNoMemory() async throws {
        let context = try makeContext()
        let harbor = Place(name: "Harbor")
        context.insert(harbor)
        let item = insertItem("a", place: harbor, latitude: 0.001, longitude: 0.002, in: context)
        context.insert(Memory(text: "It was Old Lane", author: .me, authorAccountID: MomentsAccount.localID, mediaItem: item))
        try context.save()
        let capture = CapturingOrganizer()
        let service = PhotoNoteService(makeOrganizers: { [capture] })

        let note = try XCTUnwrap(service.organize("  It was Old Lane  ", for: item, context: context))
        XCTAssertEqual(note.text, "It was Old Lane")
        XCTAssertTrue(service.isRunning(note), "A just-handed note counts as organizing at once")
        await waitUntilDone(note, service)
        XCTAssertFalse(service.isRunning(note))

        XCTAssertEqual(capture.received?.noteText, "It was Old Lane")
        XCTAssertEqual(capture.received?.placeName, "Harbor")
        XCTAssertEqual(note.organizerLabel, "Capture")
        // The model answered only with a memory: the words already are one.
        XCTAssertTrue(note.suggestions.isEmpty)
        XCTAssertEqual(note.status, .nothingFound)
        XCTAssertEqual(item.memories.map(\.text), ["It was Old Lane"], "The person's words are never rewritten")
        XCTAssertNil(service.organize("   ", for: item, context: context), "Blank words are not organized")
    }

    func testOrganizeWritesPlaceDescriptionAndDayLineAtOnceAndUndoTakesThemBack() async throws {
        let context = try makeContext()
        let harbor = Place(name: "Harbor")
        context.insert(harbor)
        let item = insertItem("a", place: harbor, tripID: "trip-1", in: context)
        context.insert(Memory(text: "Old Lane, steep steps, best day", author: .me, authorAccountID: MomentsAccount.localID, mediaItem: item))
        try context.save()
        let service = PhotoNoteService(makeOrganizers: {
            [StubOrganizer(outcome: .success(NoteOrganizerResult(placeName: "Old Lane", placeDescription: "Steep steps.", memory: "Best day", memoryScope: "day")))]
        })
        let note = try XCTUnwrap(service.organize("Old Lane, steep steps, best day", for: item, context: context))
        XCTAssertTrue(service.isOrganizing(item), "The photo shows that AI is reading its words")
        await waitUntilDone(note, service)
        XCTAssertFalse(service.isOrganizing(item))

        XCTAssertEqual(Set(note.suggestions.map(\.kind)), [.placeCorrection, .placeDescription, .memory])
        XCTAssertEqual(note.suggestions.map(\.decision), [.accepted, .accepted, .accepted], "Nothing waits for a choice")
        XCTAssertEqual(note.status, .done)
        XCTAssertEqual(item.effectivePlaceName, "Old Lane")
        XCTAssertEqual(service.placeFix(for: item)?.noteID, note.id, "The place line can mark the fix AI")
        XCTAssertEqual(try context.fetch(FetchDescriptor<PlaceNote>()).map(\.sourceNoteID), [note.id])
        let dayLines = try context.fetch(FetchDescriptor<CollectionMemory>())
        XCTAssertEqual(dayLines.map(\.text), ["Best day"])
        XCTAssertEqual(dayLines.map(\.scope), [.day])
        XCTAssertEqual(dayLines.map(\.sourceNoteID), [note.id])
        XCTAssertEqual(item.memories.map(\.text), ["Old Lane, steep steps, best day"], "The person's words are never rewritten")

        // After a relaunch the place line still knows the fix was AI's.
        let reloaded = PhotoNoteService(makeOrganizers: { [] })
        reloaded.loadPlaceFixes(context: context)
        XCTAssertEqual(reloaded.placeFix(for: item)?.writtenName, "Old Lane", "Fixes are read back after a relaunch")

        service.undo(noteID: note.id, context: context)
        XCTAssertEqual(item.effectivePlaceName, "Harbor")
        XCTAssertNil(service.placeFix(for: item))
        XCTAssertTrue(try context.fetch(FetchDescriptor<PlaceNote>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CollectionMemory>()).isEmpty)
        XCTAssertEqual(item.memories.map(\.text), ["Old Lane, steep steps, best day"], "Undo never touches the person's words")
        XCTAssertFalse(note.suggestions.contains { $0.decision == .pending }, "Nothing is offered again")
        XCTAssertEqual(note.status, .done)
    }

    func testUndoNeverTouchesAMemoryAnOlderNoteWrote() throws {
        let context = try makeContext()
        let harbor = Place(name: "Harbor")
        context.insert(harbor)
        let item = insertItem("a", place: harbor, in: context)
        try context.save()
        // From before words were saved as typed: the note wrote the photo
        // memory (the only copy of those words) and fixed the place.
        let note = PhotoNote(mediaID: "a", text: "This is Old Lane, lovely", createdAt: base, status: .ready)
        note.suggestions = [
            NoteSuggestion(id: "c", kind: .placeCorrection, text: "Old Lane", previousPlaceName: "Harbor"),
            NoteSuggestion(id: "m", kind: .memory, text: "Lovely", scope: .photo)
        ]
        context.insert(note)
        try NoteApplier.accept(["c", "m"], of: note, item: item, context: context)
        try context.save()
        XCTAssertEqual(item.ownMemory?.text, "Lovely")

        let service = PhotoNoteService(makeOrganizers: { [] })
        service.loadPlaceFixes(context: context)
        XCTAssertEqual(service.placeFix(for: item)?.noteID, note.id)
        service.undo(noteID: note.id, context: context)
        XCTAssertEqual(item.effectivePlaceName, "Harbor", "The AI place fix is taken back")
        XCTAssertEqual(item.ownMemory?.text, "Lovely", "The person's memory is never taken back")
    }

    func testUndoTakesBackTheNewestDescriptionAndLeavesThePartnersNotesAlone() async throws {
        let context = try makeContext()
        let lane = Place(name: "Old Lane")
        context.insert(lane)
        let item = insertItem("a", place: lane, in: context)
        context.insert(PlaceNote(placeName: "Old Lane", text: "Written by hand."))
        try context.save()
        let service = PhotoNoteService(makeOrganizers: {
            [StubOrganizer(outcome: .success(NoteOrganizerResult(placeDescription: "Steep steps.")))]
        })
        let note = try XCTUnwrap(service.organize("Steep steps", for: item, context: context))
        await waitUntilDone(note, service)
        let placeNote = try XCTUnwrap(try context.fetch(FetchDescriptor<PlaceNote>()).first)
        XCTAssertEqual(placeNote.text, "Written by hand.\nSteep steps.")
        XCTAssertEqual(placeNote.sourceNoteID, note.id, "The newest AI addition is what its Undo takes back")

        service.undo(noteID: note.id, context: context)
        XCTAssertEqual(placeNote.text, "Written by hand.")
        XCTAssertNil(placeNote.sourceNoteID, "Nothing AI-made is left to mark")

        // A note from the other person is theirs; this Mac doesn't undo it.
        let theirs = PhotoNote(mediaID: "a", authorAccountID: "partner-account", text: "Theirs", createdAt: base, status: .done)
        context.insert(theirs)
        try context.save()
        let before = theirs.updatedAt
        service.undo(noteID: theirs.id, context: context)
        XCTAssertEqual(theirs.updatedAt, before)
    }

    func testAnOldAnthropicKeyMovesToTheCustomModelOnlyWhenTheKeychainAnswers() throws {
        // Found: the key and Anthropic's address move over.
        let found = try makeDefaults()
        found.set("https://models.example.com/v1", forKey: AISettings.baseURLKey)
        var stored: [(String, CloudProvider)] = []
        AISettings.moveOldAnthropicSetup(defaults: found, lookup: { $0 == .claude ? .found("old-key") : .notFound }, store: { stored.append(($0, $1)); return true })
        XCTAssertEqual(stored.map { $0.0 }, ["old-key"])
        XCTAssertEqual(stored.map { $0.1 }, [.openAICompatible])
        XCTAssertEqual(found.string(forKey: AISettings.baseURLKey), "https://api.anthropic.com/v1", "A stale address from trying another service is replaced")
        XCTAssertEqual(found.string(forKey: AISettings.modelKey), CloudProvider.claude.defaultModel)
        XCTAssertEqual(found.string(forKey: AISettings.providerKey), CloudProvider.openAICompatible.rawValue)

        // No key: just the custom model from now on.
        let none = try makeDefaults()
        AISettings.moveOldAnthropicSetup(defaults: none, lookup: { _ in .notFound }, store: { _, _ in XCTFail("Nothing to store"); return false })
        XCTAssertEqual(none.string(forKey: AISettings.providerKey), CloudProvider.openAICompatible.rawValue)
        XCTAssertNil(none.string(forKey: AISettings.baseURLKey))

        // Keychain locked or access denied: nothing changes, tried again later.
        let locked = try makeDefaults()
        AISettings.moveOldAnthropicSetup(defaults: locked, lookup: { _ in .failed }, store: { _, _ in XCTFail("Nothing to store"); return false })
        XCTAssertNil(locked.string(forKey: AISettings.providerKey))

        // Already moved: left alone.
        let moved = try makeDefaults()
        moved.set(CloudProvider.openAICompatible.rawValue, forKey: AISettings.providerKey)
        AISettings.moveOldAnthropicSetup(defaults: moved, lookup: { _ in XCTFail("No lookup needed"); return .notFound }, store: { _, _ in false })
    }

    func testOnlyDayAndTripLinesThatHaveAPlaceToGoAreKept() {
        let dated = MediaItem(id: "dated", captureDate: base, title: "dated", tripID: "trip-1")
        let undated = MediaItem(id: "undated", title: "undated")
        let suggestions = [
            NoteSuggestion(id: "p", kind: .placeCorrection, text: "Old Lane"),
            NoteSuggestion(id: "photo", kind: .memory, text: "Lovely", scope: .photo),
            NoteSuggestion(id: "day", kind: .memory, text: "Best day", scope: .day),
            NoteSuggestion(id: "trip", kind: .memory, text: "Best trip", scope: .trip)
        ]
        XCTAssertEqual(NoteApplier.suggestionsAfterWords(suggestions, item: dated).map(\.id), ["p", "day", "trip"])
        XCTAssertEqual(NoteApplier.suggestionsAfterWords(suggestions, item: undated).map(\.id), ["p"])
    }

    func testAIStartsOnAndTurnsOffCompletely() throws {
        let context = try makeContext()
        let item = insertItem("a", in: context)
        let service = PhotoNoteService(makeOrganizers: { [] })
        XCTAssertNil(service.organize("Lovely evening", for: item, context: context))
        XCTAssertTrue(try context.fetch(FetchDescriptor<PhotoNote>()).isEmpty)

        var settings = AISettings()
        XCTAssertTrue(settings.enabled, "AI starts turned on")
        let defaults = try makeDefaults()
        XCTAssertTrue(AISettings.load(from: defaults).enabled)
        defaults.set(false, forKey: AISettings.enabledKey)
        XCTAssertFalse(AISettings.load(from: defaults).enabled)
        settings.enabled = false
        XCTAssertTrue(NoteOrganizerFactory.organizers(settings: settings, apiKey: { _ in "k" }).isEmpty, "Off sends nothing")
    }

    func testUnavailableOrKeylessModelsDropTheNoteAndFallbackIsTried() async throws {
        let context = try makeContext()
        let item = insertItem("a", in: context)

        let offline = PhotoNoteService(makeOrganizers: {
            [StubOrganizer(outcome: .failure(.unavailable("Apple Intelligence is off")))]
        })
        let waiting = try XCTUnwrap(offline.organize("Lovely", for: item, context: context))
        await waitUntilDone(waiting, offline)
        // No key is a model that isn't set up, not a failure.
        let keyless = PhotoNoteService(makeOrganizers: { [ClaudeOrganizer(apiKey: nil, model: "claude-opus-5-5")] })
        let noKey = try XCTUnwrap(keyless.organize("Lovely", for: item, context: context))
        await waitUntilDone(noKey, keyless)
        // Nothing would retry them and the words are the memory already:
        // no dead copies are kept.
        XCTAssertTrue(try context.fetch(FetchDescriptor<PhotoNote>()).isEmpty)

        let fallback = PhotoNoteService(makeOrganizers: {
            [
                StubOrganizer(outcome: .failure(.unavailable("off"))),
                StubOrganizer(label: "Cloud", outcome: .success(NoteOrganizerResult()))
            ]
        })
        let found = try XCTUnwrap(fallback.organize("Lovely", for: item, context: context))
        await waitUntilDone(found, fallback)
        XCTAssertEqual(found.status, .nothingFound)
        XCTAssertEqual(found.organizerLabel, "Cloud")

        let failing = PhotoNoteService(makeOrganizers: { [StubOrganizer(outcome: .failure(.badResponse))] })
        let failed = try XCTUnwrap(failing.organize("Lovely", for: item, context: context))
        await waitUntilDone(failed, failing)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.text, "Lovely")
    }

    func testAddedWordsAreOnlyWhatIsNew() {
        XCTAssertEqual(PhotoNoteService.addedWords(from: "", to: " Rainy morning "), "Rainy morning")
        XCTAssertEqual(PhotoNoteService.addedWords(from: "Rainy morning", to: "Rainy morning\nThen sun at Old Lane"), "Then sun at Old Lane")
        XCTAssertEqual(PhotoNoteService.addedWords(from: "Rainy morning", to: "Sunny morning"), "Sunny morning")
        XCTAssertEqual(PhotoNoteService.addedWords(from: "Same", to: "Same "), "")
        XCTAssertEqual(PhotoNoteService.addedWords(from: "Gone", to: ""), "")
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
        let defaults = try makeDefaults()

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
        let defaults = try makeDefaults()
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

    func testFactoryTriesThisMacThenTheCustomModel() {
        var settings = AISettings()
        XCTAssertEqual(NoteOrganizerFactory.organizers(settings: settings, apiKey: { _ in nil }).count, 2, "On this Mac first, then the custom model")
        settings.engine = .cloud
        XCTAssertEqual(NoteOrganizerFactory.organizers(settings: settings, apiKey: { _ in "k" }).map(\.label), ["Anthropic"], "A key from before the custom model keeps working")

        // A custom model is any address; Anthropic's own gets its own API.
        // An address left from once trying another service is not used for
        // a key set up for Anthropic before the custom model.
        settings.baseURL = "https://models.example.com/v1"
        var legacyAsked: [CloudProvider] = []
        let legacy = NoteOrganizerFactory.organizers(settings: settings, apiKey: { legacyAsked.append($0); return "k" })
        XCTAssertEqual(legacy.map(\.label), ["Anthropic"])
        XCTAssertEqual(legacyAsked, [.claude])

        settings.provider = .openAICompatible
        settings.model = "some-model"
        var asked: [CloudProvider] = []
        let custom = NoteOrganizerFactory.organizers(settings: settings, apiKey: { asked.append($0); return "k" })
        XCTAssertEqual(custom.map(\.label), ["some-model"])
        XCTAssertEqual(asked, [.openAICompatible])
        settings.baseURL = "https://api.anthropic.com/v1"
        XCTAssertEqual(NoteOrganizerFactory.organizers(settings: settings, apiKey: { _ in "k" }).map(\.label), ["Anthropic"])
        XCTAssertFalse(NoteOrganizerFactory.isAnthropic("https://anthropic.com.example.org/v1"))
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

    func testClaudeRequestUsesLowEffortAndServerFallback() throws {
        let context = NoteOrganizerContext(noteText: "Quiet café by the river.")
        let opus = try ClaudeOrganizer(apiKey: "k", model: ClaudeModel.opus.rawValue).makeRequest(context, apiKey: "k")
        XCTAssertEqual(opus.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(opus.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(opus.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(opus.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(opus.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertNil(body["thinking"], "Opus 5.5 rejects disabled thinking; effort is the only control")
        let output = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "low")
        XCTAssertEqual((output["format"] as? [String: Any])?["type"] as? String, "json_schema")

        // Haiku has no server-side fallback: no header, no parameter.
        let haiku = try ClaudeOrganizer(apiKey: "k", model: ClaudeModel.haiku.rawValue).makeRequest(context, apiKey: "k")
        XCTAssertNil(haiku.value(forHTTPHeaderField: "anthropic-beta"))
        let haikuBody = ClaudeOrganizer.requestBody(model: ClaudeModel.haiku.rawValue, context: context)
        XCTAssertNil(haikuBody["fallbacks"])
        XCTAssertEqual((haikuBody["output_config"] as? [String: Any])?["effort"] as? String, "low")

        // A model typed by hand gets only the plain request.
        let custom = ClaudeOrganizer.requestBody(model: "claude-haiku-4-5", context: context)
        XCTAssertNil(custom["fallbacks"])
        XCTAssertNil((custom["output_config"] as? [String: Any])?["effort"])
        XCTAssertEqual(CloudProvider.claude.defaultModel, ClaudeModel.haiku.rawValue)
    }

    func testClaudeReadsTextAfterThinkingBlocks() async throws {
        StubURLProtocol.failure = nil
        StubURLProtocol.status = 200
        let note = #"{"placeName":"","placeDescription":"Quiet in the afternoon.","memory":"We sat by the river.","memoryScope":"photo"}"#
        StubURLProtocol.body = try JSONSerialization.data(withJSONObject: [
            "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": note]],
            "stop_reason": "end_turn"
        ])
        let organizer = ClaudeOrganizer(apiKey: "k", model: ClaudeModel.opus.rawValue, session: StubURLProtocol.session())
        let result = try await organizer.organize(NoteOrganizerContext(noteText: "x"))
        XCTAssertEqual(result, NoteOrganizerResult(placeName: nil, placeDescription: "Quiet in the afternoon.", memory: "We sat by the river.", memoryScope: "photo"))
    }

    func testClaudeExplainsKeyRegionAndNetworkFailures() async throws {
        let organizer = ClaudeOrganizer(apiKey: "k", model: ClaudeModel.opus.rawValue, session: StubURLProtocol.session())
        func failure() async -> NoteOrganizerError? {
            do {
                _ = try await organizer.organize(NoteOrganizerContext(noteText: "x"))
                return nil
            } catch {
                return error as? NoteOrganizerError
            }
        }
        StubURLProtocol.failure = nil
        StubURLProtocol.status = 403
        StubURLProtocol.body = try JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": "forbidden", "message": "Request not allowed"]])
        guard case .http(403, let regionMessage)? = await failure() else { return XCTFail("Expected a 403") }
        XCTAssertTrue(regionMessage.contains("proxy"), regionMessage)
        XCTAssertTrue(regionMessage.contains("Request not allowed"), regionMessage)

        StubURLProtocol.status = 401
        StubURLProtocol.body = try JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]])
        guard case .http(401, let keyMessage)? = await failure() else { return XCTFail("Expected a 401") }
        XCTAssertTrue(keyMessage.contains("Settings"), keyMessage)

        // Offline: the note waits instead of failing.
        StubURLProtocol.failure = URLError(.notConnectedToInternet)
        guard case .unavailable? = await failure() else { return XCTFail("Expected unavailable") }
        StubURLProtocol.failure = nil
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

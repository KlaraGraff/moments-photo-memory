import Foundation
import Observation
import SwiftData

/// The optional AI pass over a memory. The words a person types under a
/// photo are their memory the moment they type them (`MemoryEditor` saves
/// them); nothing here is needed for that. When AI is turned on in
/// Settings, the newly added words are kept as a `PhotoNote` and a model
/// corrects this photo's place and describes it, written at once (the place
/// stays editable by hand). With AI off nothing happens; with no key, no
/// network or no model the note is dropped again and nothing is shown.
@MainActor
@Observable
final class PhotoNoteService {
    private(set) var runningNoteIDs: Set<String> = []
    private let makeOrganizers: () -> [any NoteOrganizing]

    init(makeOrganizers: @escaping () -> [any NoteOrganizing] = { NoteOrganizerFactory.organizers() }) {
        self.makeOrganizers = makeOrganizers
    }

    /// The part of a memory that is new since editing began: what was added
    /// at the end, or the whole text when it was rewritten.
    static func addedWords(from before: String, to after: String) -> String {
        let after = after.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard after != before else { return "" }
        if !before.isEmpty, after.hasPrefix(before) {
            return String(after.dropFirst(before.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return after
    }

    /// Hands words just written into a memory to the model, when AI is on.
    /// Returns the note it keeps for them, or nil when there was nothing to do.
    @discardableResult
    func organize(_ words: String, for item: MediaItem, context: ModelContext) -> PhotoNote? {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let organizers = makeOrganizers()
        guard !organizers.isEmpty else { return nil }
        let note = PhotoNote(mediaID: item.id, text: trimmed)
        context.insert(note)
        do {
            try context.save()
        } catch {
            context.delete(note)
            return nil
        }
        runningNoteIDs.insert(note.id)
        Task { await run(note, item: item, context: context, organizers: organizers) }
        return note
    }

    func isRunning(_ note: PhotoNote) -> Bool {
        runningNoteIDs.contains(note.id)
    }

    static let earlierWordsWrittenKey = "moments.notes.earlierWordsWritten"

    /// Before words became memories at once, a note became a memory only if
    /// the model wrote one from it; otherwise (no key, offline, failed,
    /// nothing found, or only a place fix) the words lived only in the note,
    /// whose popover is gone. Writes those words once into the author's
    /// memory; a note that wrote a photo, day or trip memory is left alone.
    @discardableResult
    static func writeEarlierWords(context: ModelContext, defaults: UserDefaults = .standard, now: Date = .now) -> Int {
        guard !defaults.bool(forKey: earlierWordsWrittenKey) else { return 0 }
        guard let notes = try? context.fetch(FetchDescriptor<PhotoNote>(sortBy: [SortDescriptor(\.createdAt)])) else { return 0 }
        let pending = notes.filter { note in
            let record = note.undoRecord
            return AuthorNames.isLocal(note.authorAccountID) && record.memories.isEmpty && record.collectionMemoryIDs.isEmpty
        }
        var written = 0
        if !pending.isEmpty {
            let ids = Array(Set(pending.map(\.mediaID)))
            let items = (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
            let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for note in pending {
                guard let item = byID[note.mediaID] else { continue }
                if NoteApplier.writeOwnWords(note.text, on: item, context: context, now: now) != nil { written += 1 }
            }
            do {
                try context.save()
            } catch {
                // Try again next launch rather than mark it done.
                return 0
            }
        }
        defaults.set(true, forKey: earlierWordsWrittenKey)
        return written
    }

    /// Expects the note to be marked running already; clears that mark when done.
    private func run(_ note: PhotoNote, item: MediaItem, context: ModelContext, organizers: [any NoteOrganizing]) async {
        // Read once: the note may be deleted below.
        let noteID = note.id
        defer { runningNoteIDs.remove(noteID) }
        note.status = .organizing
        note.failureReason = nil
        try? context.save()

        let request = NoteApplier.context(for: note, item: item)
        for organizer in organizers {
            do {
                let result = try await organizer.organize(request)
                // Only this photo's place: with nothing to confirm and no
                // undo on screen, a wrong guess must not rename its neighbours.
                let built = NoteSuggestionBuilder.suggestions(from: result, currentPlaceName: item.namedPlace, nearbyMediaIDs: [])
                let suggestions = NoteApplier.suggestionsAfterWords(built)
                note.suggestions = suggestions
                note.organizerLabel = organizer.label
                note.status = suggestions.isEmpty ? .nothingFound : .ready
                note.updatedAt = .now
                // Written at once, nothing to confirm: the place line shows
                // what it was corrected from, and stays editable by hand.
                if !suggestions.isEmpty {
                    try? NoteApplier.accept(Set(suggestions.map(\.id)), of: note, item: item, context: context)
                }
                try? context.save()
                return
            } catch NoteOrganizerError.unavailable {
                continue
            } catch NoteOrganizerError.missingKey {
                // No key is a model that isn't set up, not a failure.
                continue
            } catch {
                note.status = .failed
                note.failureReason = error.localizedDescription
                note.updatedAt = .now
                try? context.save()
                return
            }
        }
        // No model could run: nothing will retry it and the words are
        // already the memory, so the note is not kept as a dead copy.
        context.delete(note)
        try? context.save()
    }
}

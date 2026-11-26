import Foundation
import Observation
import SwiftData

/// The optional AI pass over a memory. The words a person types under a
/// photo are their memory the moment they type them (`MemoryEditor` saves
/// them); nothing here is needed for that. When AI is turned on in
/// Settings, the newly added words are kept as a `PhotoNote` and a model
/// corrects the photo's place and describes it, written at once and
/// recorded so it can be undone. With AI off, no key, no network or no
/// model, nothing happens and nothing is shown.
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

    /// Before words became memories at once, a note the model never
    /// organized (no key, offline, failed) or found nothing in left the
    /// photo without a memory. Writes those words once into the author's
    /// memory; an organized note already wrote its memory and is left alone.
    @discardableResult
    static func writeEarlierWords(context: ModelContext, defaults: UserDefaults = .standard, now: Date = .now) -> Int {
        guard !defaults.bool(forKey: earlierWordsWrittenKey) else { return 0 }
        let unwritten: Set<PhotoNoteStatus> = [.organizing, .waiting, .failed, .nothingFound]
        guard let notes = try? context.fetch(FetchDescriptor<PhotoNote>(sortBy: [SortDescriptor(\.createdAt)])) else { return 0 }
        let pending = notes.filter { unwritten.contains($0.status) && AuthorNames.isLocal($0.authorAccountID) }
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
        defer { runningNoteIDs.remove(note.id) }
        note.status = .organizing
        note.failureReason = nil
        try? context.save()

        let request = NoteApplier.context(for: note, item: item)
        var lastUnavailable: String?
        for organizer in organizers {
            do {
                let result = try await organizer.organize(request)
                let nearby = try NoteApplier.nearbyMediaIDs(for: item, among: context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil })))
                let built = NoteSuggestionBuilder.suggestions(from: result, currentPlaceName: item.namedPlace, nearbyMediaIDs: nearby)
                let suggestions = NoteApplier.suggestionsAfterWords(built)
                note.suggestions = suggestions
                note.organizerLabel = organizer.label
                note.status = suggestions.isEmpty ? .nothingFound : .ready
                note.updatedAt = .now
                // Written at once, nothing to confirm: the place shows
                // "Corrected, was …" and stays editable by hand.
                if !suggestions.isEmpty {
                    try? NoteApplier.accept(Set(suggestions.map(\.id)), of: note, item: item, context: context)
                }
                try? context.save()
                return
            } catch NoteOrganizerError.unavailable(let reason) {
                lastUnavailable = reason
                continue
            } catch NoteOrganizerError.missingKey {
                // No key is a model that isn't set up, not a failure.
                lastUnavailable = NoteOrganizerError.missingKey.localizedDescription
                continue
            } catch {
                note.status = .failed
                note.failureReason = error.localizedDescription
                note.updatedAt = .now
                try? context.save()
                return
            }
        }
        note.status = .waiting
        note.failureReason = lastUnavailable
        note.updatedAt = .now
        try? context.save()
    }
}

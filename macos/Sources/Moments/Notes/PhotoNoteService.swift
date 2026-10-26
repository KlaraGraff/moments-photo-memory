import Foundation
import Observation
import SwiftData

/// Saves notes and runs the model on them. Saving always keeps the original
/// words first; organizing is a separate step whose result only becomes
/// suggestions, never direct changes.
@MainActor
@Observable
final class PhotoNoteService {
    private(set) var runningNoteIDs: Set<String> = []
    private let makeOrganizers: () -> [any NoteOrganizing]

    init(makeOrganizers: @escaping () -> [any NoteOrganizing] = { NoteOrganizerFactory.organizers() }) {
        self.makeOrganizers = makeOrganizers
    }

    /// Stores the words under the photo and starts organizing them.
    @discardableResult
    func save(_ text: String, for item: MediaItem, context: ModelContext) -> PhotoNote? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let note = PhotoNote(mediaID: item.id, text: trimmed)
        context.insert(note)
        do {
            try context.save()
        } catch {
            context.delete(note)
            return nil
        }
        Task { await organize(note, item: item, context: context) }
        return note
    }

    func isRunning(_ note: PhotoNote) -> Bool {
        runningNoteIDs.contains(note.id)
    }

    func organize(_ note: PhotoNote, item: MediaItem, context: ModelContext) async {
        guard !runningNoteIDs.contains(note.id) else { return }
        runningNoteIDs.insert(note.id)
        defer { runningNoteIDs.remove(note.id) }
        note.status = .organizing
        note.failureReason = nil
        try? context.save()

        let request = NoteApplier.context(for: note, item: item)
        var lastUnavailable: String?
        for organizer in makeOrganizers() {
            do {
                let result = try await organizer.organize(request)
                let nearby = try NoteApplier.nearbyMediaIDs(for: item, among: context.fetch(FetchDescriptor<MediaItem>()))
                let suggestions = NoteSuggestionBuilder.suggestions(from: result, currentPlaceName: item.effectivePlaceName, nearbyMediaIDs: nearby)
                note.suggestions = suggestions
                note.organizerLabel = organizer.label
                note.status = suggestions.isEmpty ? .nothingFound : .ready
                note.updatedAt = .now
                try? context.save()
                return
            } catch NoteOrganizerError.unavailable(let reason) {
                lastUnavailable = reason
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

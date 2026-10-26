import Foundation
import SwiftData

/// Every write made from one note, so it can be undone exactly.
public struct PhotoNoteUndoRecord: Codable, Equatable, Sendable {
    public struct OverrideChange: Codable, Equatable, Sendable {
        public var mediaID: String
        public var previousName: String?
        public var created: Bool
    }

    public struct TextChange: Codable, Equatable, Sendable {
        public var recordID: String
        public var previousText: String?
        public var created: Bool
    }

    public var overrides: [OverrideChange] = []
    public var placeNotes: [TextChange] = []
    public var memories: [TextChange] = []
    public var collectionMemoryIDs: [String] = []

    public init() {}

    public var isEmpty: Bool {
        overrides.isEmpty && placeNotes.isEmpty && memories.isEmpty && collectionMemoryIDs.isEmpty
    }
}

public enum PhotoNoteDay {
    /// `yyyy-MM-dd` in the current calendar, used as a day memory's key.
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

public enum NoteApplier {
    /// Photos taken within `window` of this one at the same place name or
    /// within `radius` metres, oldest first. Used to offer a place correction
    /// for the whole stop, not just the photo the note is under.
    public static func nearbyMediaIDs(
        for item: MediaItem,
        among candidates: [MediaItem],
        window: TimeInterval = 2 * 60 * 60,
        radius: Double = 300
    ) -> [String] {
        guard let date = item.effectiveCaptureDate else { return [] }
        let name = item.effectivePlaceName.map(PlaceNote.key(for:))
        let coordinate = item.effectiveCoordinate
        return candidates
            .filter { other in
                guard other.id != item.id, let otherDate = other.effectiveCaptureDate,
                      abs(otherDate.timeIntervalSince(date)) <= window else { return false }
                if let name, !name.isEmpty, other.effectivePlaceName.map(PlaceNote.key(for:)) == name { return true }
                if let coordinate, let otherCoordinate = other.effectiveCoordinate {
                    return distance(coordinate, otherCoordinate) <= radius
                }
                return false
            }
            .sorted { ($0.effectiveCaptureDate ?? .distantPast, $0.id) < ($1.effectiveCaptureDate ?? .distantPast, $1.id) }
            .map(\.id)
    }

    static func distance(_ a: (latitude: Double, longitude: Double), _ b: (latitude: Double, longitude: Double)) -> Double {
        let radians = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * radians
        let dLon = (b.longitude - a.longitude) * radians
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * radians) * cos(b.latitude * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371_000 * 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    public static func context(for note: PhotoNote, item: MediaItem) -> NoteOrganizerContext {
        NoteOrganizerContext(
            noteText: note.text,
            date: item.effectiveCaptureDate.map { $0.formatted(date: .long, time: .shortened) },
            placeName: item.effectivePlaceName
        )
    }

    /// Writes the suggestions with the given IDs and marks them accepted;
    /// suggestions already decided are left alone. Returns how many were written.
    @discardableResult
    public static func accept(
        _ suggestionIDs: Set<String>,
        of note: PhotoNote,
        item: MediaItem,
        context: ModelContext,
        now: Date = .now
    ) throws -> Int {
        var suggestions = note.suggestions
        var record = note.undoRecord
        var written = 0
        for index in suggestions.indices where suggestionIDs.contains(suggestions[index].id) && suggestions[index].decision == .pending {
            let suggestion = suggestions[index]
            switch suggestion.kind {
            case .placeCorrection:
                var targets = [item]
                if suggestion.applyToNearby, !suggestion.nearbyMediaIDs.isEmpty {
                    let ids = Set(suggestion.nearbyMediaIDs)
                    targets += try context.fetch(FetchDescriptor<MediaItem>()).filter { ids.contains($0.id) }
                }
                for target in targets {
                    record.overrides.append(setPlaceName(suggestion.text, on: target, context: context, now: now))
                }
            case .placeDescription:
                guard let place = suggestion.placeName else { continue }
                record.placeNotes.append(try writePlaceDescription(suggestion.text, place: place, noteID: note.id, context: context, now: now))
            case .memory:
                let scope = suggestion.scope ?? .photo
                if scope == .photo || (scope == .day && item.effectiveCaptureDate == nil) || (scope == .trip && item.tripID == nil) {
                    record.memories.append(writePhotoMemory(suggestion.text, on: item, context: context, now: now))
                } else {
                    let key = scope == .day ? PhotoNoteDay.key(for: item.effectiveCaptureDate!) : item.tripID!
                    let memory = CollectionMemory(scope: scope, scopeKey: key, text: suggestion.text, createdAt: now, sourceNoteID: note.id)
                    context.insert(memory)
                    record.collectionMemoryIDs.append(memory.id)
                }
            }
            suggestions[index].decision = .accepted
            written += 1
        }
        note.suggestions = suggestions
        note.undoRecord = record
        settleStatus(note, now: now)
        return written
    }

    public static func reject(_ suggestionID: String, of note: PhotoNote, now: Date = .now) {
        var suggestions = note.suggestions
        guard let index = suggestions.firstIndex(where: { $0.id == suggestionID && $0.decision == .pending }) else { return }
        suggestions[index].decision = .rejected
        note.suggestions = suggestions
        settleStatus(note, now: now)
    }

    /// Reverses every write made from the note, newest first, and puts its
    /// suggestions back to pending so the person can choose again.
    public static func undo(_ note: PhotoNote, context: ModelContext, now: Date = .now) throws {
        let record = note.undoRecord
        if !record.collectionMemoryIDs.isEmpty {
            let ids = Set(record.collectionMemoryIDs)
            for memory in try context.fetch(FetchDescriptor<CollectionMemory>()) where ids.contains(memory.id) {
                context.delete(memory)
            }
        }
        if !record.memories.isEmpty {
            let memories = try context.fetch(FetchDescriptor<Memory>())
            for change in record.memories.reversed() {
                guard let memory = memories.first(where: { $0.id == change.recordID }) else { continue }
                if change.created {
                    context.delete(memory)
                } else {
                    context.insert(MemoryRevision(
                        text: memory.text,
                        editedBy: MomentsAccount.localID,
                        editedAt: now,
                        baseRevision: memory.revision,
                        reason: "photo-note-undo",
                        memory: memory
                    ))
                    memory.text = change.previousText ?? ""
                    memory.updatedAt = now
                    memory.updatedBy = MomentsAccount.localID
                    memory.revision += 1
                }
            }
        }
        if !record.placeNotes.isEmpty {
            let placeNotes = try context.fetch(FetchDescriptor<PlaceNote>())
            for change in record.placeNotes.reversed() {
                guard let placeNote = placeNotes.first(where: { $0.id == change.recordID }) else { continue }
                if change.created {
                    context.delete(placeNote)
                } else {
                    placeNote.text = change.previousText ?? ""
                    placeNote.updatedAt = now
                }
            }
        }
        if !record.overrides.isEmpty {
            let ids = Set(record.overrides.map(\.mediaID))
            let items = try context.fetch(FetchDescriptor<MediaItem>()).filter { ids.contains($0.id) }
            for change in record.overrides.reversed() {
                guard let target = items.first(where: { $0.id == change.mediaID }),
                      let override = target.localPlaceOverride else { continue }
                if change.created {
                    context.delete(override)
                } else {
                    override.nameOverride = change.previousName
                    override.updatedAt = now
                    override.updatedBy = MomentsAccount.localID
                }
                target.updatedAt = now
            }
        }
        var suggestions = note.suggestions
        for index in suggestions.indices where suggestions[index].decision == .accepted {
            suggestions[index].decision = .pending
        }
        note.suggestions = suggestions
        note.undoRecord = PhotoNoteUndoRecord()
        note.status = suggestions.contains { $0.decision == .pending } ? .ready : .done
        note.updatedAt = now
    }

    private static func settleStatus(_ note: PhotoNote, now: Date) {
        note.status = note.suggestions.contains { $0.decision == .pending } ? .ready : .done
        note.updatedAt = now
    }

    private static func setPlaceName(_ name: String, on item: MediaItem, context: ModelContext, now: Date) -> PhotoNoteUndoRecord.OverrideChange {
        item.updatedAt = now
        item.updatedBy = MomentsAccount.localID
        if let existing = item.localPlaceOverride {
            let change = PhotoNoteUndoRecord.OverrideChange(mediaID: item.id, previousName: existing.nameOverride, created: false)
            existing.nameOverride = name
            existing.updatedAt = now
            existing.updatedBy = MomentsAccount.localID
            return change
        }
        context.insert(PlaceOverride(mediaID: item.id, nameOverride: name, updatedAt: now, updatedBy: MomentsAccount.localID, mediaItem: item))
        return PhotoNoteUndoRecord.OverrideChange(mediaID: item.id, previousName: nil, created: true)
    }

    private static func writePlaceDescription(_ text: String, place: String, noteID: String, context: ModelContext, now: Date) throws -> PhotoNoteUndoRecord.TextChange {
        let key = PlaceNote.key(for: place)
        let mine = try context.fetch(FetchDescriptor<PlaceNote>())
            .first { $0.placeKey == key && $0.authorAccountID == MomentsAccount.localID }
        if let mine {
            let change = PhotoNoteUndoRecord.TextChange(recordID: mine.id, previousText: mine.text, created: false)
            mine.text = appending(text, to: mine.text)
            mine.updatedAt = now
            return change
        }
        let placeNote = PlaceNote(placeName: place, text: text, updatedAt: now, sourceNoteID: noteID)
        context.insert(placeNote)
        return PhotoNoteUndoRecord.TextChange(recordID: placeNote.id, previousText: nil, created: true)
    }

    /// Adds to this person's own memory on the photo, or starts one. A
    /// partner's memory is never edited.
    private static func writePhotoMemory(_ text: String, on item: MediaItem, context: ModelContext, now: Date) -> PhotoNoteUndoRecord.TextChange {
        let mine = item.memories
            .filter { $0.authorAccountID == MomentsAccount.localID || ($0.authorAccountID == nil && $0.author == .me) }
            .max { $0.updatedAt < $1.updatedAt }
        if let mine, !mine.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let change = PhotoNoteUndoRecord.TextChange(recordID: mine.id, previousText: mine.text, created: false)
            context.insert(MemoryRevision(
                text: mine.text,
                editedBy: MomentsAccount.localID,
                editedAt: now,
                baseRevision: mine.revision,
                reason: "photo-note",
                memory: mine
            ))
            mine.text = appending(text, to: mine.text)
            mine.updatedAt = now
            mine.updatedBy = MomentsAccount.localID
            mine.revision += 1
            return change
        }
        let memory = Memory(
            text: text,
            author: .me,
            authorAccountID: MomentsAccount.localID,
            createdAt: now,
            updatedAt: now,
            updatedBy: MomentsAccount.localID,
            mediaItem: item
        )
        context.insert(memory)
        return PhotoNoteUndoRecord.TextChange(recordID: memory.id, previousText: nil, created: true)
    }

    private static func appending(_ text: String, to existing: String) -> String {
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard !trimmed.contains(text) else { return existing }
        return trimmed + "\n" + text
    }
}

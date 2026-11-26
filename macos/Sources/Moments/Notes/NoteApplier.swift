import Foundation
import SwiftData

/// Every write an old AI-organized note made. Kept so those notes still
/// load; it tells which notes already wrote a memory.
public struct PhotoNoteUndoRecord: Codable, Equatable, Sendable {
    public struct OverrideChange: Codable, Equatable, Sendable {
        public var mediaID: String
        public var previousName: String?
        public var created: Bool
        /// The name the note wrote; undo leaves a later, different name alone.
        public var writtenName: String?
    }

    public struct TextChange: Codable, Equatable, Sendable {
        public var recordID: String
        public var previousText: String?
        public var created: Bool
        /// The text after the note's write; undo leaves later edits alone.
        public var writtenText: String?
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

    /// The photo's own local day when import recorded one and the date was not
    /// corrected since, so day memories don't move with the Mac's time zone.
    public static func key(for item: MediaItem) -> String? {
        if item.userCorrectedCaptureDateUTC == nil, let local = item.localDayKey, local.count == 10 {
            return local
        }
        return item.effectiveCaptureDate.map { key(for: $0) }
    }
}

public enum NoteApplier {
    /// Words written into this person's own memory on the photo: added on a
    /// new line, or a new memory.
    @discardableResult
    public static func writeOwnWords(_ text: String, on item: MediaItem, context: ModelContext, now: Date = .now) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return writePhotoMemory(trimmed, on: item, context: context, now: now).recordID
    }

    /// Adds to this person's own memory on the photo, or starts one. A
    /// partner's memory is never edited.
    private static func writePhotoMemory(_ text: String, on item: MediaItem, context: ModelContext, now: Date) -> PhotoNoteUndoRecord.TextChange {
        if let mine = item.ownMemory, !mine.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let previous = mine.text
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
            return PhotoNoteUndoRecord.TextChange(recordID: mine.id, previousText: previous, created: false, writtenText: mine.text)
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
        return PhotoNoteUndoRecord.TextChange(recordID: memory.id, previousText: nil, created: true, writtenText: text)
    }

    private static func appending(_ text: String, to existing: String) -> String {
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard !trimmed.contains(text) else { return existing }
        return trimmed + "\n" + text
    }
}

import Foundation
import SwiftData

/// What a person typed on the ruled line under one photo. The original words
/// are always kept; the AI's suggestions and what was written from them are
/// stored next to them so nothing changes without the person's say-so and
/// every applied change can be undone.
@Model
public final class PhotoNote {
    public var id: String
    public var mediaID: String
    public var authorAccountID: String
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date
    public var statusRaw: String
    public var suggestionsData: Data?
    /// Which model organized the note, shown next to the suggestions.
    public var organizerLabel: String?
    /// Why organizing did not happen or failed, in the person's language.
    public var failureReason: String?
    /// A ``PhotoNoteUndoRecord`` describing every write made from this note.
    public var undoData: Data?

    public init(
        id: String = UUID().uuidString,
        mediaID: String,
        authorAccountID: String = MomentsAccount.localID,
        text: String,
        createdAt: Date = .now,
        status: PhotoNoteStatus = .organizing
    ) {
        self.id = id
        self.mediaID = mediaID
        self.authorAccountID = authorAccountID
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.statusRaw = status.rawValue
    }

    public var status: PhotoNoteStatus {
        get { PhotoNoteStatus(rawValue: statusRaw) ?? .waiting }
        set { statusRaw = newValue.rawValue }
    }

    public var suggestions: [NoteSuggestion] {
        get { suggestionsData.flatMap { try? JSONDecoder().decode([NoteSuggestion].self, from: $0) } ?? [] }
        set { suggestionsData = try? JSONEncoder().encode(newValue) }
    }

    public var undoRecord: PhotoNoteUndoRecord {
        get { undoData.flatMap { try? JSONDecoder().decode(PhotoNoteUndoRecord.self, from: $0) } ?? PhotoNoteUndoRecord() }
        set { undoData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }
}

/// A description of a place, written from a note. Keyed by the normalized
/// place name so it follows corrections made by name.
@Model
public final class PlaceNote {
    public var id: String
    public var placeKey: String
    public var placeName: String
    public var text: String
    public var authorAccountID: String
    public var updatedAt: Date
    public var sourceNoteID: String?

    public init(
        id: String = UUID().uuidString,
        placeName: String,
        text: String,
        authorAccountID: String = MomentsAccount.localID,
        updatedAt: Date = .now,
        sourceNoteID: String? = nil
    ) {
        self.id = id
        self.placeKey = Self.key(for: placeName)
        self.placeName = placeName
        self.text = text
        self.authorAccountID = authorAccountID
        self.updatedAt = updatedAt
        self.sourceNoteID = sourceNoteID
    }

    public static func key(for placeName: String) -> String {
        placeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// A memory about a whole day or a whole trip rather than one photo.
@Model
public final class CollectionMemory {
    public var id: String
    public var scopeRaw: String
    /// `yyyy-MM-dd` for a day, the trip ID for a trip.
    public var scopeKey: String
    public var text: String
    public var authorAccountID: String
    public var createdAt: Date
    public var updatedAt: Date
    public var sourceNoteID: String?

    public init(
        id: String = UUID().uuidString,
        scope: NoteMemoryScope,
        scopeKey: String,
        text: String,
        authorAccountID: String = MomentsAccount.localID,
        createdAt: Date = .now,
        sourceNoteID: String? = nil
    ) {
        self.id = id
        self.scopeRaw = scope.rawValue
        self.scopeKey = scopeKey
        self.text = text
        self.authorAccountID = authorAccountID
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.sourceNoteID = sourceNoteID
    }

    public var scope: NoteMemoryScope {
        NoteMemoryScope(rawValue: scopeRaw) ?? .day
    }
}

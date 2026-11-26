import Foundation

// The shapes an old AI-organized note was stored in. Nothing writes them
// any more; they stay so notes already in a library still load.

public enum PhotoNoteStatus: String, Codable, Sendable {
    /// Saved, the model is working on it.
    case organizing
    /// Suggestions are waiting for the person.
    case ready
    /// Every suggestion was decided.
    case done
    /// The model found nothing to organize; only the original words are kept.
    case nothingFound
    /// No model was available; the words are kept to organize later.
    case waiting
    case failed
}

public enum NoteMemoryScope: String, Codable, CaseIterable, Sendable {
    case photo
    case day
    case trip
}

public struct NoteSuggestion: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case placeCorrection
        case placeDescription
        case memory
    }

    public enum Decision: String, Codable, Sendable {
        case pending
        case accepted
        case rejected
    }

    public var id: String
    public var kind: Kind
    /// The corrected place name, the place description or the memory text.
    public var text: String
    /// For a correction: the place name the photo had.
    public var previousPlaceName: String?
    /// For a description: the place it describes.
    public var placeName: String?
    /// For a memory: where it is written.
    public var scope: NoteMemoryScope?
    /// For a correction: also correct these photos taken nearby at about the same time.
    public var applyToNearby: Bool
    public var nearbyMediaIDs: [String]
    public var decision: Decision

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        text: String,
        previousPlaceName: String? = nil,
        placeName: String? = nil,
        scope: NoteMemoryScope? = nil,
        applyToNearby: Bool = false,
        nearbyMediaIDs: [String] = [],
        decision: Decision = .pending
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.previousPlaceName = previousPlaceName
        self.placeName = placeName
        self.scope = scope
        self.applyToNearby = applyToNearby
        self.nearbyMediaIDs = nearbyMediaIDs
        self.decision = decision
    }
}

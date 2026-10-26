import Foundation

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

/// What a model returned for one note, before it becomes suggestions.
public struct NoteOrganizerResult: Codable, Equatable, Sendable {
    public var placeName: String?
    public var placeDescription: String?
    public var memory: String?
    public var memoryScope: String?

    public init(placeName: String? = nil, placeDescription: String? = nil, memory: String? = nil, memoryScope: String? = nil) {
        self.placeName = placeName
        self.placeDescription = placeDescription
        self.memory = memory
        self.memoryScope = memoryScope
    }
}

/// The only facts sent to a model: the words, the photo's date and its place name.
public struct NoteOrganizerContext: Equatable, Sendable {
    public var noteText: String
    public var date: String?
    public var placeName: String?

    public init(noteText: String, date: String? = nil, placeName: String? = nil) {
        self.noteText = noteText
        self.date = date
        self.placeName = placeName
    }
}

public enum NotePrompt {
    public static let instructions = """
    You help a person organize a note they wrote under one of their travel photos. \
    The note can mix a correction of where the photo was taken, facts about the place, \
    and their own experience. Split it into these fields:
    - placeName: the correct name of the place where this photo was taken, only if the note \
    says the current place is wrong or names the exact spot. Keep it short. Otherwise empty.
    - placeDescription: what the place itself is like or useful tips about it, in one or two \
    neutral sentences. Otherwise empty.
    - memory: the person's own experience and feelings, in their voice and mostly their own \
    words, lightly tidied. Otherwise empty.
    - memoryScope: "photo" if the memory is about this moment, "day" if about the whole day, \
    "trip" if about the whole trip.
    Use only what the note says; never add facts. Write every field in the language of the note.
    Answer with one JSON object with exactly these four string fields and nothing else.
    """

    public static func message(for context: NoteOrganizerContext) -> String {
        var lines: [String] = []
        if let date = context.date { lines.append("Photo date: \(date)") }
        lines.append("Current place name: \(context.placeName ?? "unknown")")
        lines.append("Note:")
        lines.append(context.noteText)
        return lines.joined(separator: "\n")
    }

    /// The JSON schema for providers that support structured output.
    public static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "placeName": ["type": "string"],
                "placeDescription": ["type": "string"],
                "memory": ["type": "string"],
                "memoryScope": ["type": "string", "enum": ["photo", "day", "trip"]]
            ],
            "required": ["placeName", "placeDescription", "memory", "memoryScope"],
            "additionalProperties": false
        ]
    }
}

public enum NoteOrganizerParser {
    /// Reads the first JSON object in a model's reply, tolerating code fences
    /// or a sentence around it.
    public static func parse(_ reply: String) throws -> NoteOrganizerResult {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NoteOrganizerError.badResponse
        }
        func field(_ name: String) -> String? {
            guard let value = object[name] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return NoteOrganizerResult(
            placeName: field("placeName"),
            placeDescription: field("placeDescription"),
            memory: field("memory"),
            memoryScope: field("memoryScope")
        )
    }
}

public enum NoteSuggestionBuilder {
    public static func suggestions(
        from result: NoteOrganizerResult,
        currentPlaceName: String?,
        nearbyMediaIDs: [String],
        makeID: () -> String = { UUID().uuidString }
    ) -> [NoteSuggestion] {
        var suggestions: [NoteSuggestion] = []
        let current = currentPlaceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        var describedPlace = current

        if let name = result.placeName,
           PlaceNote.key(for: name) != current.map(PlaceNote.key(for:)) {
            suggestions.append(NoteSuggestion(
                id: makeID(),
                kind: .placeCorrection,
                text: name,
                previousPlaceName: current,
                applyToNearby: !nearbyMediaIDs.isEmpty,
                nearbyMediaIDs: nearbyMediaIDs
            ))
            describedPlace = name
        }

        // A description needs a place to belong to.
        if let description = result.placeDescription, let place = describedPlace, !place.isEmpty {
            suggestions.append(NoteSuggestion(id: makeID(), kind: .placeDescription, text: description, placeName: place))
        }

        if let memory = result.memory {
            let scope = result.memoryScope.flatMap(NoteMemoryScope.init(rawValue:)) ?? .photo
            suggestions.append(NoteSuggestion(id: makeID(), kind: .memory, text: memory, scope: scope))
        }
        return suggestions
    }
}

public enum NoteOrganizerError: LocalizedError, Equatable {
    /// No model can run right now; the note waits.
    case unavailable(String)
    case missingKey
    case badResponse
    case refused
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .missingKey:
            return String(localized: "Add an API key in Settings › AI Model.")
        case .badResponse:
            return String(localized: "The model's answer could not be read.")
        case .refused:
            return String(localized: "The model declined to organize this note.")
        case .http(let status, let message):
            return message.isEmpty ? String(localized: "The cloud model returned an error (\(status)).") : "\(status): \(message)"
        }
    }
}

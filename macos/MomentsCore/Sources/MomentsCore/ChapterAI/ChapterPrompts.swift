import Foundation

/// The words sent to the model for organizing chapters, and the shapes of
/// its answers. Kept here, next to their parsers, so tests read the same text.
public enum ChapterPrompts {
    // MARK: Describing photos

    public static func captionInstructions(language: String) -> String {
        """
        You describe photos for a photo album app, so that later the days can be grouped into chapters such as trips, events and celebrations. Each photo comes right after a label with its number, local time and place.

        For each photo write one short caption in \(language), at most about 15 Chinese characters or 10 words: what is happening and where (the scene, the activity, notable things), with any clue that marks an occasion, such as a cake with candles, a wedding dress, an airport gate, a hotel room, a stage, a diploma, moving boxes or a hospital. When there are people, say how many, but never guess who they are, their names, ages or other personal traits.

        Also pick its kind: people, scenery, city, food, animal, object, document (papers, receipts, tickets, screens and screenshots), or other. Answer for every photo number, in order.
        """
    }

    /// The label in front of each photo, e.g. "Photo 3 · 14:05 · Kyoto, Gion".
    public static func captionLabel(number: Int, time: String?, place: String?) -> String {
        (["Photo \(number)"] + [time, place].compactMap { $0?.isEmpty == false ? $0 : nil }).joined(separator: " · ")
    }

    public static let captionKinds = ["people", "scenery", "city", "food", "animal", "object", "document", "other"]

    public static var captionSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "photos": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "n": ["type": "integer"],
                            "caption": ["type": "string"],
                            "kind": ["type": "string", "enum": captionKinds]
                        ],
                        "required": ["n", "caption", "kind"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["photos"],
            "additionalProperties": false
        ]
    }

    public struct Caption: Codable, Equatable, Sendable {
        public var text: String
        public var kind: String

        public init(text: String, kind: String) {
            self.text = text
            self.kind = kind
        }

        public var isDocument: Bool { kind == "document" }
    }

    private struct CaptionAnswer: Decodable {
        struct Photo: Decodable {
            var n: Int?
            var caption: String?
            var kind: String?
        }
        var photos: [Photo]
    }

    /// Captions by photo number, 1...count; numbers outside that are ignored.
    public static func parseCaptions(_ text: String, count: Int) throws -> [Int: Caption] {
        guard let data = ChapterPlan.jsonObjectText(text).data(using: .utf8),
              let answer = try? JSONDecoder().decode(CaptionAnswer.self, from: data) else { throw ChapterPlanError.notJSON }
        var result: [Int: Caption] = [:]
        for photo in answer.photos {
            guard let number = photo.n, (1...max(count, 1)).contains(number),
                  let caption = photo.caption?.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces),
                  !caption.isEmpty else { continue }
            let kind = photo.kind.map { $0.lowercased() }.flatMap { captionKinds.contains($0) ? $0 : nil } ?? "other"
            result[number] = Caption(text: String(caption.prefix(80)), kind: kind)
        }
        return result
    }

    // MARK: Finding chapters

    public static func chapterInstructions(language: String) -> String {
        """
        You turn a person's photo library into chapters for their photo album app. Each input line is one day with photos, oldest first (days without photos are left out). A line has the date and weekday; "away" when the photos are far from every place the person usually lives or works, otherwise "usual places"; place names; counts; people recognised by name; the person's own notes; short descriptions of what the photos show ("seen"); and hints from simple rules: a numbered trip candidate, or "big day" when far more photos than usual were taken. A line starting with two dates sums up a run of ordinary days at the usual places.

        Find the stretches worth a chapter:
        - trip: time away from the usual places, from the first day away to the last, usually with the travel days. A trip through several cities is one chapter. A day trip only when the photos show an outing (sightseeing, a hike, a visit), not errands or work.
        - event: one to a few days at or near the usual places that stand out, such as a wedding, a concert, a graduation, moving house, a big family gathering or a newborn coming home.
        - celebration: a birthday, an anniversary, or a holiday celebrated (New Year, Spring Festival, Christmas, Mid-Autumn and the like).
        - period: a longer stretch with one theme, such as renovating a flat or a baby's first month. Use it rarely.

        Ordinary daily life is not a chapter: most days belong to no chapter. Leave a day out when unsure. Never invent what the lines do not show. The rule hints can be wrong; trust the descriptions, places and notes over them. Days marked "fixed" are already in a chapter the person made, so do not make another chapter of the same kind over them.

        title: short and specific, like an album title, in \(language): where and what, at most about 12 Chinese characters or 6 words, with no dates or years. summary: one sentence in \(language) about what happened, taken from the lines only. confidence: how sure you are that this is a chapter with these dates. Dates are yyyy-MM-dd and both ends are included.
        """
    }

    public static func chapterMessage(_ window: ChapterDigest.Window) -> String {
        "Days from \(window.firstDay) to \(window.lastDay):\n\n" + window.text
    }

    public static var chapterSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "chapters": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "start": ["type": "string"],
                            "end": ["type": "string"],
                            "type": ["type": "string", "enum": ChapterProposal.Kind.allCases.map(\.rawValue)],
                            "title": ["type": "string"],
                            "summary": ["type": "string"],
                            "confidence": ["type": "string", "enum": ["high", "medium", "low"]]
                        ],
                        "required": ["start", "end", "type", "title", "summary", "confidence"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["chapters"],
            "additionalProperties": false
        ]
    }
}

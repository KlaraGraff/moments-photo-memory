import Foundation
import MomentsCore
import SwiftData

/// What kind of stretch of life a chapter is. Trips are stored as `Trip`
/// (one trip per photo, with route maps and the import's trip finding);
/// every other kind is a `UserGroup` of kind `.chapter`, whose photos may
/// also be in a trip or another chapter.
enum ChapterType: Hashable, Identifiable {
    case trip
    case event
    case celebration
    case period
    /// A tag someone typed, like "Moving house".
    case custom(String)

    static let presets: [ChapterType] = [.trip, .event, .celebration, .period]

    var id: String { raw }

    var raw: String {
        switch self {
        case .trip: "trip"
        case .event: "event"
        case .celebration: "celebration"
        case .period: "period"
        case let .custom(label): "custom:" + label
        }
    }

    init(raw: String) {
        switch raw {
        case "trip": self = .trip
        case "event": self = .event
        case "celebration": self = .celebration
        case "period": self = .period
        default:
            let label = raw.hasPrefix("custom:") ? String(raw.dropFirst("custom:".count)) : raw
            self = label.isEmpty ? .period : .custom(label)
        }
    }

    var label: String {
        switch self {
        case .trip: String(localized: "Trip")
        case .event: String(localized: "Event")
        case .celebration: String(localized: "Celebration")
        case .period: String(localized: "A stretch of time")
        case let .custom(label): label
        }
    }

    /// The plural, for the filter above the cards.
    var filterLabel: String {
        switch self {
        case .trip: String(localized: "Trips")
        case .event: String(localized: "Events")
        case .celebration: String(localized: "Celebrations")
        case .period: String(localized: "Stretches of time")
        case let .custom(label): label
        }
    }

    var defaultSymbol: String {
        switch self {
        case .trip: "airplane.departure"
        case .event: "music.mic"
        case .celebration: "gift"
        case .period: "sun.horizon"
        case .custom: "tag"
        }
    }

    /// Symbols offered for a custom tag.
    static let customSymbols = ["tag", "heart", "house", "graduationcap", "leaf", "pawprint", "star", "figure.2.and.child.holdinghands", "fork.knife", "camera"]
}

/// A chapter's own details, kept in its group's `rulesData` under a
/// `chapter` key so it can never be read as smart-group rules.
struct ChapterInfo: Codable, Equatable {
    var type: String
    var symbol: String?
    var startDate: Date?
    var endDate: Date?
    /// One sentence about what happened, written by the model.
    var summary: String? = nil
    /// "ai" for a chapter the model made.
    var madeBy: String? = nil

    private struct Envelope: Codable {
        var chapter: ChapterInfo
    }

    static func decode(_ data: Data) -> ChapterInfo? {
        (try? JSONDecoder().decode(Envelope.self, from: data))?.chapter
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(Envelope(chapter: self))) ?? Data()
    }
}

extension UserGroup {
    var isChapter: Bool { kindRaw == UserGroup.Kind.chapter.rawValue }

    var chapterInfo: ChapterInfo {
        get { ChapterInfo.decode(rulesData) ?? ChapterInfo(type: ChapterType.period.raw) }
        set { rulesData = newValue.encoded() }
    }

    var chapterType: ChapterType { ChapterType(raw: chapterInfo.type) }

    var chapterSymbol: String { chapterInfo.symbol ?? chapterType.defaultSymbol }
}

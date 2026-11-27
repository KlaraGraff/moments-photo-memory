import Foundation

/// What a stretch of photos away from daily life was. The judge picks one of
/// these for every suggested chapter.
///
/// The built-in kinds cover what most libraries hold. `custom` carries a type
/// the person named themselves ("project visit"); the judge offers it again
/// for similar days once it has been used.
public enum ChapterKind: Hashable, Sendable {
    /// Time away for its own sake: a holiday, a weekend away.
    case trip
    /// Time away for work.
    case businessTrip
    /// Time back home with family: home leave, a visit to the home town.
    case homeVisit
    /// Not a chapter at all: ordinary days that only looked like time away.
    case daily
    /// A type the person named.
    case custom(String)

    /// The kinds every library starts with, in the order they are offered.
    public static let builtIn: [ChapterKind] = [.trip, .businessTrip, .homeVisit]

    /// A stable key for storage and for the model's answer.
    public var key: String {
        switch self {
        case .trip: return "trip"
        case .businessTrip: return "businessTrip"
        case .homeVisit: return "homeVisit"
        case .daily: return "daily"
        case let .custom(label): return "custom:" + label
        }
    }

    public init?(key: String) {
        switch key {
        case "trip": self = .trip
        case "businessTrip": self = .businessTrip
        case "homeVisit": self = .homeVisit
        case "daily": self = .daily
        default:
            guard key.hasPrefix("custom:") else { return nil }
            let label = Self.cleanLabel(String(key.dropFirst("custom:".count)))
            guard let label else { return nil }
            self = .custom(label)
        }
    }

    /// A chapter is kept for every kind but `daily`.
    public var isChapter: Bool { self != .daily }

    public var customLabel: String? {
        if case let .custom(label) = self { return label }
        return nil
    }

    /// Trims a label the person typed. Empty labels and labels longer than
    /// 24 characters are no type.
    public static func cleanLabel(_ raw: String) -> String? {
        let label = raw
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 24 else { return nil }
        return label
    }
}

extension ChapterKind: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let key = try container.decode(String.self)
        guard let kind = ChapterKind(key: key) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown chapter kind \(key)")
        }
        self = kind
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }
}

/// How sure the judge is.
public enum JudgeConfidence: String, Codable, Comparable, CaseIterable, Sendable {
    case low, medium, high

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (lhs: JudgeConfidence, rhs: JudgeConfidence) -> Bool { lhs.rank < rhs.rank }

    public var lower: JudgeConfidence { self == .high ? .medium : .low }
    public var higher: JudgeConfidence { self == .low ? .medium : .high }
}

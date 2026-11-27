import Foundation

/// Who decided a chapter's kind.
public enum VerdictSource: String, Codable, Sendable {
    /// The fixed rules on this Mac.
    case rules
    /// A language model, on this Mac or one the person connected.
    case model
    /// The person: they answered, confirmed or changed it.
    case person
}

/// One fact behind a verdict. The app turns each into a sentence.
public enum JudgeReason: Codable, Equatable, Sendable {
    /// All of the days are workdays.
    case allWorkdays(days: Int)
    /// The stretch takes in a weekend.
    case weekend(weekendDays: Int, days: Int)
    /// Of the photos looked at, this many show work.
    case workScenes(count: Int, of: Int)
    /// Of the photos looked at, this many show leisure.
    case leisureScenes(count: Int, of: Int)
    /// Most photos were taken in working hours.
    case workHours
    /// Most photos were taken outside working hours.
    case freeHours
    /// The distance from where the person lives or works.
    case farFromBase(km: Int, role: PlaceRole)
    case nearBase(km: Int, role: PlaceRole)
    /// Near the person's home town.
    case nearHomeTown(km: Int)
    case abroad
    /// A long stay, in days.
    case longStay(days: Int)
    /// Only a day or so.
    case shortVisit(days: Int)
    /// Few photos each day, as on working days.
    case fewPhotos(perDay: Int)
    /// Many photos each day, as on a holiday.
    case manyPhotos(perDay: Int)
    /// A stretch the person decided before looks much the same.
    case similar(title: String, kind: ChapterKind, start: Date, corrected: Bool)
}

/// The judge's answer for one stretch of photos.
public struct ChapterVerdict: Codable, Equatable, Sendable {
    public var kind: ChapterKind
    public var confidence: JudgeConfidence
    public var source: VerdictSource
    /// The next most likely kinds, most likely first. Never holds `kind`.
    public var alternatives: [ChapterKind]
    /// The facts that point to `kind`, strongest first.
    public var reasons: [JudgeReason]
    /// The model's own one-line reason, in the person's language.
    public var modelReason: String?

    public init(
        kind: ChapterKind,
        confidence: JudgeConfidence,
        source: VerdictSource,
        alternatives: [ChapterKind] = [],
        reasons: [JudgeReason] = [],
        modelReason: String? = nil
    ) {
        self.kind = kind
        self.confidence = confidence
        self.source = source
        self.alternatives = alternatives.filter { $0 != kind }
        self.reasons = reasons
        self.modelReason = modelReason
    }

    /// The person's own answer.
    public static func person(_ kind: ChapterKind) -> ChapterVerdict {
        ChapterVerdict(kind: kind, confidence: .high, source: .person)
    }
}

/// How often the judge asks when it is not sure.
public enum AskLevel: String, Codable, CaseIterable, Sendable {
    case more, balanced, less
}

/// What happens with a verdict.
public enum JudgeAction: Equatable, Sendable {
    /// Use the kind and say nothing.
    case apply
    /// Use the kind, and ask in one line on the chapter whether it is right.
    case applyAndCheck
    /// Keep the chapter as it is and ask the person what it was.
    case ask
}

public enum ConfidencePolicy {
    public static func action(for verdict: ChapterVerdict, level: AskLevel) -> JudgeAction {
        if verdict.source == .person { return .apply }
        let action: JudgeAction
        switch (level, verdict.confidence) {
        case (_, .high): action = .apply
        case (.more, .medium): action = .ask
        case (.balanced, .medium): action = .applyAndCheck
        case (.less, .medium): action = .apply
        case (.less, .low): action = .applyAndCheck
        case (_, .low): action = .ask
        }
        // Calling a stretch ordinary days removes its chapter, and a chapter
        // that is gone cannot carry the one-line check: so it is either sure
        // enough to remove, or a question.
        if verdict.kind == .daily {
            return verdict.confidence == .high ? .apply : .ask
        }
        return action
    }
}

import Foundation

/// One chapter the model proposes, by day.
public struct ChapterProposal: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case trip
        case event
        case celebration
        case period
    }

    public var start: String
    public var end: String
    public var type: Kind
    public var title: String
    public var summary: String
    public var confidence: String

    public init(start: String, end: String, type: Kind, title: String, summary: String = "", confidence: String = "medium") {
        self.start = start
        self.end = end
        self.type = type
        self.title = title
        self.summary = summary
        self.confidence = confidence
    }

    public var days: Int { DayKey.length(from: start, to: end) }

    public func overlaps(_ other: ChapterProposal) -> Bool {
        start <= other.end && other.start <= end
    }

    /// Shared days over the shorter of the two.
    public func overlapShare(with other: ChapterProposal) -> Double {
        let first = max(start, other.start)
        let last = min(end, other.end)
        let shared = DayKey.length(from: first, to: last)
        let shorter = min(days, other.days)
        return shorter > 0 ? Double(shared) / Double(shorter) : 0
    }
}

public enum ChapterPlanError: Error, Equatable {
    case notJSON
}

/// Reads the model's answer and puts the windows' answers together.
public enum ChapterPlan {
    /// Longest chapters kept, by kind; anything longer is a misreading.
    public static let maximumDays: [ChapterProposal.Kind: Int] = [.trip: 120, .event: 7, .celebration: 4, .period: 400]

    private struct Answer: Decodable {
        struct Chapter: Decodable {
            var start: String?
            var end: String?
            var type: String?
            var title: String?
            var summary: String?
            var confidence: String?
        }
        var chapters: [Chapter]
    }

    /// The proposals in `text` that make sense inside `firstDay...lastDay`.
    public static func parse(_ text: String, firstDay: String, lastDay: String) throws -> [ChapterProposal] {
        guard let data = jsonObjectText(text).data(using: .utf8),
              let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw ChapterPlanError.notJSON }
        return answer.chapters.compactMap { chapter in
            guard var start = chapter.start?.trimmingCharacters(in: .whitespaces), DayKey.ordinal(start) != nil,
                  var end = chapter.end?.trimmingCharacters(in: .whitespaces), DayKey.ordinal(end) != nil,
                  let kind = chapter.type.flatMap({ ChapterProposal.Kind(rawValue: $0.lowercased()) }) else { return nil }
            if end < start { swap(&start, &end) }
            start = max(start, firstDay)
            end = min(end, lastDay)
            guard start <= end else { return nil }
            let title = clean(chapter.title ?? "", limit: 40)
            guard !title.isEmpty else { return nil }
            let proposal = ChapterProposal(
                start: start,
                end: end,
                type: kind,
                title: title,
                summary: clean(chapter.summary ?? "", limit: 200),
                confidence: chapter.confidence ?? "medium"
            )
            guard proposal.days <= maximumDays[kind, default: 400] else { return nil }
            return proposal
        }
    }

    /// One list from every window's answer, oldest first. Trips never
    /// overlap (a photo is in one trip): overlapping trips, such as one cut
    /// at a window's edge and seen whole by the next, become one. Other
    /// kinds may overlap a trip or each other, but the same chapter seen
    /// by two windows is kept once.
    public static func merge(_ answers: [[ChapterProposal]]) -> [ChapterProposal] {
        let all = answers.flatMap { $0 }
        var trips: [ChapterProposal] = []
        for trip in all.filter({ $0.type == .trip }).sorted(by: order) {
            if let last = trips.last, last.overlaps(trip) || DayKey.adding(1, to: last.end) == trip.start && last.title == trip.title {
                // The longer view names it.
                var joined = trip.days > last.days ? trip : last
                joined.start = min(last.start, trip.start)
                joined.end = max(last.end, trip.end)
                trips[trips.count - 1] = joined
            } else {
                trips.append(trip)
            }
        }
        var others: [ChapterProposal] = []
        for proposal in all.filter({ $0.type != .trip }).sorted(by: order) {
            if let index = others.firstIndex(where: { $0.type == proposal.type && $0.overlapShare(with: proposal) >= 0.5 }) {
                let kept = others[index]
                if proposal.days > kept.days { others[index] = proposal }
            } else {
                others.append(proposal)
            }
        }
        // An event inside a trip is part of the trip.
        let kept = others.filter { other in
            other.type == .period || !trips.contains { $0.start <= other.start && other.end <= $0.end }
        }
        return (trips + kept).sorted(by: order)
    }

    private static func order(_ a: ChapterProposal, _ b: ChapterProposal) -> Bool {
        (a.start, a.end, a.type.rawValue, a.title) < (b.start, b.end, b.type.rawValue, b.title)
    }

    private static func clean(_ text: String, limit: Int) -> String {
        let single = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return single.count > limit ? String(single.prefix(limit)) : single
    }

    /// The outermost `{…}` in a reply, in case words came around it.
    static func jsonObjectText(_ text: String) -> String {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return text }
        return String(text[open...close])
    }
}

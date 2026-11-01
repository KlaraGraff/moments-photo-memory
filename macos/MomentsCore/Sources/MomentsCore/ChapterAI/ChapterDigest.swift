import Foundation

/// What Moments knows about one day with photos, for the model that groups
/// days into chapters. Only names and words: no coordinates, paths or ids.
public struct DayEvidence: Equatable, Sendable {
    /// `yyyy-MM-dd`, the photos' own local day.
    public var dayKey: String
    public var photos: Int
    public var videos: Int
    /// Photos more than a minute apart; a burst counts once.
    public var moments: Int
    /// Far from every usual place (`TripSegmenter`).
    public var isAway: Bool
    /// Place names in the order the day reaches them.
    public var places: [String]
    /// People recognised by name.
    public var people: [String]
    /// The person's own notes.
    public var notes: [String]
    /// What the described photos show, oldest first.
    public var captions: [String]
    /// Photos of papers, receipts, tickets or screens.
    public var documents: Int
    /// The rules' trip candidate, numbered in date order.
    public var ruleTrip: Int?
    /// Far more photos than usual (`BigDayFinder`).
    public var isBigDay: Bool
    /// The name of a chapter someone made or edited that holds this day.
    public var fixedChapter: String?

    public init(
        dayKey: String,
        photos: Int = 0,
        videos: Int = 0,
        moments: Int = 0,
        isAway: Bool = false,
        places: [String] = [],
        people: [String] = [],
        notes: [String] = [],
        captions: [String] = [],
        documents: Int = 0,
        ruleTrip: Int? = nil,
        isBigDay: Bool = false,
        fixedChapter: String? = nil
    ) {
        self.dayKey = dayKey
        self.photos = photos
        self.videos = videos
        self.moments = moments
        self.isAway = isAway
        self.places = places
        self.people = people
        self.notes = notes
        self.captions = captions
        self.documents = documents
        self.ruleTrip = ruleTrip
        self.isBigDay = isBigDay
        self.fixedChapter = fixedChapter
    }

    /// Nothing but ordinary photos at the usual places: a run of these
    /// days is summed up in one line.
    var isQuiet: Bool {
        !isAway && captions.isEmpty && notes.isEmpty && people.isEmpty
            && !isBigDay && ruleTrip == nil && fixedChapter == nil
    }
}

/// Writes the days as short lines of text and cuts them into windows small
/// enough for one request each. Neighbouring windows share a few days, so
/// a chapter at the edge of one is seen whole by the next.
public struct ChapterDigest: Sendable {
    /// Descriptions kept for a busy day, spread over the day.
    public var captionsPerDay = 12
    /// Descriptions kept for a day at the usual places with few photos.
    public var captionsPerQuietDay = 3
    /// Estimated tokens of day lines per window. Haiku 5.5 bills a prompt
    /// over 100,000 tokens at five times the price, so windows stay far below.
    public var tokenBudget = 40_000
    /// Days two neighbouring windows share.
    public var overlapDays = 6
    /// A note is cut after this many characters.
    public var noteLength = 120

    public init() {}

    public struct Window: Equatable, Sendable {
        public let text: String
        public let firstDay: String
        public let lastDay: String
        public let dayCount: Int
    }

    private struct Unit {
        let firstDay: String
        let lastDay: String
        let ordinal: Int
        let text: String
        let tokens: Int
    }

    /// One line for one day.
    public func line(for day: DayEvidence) -> String {
        var parts = [day.dayKey + " " + Self.weekday(day.dayKey), day.isAway ? "away" : "usual places"]
        if !day.places.isEmpty { parts.append(day.places.joined(separator: ", ")) }
        var counts = ["\(day.photos) photos"]
        if day.videos > 0 { counts.append("\(day.videos) videos") }
        if day.moments > 0, day.moments != day.photos + day.videos { counts.append("\(day.moments) moments") }
        parts.append(counts.joined(separator: ", "))
        if !day.people.isEmpty { parts.append("with " + day.people.joined(separator: ", ")) }
        let notes = day.notes.map { Self.clip($0, to: noteLength) }.filter { !$0.isEmpty }
        if !notes.isEmpty { parts.append("notes: " + notes.map { "\"\($0)\"" }.joined(separator: " ")) }
        let limit = !day.isAway && day.photos + day.videos <= 5 ? captionsPerQuietDay : captionsPerDay
        let captions = Self.spread(Self.distinct(day.captions), limit: limit)
        if !captions.isEmpty { parts.append("seen: " + captions.joined(separator: " | ")) }
        if day.documents > 0 { parts.append("\(day.documents) documents") }
        var hints: [String] = []
        if let trip = day.ruleTrip { hints.append("trip candidate \(trip)") }
        if day.isBigDay { hints.append("big day") }
        if !hints.isEmpty { parts.append("rules: " + hints.joined(separator: ", ")) }
        if let fixed = day.fixedChapter { parts.append("fixed: \"\(Self.clip(fixed, to: 60))\"") }
        return parts.joined(separator: " · ")
    }

    /// The days, oldest first, in windows of at most `tokenBudget`.
    public func windows(_ days: [DayEvidence]) -> [Window] {
        let units = self.units(days.filter { DayKey.ordinal($0.dayKey) != nil }.sorted { $0.dayKey < $1.dayKey })
        guard !units.isEmpty else { return [] }
        var windows: [Window] = []
        var start = 0
        while start < units.count {
            var end = start
            var tokens = units[start].tokens
            while end + 1 < units.count, tokens + units[end + 1].tokens <= tokenBudget {
                end += 1
                tokens += units[end].tokens
            }
            let slice = units[start...end]
            windows.append(Window(
                text: slice.map(\.text).joined(separator: "\n"),
                firstDay: units[start].firstDay,
                lastDay: units[end].lastDay,
                dayCount: slice.count
            ))
            guard end + 1 < units.count else { break }
            // The next window starts `overlapDays` before this one ends,
            // but always moves on by at least one line.
            let reach = units[end].ordinal - overlapDays
            var next = end + 1
            while next - 1 > start, units[next - 1].ordinal > reach { next -= 1 }
            start = max(next, start + 1)
        }
        return windows
    }

    private func units(_ days: [DayEvidence]) -> [Unit] {
        var units: [Unit] = []
        var quiet: [DayEvidence] = []
        func flushQuiet() {
            guard let first = quiet.first, let last = quiet.last else { return }
            let text: String
            if quiet.count == 1 {
                text = line(for: first)
            } else {
                let photos = quiet.reduce(0) { $0 + $1.photos + $1.videos }
                text = "\(first.dayKey) to \(last.dayKey) · usual places · \(quiet.count) days with photos, \(photos) photos in all"
            }
            units.append(Unit(firstDay: first.dayKey, lastDay: last.dayKey, ordinal: DayKey.ordinal(last.dayKey) ?? 0, text: text, tokens: Self.estimatedTokens(text) + 1))
            quiet = []
        }
        for day in days {
            if day.isQuiet {
                quiet.append(day)
                continue
            }
            flushQuiet()
            let text = line(for: day)
            units.append(Unit(firstDay: day.dayKey, lastDay: day.dayKey, ordinal: DayKey.ordinal(day.dayKey) ?? 0, text: text, tokens: Self.estimatedTokens(text) + 1))
        }
        flushQuiet()
        return units
    }

    /// A rough count that errs high: a CJK character is about one token,
    /// other text about three and a half characters a token.
    public static func estimatedTokens(_ text: String) -> Int {
        var wide = 0
        var narrow = 0
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x2E80 { wide += 1 } else { narrow += 1 }
        }
        return wide + (narrow * 2 + 6) / 7
    }

    /// Up to `limit` items spread evenly, first and last included.
    public static func spread<T>(_ items: [T], limit: Int) -> [T] {
        guard limit > 0 else { return [] }
        guard items.count > limit else { return items }
        guard limit > 1 else { return [items[items.count / 2]] }
        return (0..<limit).map { items[$0 * (items.count - 1) / (limit - 1)] }
    }

    static func distinct(_ captions: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for caption in captions {
            let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed.replacingOccurrences(of: "|", with: "/"))
        }
        return result
    }

    static func clip(_ text: String, to length: Int) -> String {
        let single = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard single.count > length else { return single }
        return String(single.prefix(length)) + "…"
    }

    static func weekday(_ key: String) -> String {
        guard let ordinal = DayKey.ordinal(key) else { return "" }
        // 1970-01-01 was a Thursday.
        let names = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"]
        return names[((ordinal % 7) + 7) % 7]
    }
}

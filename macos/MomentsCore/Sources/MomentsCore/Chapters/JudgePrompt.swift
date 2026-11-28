import Foundation

/// What a language model is asked about one stretch of photos, and how its
/// answer is read.
///
/// The model sees a short text sheet only: dates, counts, distances in
/// kilometres, the place's name and words for what the photos show. No photo
/// and no coordinate is ever part of it.
public struct JudgePrompt: Equatable, Sendable {
    public var system: String
    public var user: String
    /// The kinds the answer may name, as keys.
    public var allowedKeys: [String]

    /// - Parameters:
    ///   - language: the language the reason is written in, such as "Chinese".
    ///   - privateNames: the names of the person's own places; a place name
    ///     or title holding one stays out of the prompt.
    public static func make(
        evidence: SegmentEvidence,
        book: ChapterJudgeBook,
        language: String,
        calendar: Calendar,
        privateNames: [String] = []
    ) -> JudgePrompt {
        let names = privateNames + [evidence.baseName].compactMap { $0 }
        let kinds = book.candidates + [.daily]
        let keys = kinds.map(\.key)
        let system = """
        You sort one person's photo chapters. A trip finder grouped the photos below because they were taken \
        away from where the person usually lives or works. Decide what this stretch of days was, and choose \
        exactly one kind from the list.

        Kinds:
        - trip: time away for its own sake, such as a holiday or a weekend away.
        - businessTrip: time away for work, such as site visits, meetings or a conference.
        - homeVisit: time back home with family, such as home leave or a visit to the home town.
        - daily: not a chapter at all, ordinary days that only looked like time away.
        - custom:<name>: a kind the person named themselves.

        The person's earlier decisions are the strongest guide. When a stretch is much like one they decided, \
        choose what they chose. Dates and distances alone rarely say why someone went: when the facts point both \
        ways, answer with low confidence, and the person will be asked.

        Reply with JSON only: {"kind": one of the keys listed, "confidence": "high", "medium" or "low", \
        "reason": one short sentence in \(language), at most 20 words, naming the facts that decided it}.
        """
        var lines: [String] = ["Stretch to judge:"]
        lines += sheet(evidence, calendar: calendar, privateNames: names).map { "- " + $0 }
        let examples = book.nearestExamples(to: evidence)
        if !examples.isEmpty {
            lines.append("")
            lines.append("Their earlier decisions, most alike first:")
            for (index, example) in examples.enumerated() {
                let summary = sheet(example.evidence, calendar: calendar, privateNames: names).prefix(4).joined(separator: "; ")
                let how = example.corrected ? "they changed the judge's answer to" : "they confirmed"
                let name = example.evidence.shareable(example.title, privateNames: names).map { "\"\($0)\": " } ?? ""
                lines.append("\(index + 1). \(name)\(summary). \(how) \(example.kind.key)")
            }
        }
        lines.append("")
        lines.append("Keys to choose from: " + keys.joined(separator: ", "))
        return JudgePrompt(system: system, user: lines.joined(separator: "\n"), allowedKeys: keys)
    }

    /// The facts of one stretch, one per line, in English.
    static func sheet(_ evidence: SegmentEvidence, calendar: Calendar, privateNames: [String]) -> [String] {
        var lines: [String] = []
        let first = dayText(evidence.start, calendar: calendar)
        let last = dayText(evidence.end, calendar: calendar)
        let span = evidence.dayCount == 1 ? "1 day" : "\(evidence.dayCount) days"
        let weekend = evidence.weekendDayCount == 0 ? "no weekend day" : "\(evidence.weekendDayCount) weekend days"
        lines.append(first == last ? "Date: \(first), \(weekend)" : "Dates: \(first) to \(last), \(span), \(weekend)")
        let perDay = Int(evidence.photosPerDay.rounded())
        let workHours = Int((evidence.workHourShare * 100).rounded())
        lines.append("Photos: \(evidence.photoCount) on \(evidence.photoDayCount) days, about \(perDay) a day, \(workHours)% taken on workdays between 8:00 and 18:00")
        if let place = evidence.shareablePlaceName(privateNames: privateNames) { lines.append("Place: \(place)") }
        if let km = evidence.kmFromBase, let role = evidence.baseRole {
            let base = role == .work ? "where they work" : "where they live"
            lines.append("Distance from \(base): \(Int(km.rounded())) km")
        }
        if let km = evidence.kmFromHomeTown {
            lines.append("Distance from their home town: \(Int(km.rounded())) km")
        }
        if let abroad = evidence.isAbroad { lines.append(abroad ? "In another country than daily life" : "In the country of daily life") }
        if evidence.sceneSample > 0 {
            let sample = Double(evidence.sceneSample)
            let work = Int(((evidence.workSceneShare ?? 0) * sample).rounded())
            let leisure = Int(((evidence.leisureSceneShare ?? 0) * sample).rounded())
            var line = "Of \(evidence.sceneSample) photos looked at, \(work) show work and \(leisure) leisure"
            if !evidence.sceneWords.isEmpty { line += "; seen most: " + evidence.sceneWords.joined(separator: ", ") }
            lines.append(line)
        }
        if let title = evidence.shareableTitle(privateNames: privateNames) { lines.append("Title they gave it: \(title)") }
        return lines
    }

    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static func dayText(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let weekday = weekdays[((parts.weekday ?? 1) - 1 + 7) % 7]
        func padded(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(padded(parts.year, 4))-\(padded(parts.month, 2))-\(padded(parts.day, 2)) (\(weekday))"
    }

    /// The JSON schema of the answer, for models that take one.
    public var responseSchemaJSON: String {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": allowedKeys],
                "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
                "reason": ["type": "string"],
            ],
            "required": ["kind", "confidence", "reason"],
            "additionalProperties": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads the model's answer. Nil when it names no kind on the list.
    public func parse(_ text: String) -> ChapterVerdict? {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let data = String(text[open...close]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawKind = object["kind"] as? String,
              let kind = match(rawKind)
        else { return nil }
        let confidence = (object["confidence"] as? String)
            .flatMap { JudgeConfidence(rawValue: $0.lowercased().trimmingCharacters(in: .whitespaces)) } ?? .low
        let reason = (object["reason"] as? String).flatMap(Self.cleanReason)
        return ChapterVerdict(kind: kind, confidence: confidence, source: .model, modelReason: reason)
    }

    private func match(_ raw: String) -> ChapterKind? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if allowedKeys.contains(trimmed) { return ChapterKind(key: trimmed) }
        func plain(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let wanted = plain(trimmed)
        guard !wanted.isEmpty else { return nil }
        for key in allowedKeys {
            let label = ChapterKind(key: key)?.customLabel
            if plain(key) == wanted || label.map(plain) == wanted { return ChapterKind(key: key) }
        }
        return nil
    }

    /// One line, at most 80 characters, with no quotes around it.
    static func cleanReason(_ raw: String) -> String? {
        var line = raw.components(separatedBy: .newlines).first ?? ""
        line = line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"“”「」")))
        guard !line.isEmpty else { return nil }
        if line.count > 80 { line = String(line.prefix(79)) + "…" }
        return line
    }
}

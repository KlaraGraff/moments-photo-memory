import Foundation

/// A stretch the person decided: the judge looks at it when it meets similar days.
public struct JudgeExample: Codable, Equatable, Identifiable, Sendable {
    /// The chapter it came from.
    public var id: String
    /// What the person saw as its title.
    public var title: String
    public var evidence: SegmentEvidence
    public var kind: ChapterKind
    /// True when the person changed the judge's answer, false when they
    /// confirmed it.
    public var corrected: Bool
    public var addedAt: Date

    public init(id: String, title: String, evidence: SegmentEvidence, kind: ChapterKind, corrected: Bool, addedAt: Date) {
        self.id = id
        self.title = title
        self.evidence = evidence
        self.kind = kind
        self.corrected = corrected
        self.addedAt = addedAt
    }
}

/// What the judge decided for one chapter, and what the person did with it.
public struct StoredVerdict: Codable, Equatable, Sendable {
    public var verdict: ChapterVerdict
    /// The evidence's signature when it was judged.
    public var signature: String
    public var judgedAt: Date
    /// The person answered the one-line check, or it was put away.
    public var checkClosedAt: Date?
    /// The person chose "Later" on the question.
    public var deferredAt: Date?
    /// Someone touched the chapter, or brought it back with Undo: the judge
    /// asks before it calls it daily life, however sure it is.
    public var asksFirst = false

    public init(verdict: ChapterVerdict, signature: String, judgedAt: Date) {
        self.verdict = verdict
        self.signature = signature
        self.judgedAt = judgedAt
    }

    private enum CodingKeys: String, CodingKey { case verdict, signature, judgedAt, checkClosedAt, deferredAt, asksFirst }

    /// An entry written before a field existed reads with that field unset.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        verdict = try container.decode(ChapterVerdict.self, forKey: .verdict)
        signature = try container.decode(String.self, forKey: .signature)
        judgedAt = try container.decode(Date.self, forKey: .judgedAt)
        checkClosedAt = try container.decodeIfPresent(Date.self, forKey: .checkClosedAt)
        deferredAt = try container.decodeIfPresent(Date.self, forKey: .deferredAt)
        asksFirst = try container.decodeIfPresent(Bool.self, forKey: .asksFirst) ?? false
    }
}

/// Everything the chapter judge keeps: its settings, its verdicts and the
/// stretches it learned from. It holds no photo and no coordinate.
public struct ChapterJudgeBook: Codable, Equatable, Sendable {
    public static let maximumExamples = 200
    /// The one-line check on a chapter puts itself away after this long.
    public static let checkLifetime: TimeInterval = 5 * 24 * 60 * 60
    /// A question put off with "Later" comes back after this long.
    public static let deferLifetime: TimeInterval = 7 * 24 * 60 * 60

    public var enabled: Bool = true
    public var askLevel: AskLevel = .balanced
    /// By chapter id.
    public var verdicts: [String: StoredVerdict] = [:]
    /// Newest first.
    public var examples: [JudgeExample] = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, askLevel, verdicts, examples }

    /// Reads every field it can, so a book written by another version keeps
    /// what it has in common.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        askLevel = (try? container.decodeIfPresent(AskLevel.self, forKey: .askLevel)) ?? .balanced
        // One entry at a time: an entry this version cannot read is left
        // out, and the rest stay.
        let storedVerdicts = (try? container.decodeIfPresent([String: Lossy<StoredVerdict>].self, forKey: .verdicts)) ?? [:]
        verdicts = storedVerdicts.compactMapValues(\.value)
        let storedExamples = (try? container.decodeIfPresent([Lossy<JudgeExample>].self, forKey: .examples)) ?? []
        examples = storedExamples.compactMap(\.value)
    }

    /// An entry that may fail to decode without failing its list.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    // MARK: Reading

    /// The kinds to choose from: the built-in ones, then the person's own,
    /// most recently used first.
    public var candidates: [ChapterKind] {
        var kinds = ChapterKind.builtIn
        for example in examples.sorted(by: { $0.addedAt > $1.addedAt }) {
            if case .custom = example.kind, !kinds.contains(example.kind) { kinds.append(example.kind) }
        }
        return kinds
    }

    public func verdict(for id: String) -> ChapterVerdict? { verdicts[id]?.verdict }

    /// True when the chapter was never judged, or its photos have changed
    /// since and the person had not decided it.
    public func needsJudging(_ id: String, signature: String) -> Bool {
        guard let stored = verdicts[id] else { return true }
        if stored.verdict.source == .person { return false }
        return stored.signature != signature
    }

    public func action(for id: String) -> JudgeAction? {
        guard enabled, let stored = verdicts[id] else { return nil }
        return ConfidencePolicy.action(for: stored.verdict, level: askLevel)
    }

    /// True when the chapter waits for the person's answer now.
    public func isQuestion(_ id: String, now: Date) -> Bool {
        guard let stored = verdicts[id], action(for: id) == .ask else { return false }
        if let deferred = stored.deferredAt, now.timeIntervalSince(deferred) < Self.deferLifetime { return false }
        return true
    }

    /// True when the chapter shows the one-line check now.
    public func showsCheck(_ id: String, now: Date) -> Bool {
        guard let stored = verdicts[id], action(for: id) == .applyAndCheck, stored.checkClosedAt == nil else { return false }
        return now.timeIntervalSince(stored.judgedAt) < Self.checkLifetime
    }

    /// The kind the chapter shows: the verdict's, unless it is still a question.
    public func shownKind(for id: String) -> ChapterKind? {
        guard enabled, let stored = verdicts[id] else { return nil }
        if action(for: id) == .ask { return nil }
        return stored.verdict.kind
    }

    /// The nearest examples to a stretch, for the model, closest first.
    public func nearestExamples(to evidence: SegmentEvidence, limit: Int = 5) -> [JudgeExample] {
        examples
            .map { ($0, RuleJudge.distance(evidence, $0.evidence)) }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: Changing

    public mutating func record(_ verdict: ChapterVerdict, for id: String, signature: String, now: Date) {
        guard let kind = verdict.kind.normalized else { return }
        var verdict = verdict
        verdict.kind = kind
        verdict.alternatives = verdict.alternatives.compactMap(\.normalized).filter { $0 != kind }
        let earlier = verdicts[id]
        let asksFirst = earlier?.asksFirst ?? false
        if asksFirst, kind == .daily { verdict.confidence = min(verdict.confidence, .low) }
        var stored = StoredVerdict(verdict: verdict, signature: signature, judgedAt: now)
        stored.asksFirst = asksFirst
        // The same answer again: "Later", the closed check and the check's
        // age still hold, so nothing the person put away comes back.
        if let earlier, earlier.verdict.source != .person, earlier.verdict.kind == kind {
            stored.deferredAt = earlier.deferredAt
            stored.checkClosedAt = earlier.checkClosedAt
            stored.judgedAt = earlier.judgedAt
        }
        verdicts[id] = stored
    }

    /// The person decided the chapter: the kind is theirs from now on, and
    /// similar days are judged by it. False when the kind's label is no
    /// type and nothing was kept.
    @discardableResult
    public mutating func decide(
        _ kind: ChapterKind,
        for id: String,
        title: String,
        evidence: SegmentEvidence,
        now: Date
    ) -> Bool {
        guard let kind = kind.normalized else { return false }
        var evidence = evidence
        evidence.baseName = nil
        let earlier = verdicts[id]?.verdict
        let corrected = earlier.map { $0.kind != kind } ?? true
        var stored = StoredVerdict(verdict: .person(kind), signature: evidence.signature, judgedAt: now)
        stored.checkClosedAt = now
        verdicts[id] = stored
        examples.removeAll { $0.id == id }
        examples.insert(
            JudgeExample(id: id, title: title, evidence: evidence, kind: kind, corrected: corrected, addedAt: now),
            at: 0
        )
        if examples.count > Self.maximumExamples { examples.removeLast(examples.count - Self.maximumExamples) }
        return true
    }

    /// Chapters among `ids` the judge is sure were ordinary days, to remove
    /// if nobody touched them. The person's own answers are never here.
    public func removals(among ids: [String]) -> [String] {
        guard enabled else { return [] }
        return ids.filter { id in
            guard let stored = verdicts[id], stored.verdict.source != .person, !stored.asksFirst, stored.verdict.kind == .daily else { return false }
            return action(for: id) == .apply
        }
    }

    /// The judge's answer for these chapters stays, but it asks first: for a
    /// chapter someone touched, or one brought back with Undo.
    public mutating func askInstead(_ ids: [String]) {
        for id in ids {
            guard var stored = verdicts[id], stored.verdict.source != .person else { continue }
            stored.verdict.confidence = min(stored.verdict.confidence, .low)
            stored.deferredAt = nil
            stored.asksFirst = true
            verdicts[id] = stored
        }
    }

    /// What the book holds for some chapters, to put back with Undo.
    public struct Entries: Equatable, Sendable {
        public let ids: [String]
        let verdicts: [String: StoredVerdict]
        let examples: [JudgeExample]
    }

    public func entries(for ids: [String]) -> Entries {
        let wanted = Set(ids)
        return Entries(
            ids: ids,
            verdicts: verdicts.filter { wanted.contains($0.key) },
            examples: examples.filter { wanted.contains($0.id) }
        )
    }

    /// Puts back what `entries` held for its chapters, leaving everything
    /// else, such as later answers about other chapters, as it is.
    public mutating func restore(_ entries: Entries) {
        let ids = Set(entries.ids)
        for id in ids { verdicts[id] = entries.verdicts[id] }
        examples.removeAll { ids.contains($0.id) }
        for example in entries.examples {
            let index = examples.firstIndex { $0.addedAt < example.addedAt } ?? examples.endIndex
            examples.insert(example, at: index)
        }
    }

    /// The one-line check was answered "yes", or put away.
    public mutating func closeCheck(for id: String, now: Date) {
        verdicts[id]?.checkClosedAt = now
    }

    public mutating func deferQuestion(for id: String, now: Date) {
        verdicts[id]?.deferredAt = now
    }

    /// Forgets an example. Chapters already decided keep their kind.
    public mutating func forgetExample(_ id: String) {
        examples.removeAll { $0.id == id }
    }

    /// Drops what the judge said about chapters that are gone. The person's
    /// own answers, and stretches called ordinary days, are kept, so a
    /// chapter that comes back with the same photos gets the same answer.
    public mutating func prune(keeping ids: Set<String>) {
        verdicts = verdicts.filter { id, stored in
            ids.contains(id) || stored.verdict.source == .person || stored.verdict.kind == .daily
        }
    }

    /// The person moved a chapter's photos to another chapter id.
    public mutating func rename(_ id: String, to newID: String) {
        guard id != newID else { return }
        if let stored = verdicts.removeValue(forKey: id) { verdicts[newID] = stored }
        if examples.contains(where: { $0.id == id }) { examples.removeAll { $0.id == newID } }
        for index in examples.indices where examples[index].id == id { examples[index].id = newID }
    }

    // MARK: Storage

    public static func decode(_ stored: String?) -> ChapterJudgeBook {
        guard let data = stored?.data(using: .utf8) else { return ChapterJudgeBook() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(ChapterJudgeBook.self, from: data)) ?? ChapterJudgeBook()
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

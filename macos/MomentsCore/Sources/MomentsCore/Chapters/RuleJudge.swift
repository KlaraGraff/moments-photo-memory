import Foundation

/// Judges a stretch of photos with fixed, general rules and with the
/// stretches the person decided before.
///
/// The rules only weigh what holds in most lives: weekends and leisure
/// scenes lean to a trip, workdays and work scenes to a business trip, the
/// home town to a home visit, a short stretch close to daily life to
/// ordinary days. Everything particular to one person comes from their
/// examples: a stretch much like one they decided gets the same kind, so a
/// correction teaches the judge without any new rule.
public enum RuleJudge {
    /// How much one example close to the stretch counts, against the rules.
    static let exampleWeight = 5.0
    /// Examples further apart than this have no say.
    static let exampleReach = 0.42

    public static func judge(_ evidence: SegmentEvidence, book: ChapterJudgeBook) -> ChapterVerdict {
        judge(evidence, candidates: book.candidates, examples: book.examples)
    }

    struct Scoring {
        var scores: [ChapterKind: Double]
        var support: [ChapterKind: [(JudgeReason, Double)]]
        var bestExample: (JudgeExample, Double)?

        func reasons(for kind: ChapterKind) -> [JudgeReason] {
            (support[kind] ?? [])
                .sorted { $0.1 > $1.1 }
                .map(\.0)
                .reduce(into: [JudgeReason]()) { list, reason in if !list.contains(reason) { list.append(reason) } }
        }
    }

    /// The facts that point to `kind`, strongest first, for a verdict the
    /// rules did not make.
    public static func reasons(for kind: ChapterKind, evidence: SegmentEvidence, book: ChapterJudgeBook) -> [JudgeReason] {
        score(evidence, candidates: book.candidates + [kind], examples: book.examples).reasons(for: kind)
    }

    public static func judge(
        _ evidence: SegmentEvidence,
        candidates: [ChapterKind],
        examples: [JudgeExample]
    ) -> ChapterVerdict {
        let scoring = score(evidence, candidates: candidates, examples: examples)
        let scores = scoring.scores
        let bestExample = scoring.bestExample
        let sample = evidence.sceneSample
        let ranked = scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.key < $1.key.key }
        let top = ranked[0]
        let probabilities = softmax(ranked.map(\.value), temperature: 0.9)
        let margin = probabilities[0] - (probabilities.count > 1 ? probabilities[1] : 0)
        var confidence: JudgeConfidence
        if probabilities[0] >= 0.62 && margin >= 0.32 {
            confidence = .high
        } else if margin >= 0.14 {
            confidence = .medium
        } else {
            confidence = .low
        }
        // Without scenes the rules see only dates and distances, which say
        // little about why someone went: never sure on those alone, unless
        // an example the person decided is a near match.
        let closeExample = (bestExample?.1 ?? 0) >= 0.6 && bestExample?.0.kind == top.key
        if sample == 0 && !closeExample && confidence == .high { confidence = .medium }
        if closeExample { confidence = max(confidence, .medium) }

        let alternatives = ranked.dropFirst()
            .filter { $0.key != .daily || $0.value > top.value - 2 }
            .map(\.key)
        return ChapterVerdict(
            kind: top.key,
            confidence: confidence,
            source: .rules,
            alternatives: Array(alternatives.prefix(3)),
            reasons: scoring.reasons(for: top.key)
        )
    }

    static func score(
        _ evidence: SegmentEvidence,
        candidates: [ChapterKind],
        examples: [JudgeExample]
    ) -> Scoring {
        var kinds: [ChapterKind] = []
        for kind in candidates where !kinds.contains(kind) { kinds.append(kind) }
        if !kinds.contains(.daily) { kinds.append(.daily) }
        var scores: [ChapterKind: Double] = Dictionary(uniqueKeysWithValues: kinds.map { ($0, 0) })
        var support: [ChapterKind: [(JudgeReason, Double)]] = [:]
        func add(_ kind: ChapterKind, _ amount: Double, _ reason: JudgeReason? = nil) {
            guard scores[kind] != nil else { return }
            scores[kind, default: 0] += amount
            if let reason, amount > 0 { support[kind, default: []].append((reason, amount)) }
        }

        // Custom kinds start low: only the person's examples speak for them.
        for kind in kinds { if case .custom = kind { scores[kind] = -1.0 } }
        // A trip is what the trip finder found, so it is the starting guess.
        add(.trip, 0.3)

        let days = evidence.dayCount
        let weekend = evidence.weekendShare
        if evidence.weekendDayCount > 0 {
            let reason = JudgeReason.weekend(weekendDays: evidence.weekendDayCount, days: days)
            add(.trip, 1.3 * weekend + (days <= 4 ? 0.4 : 0), reason)
            add(.homeVisit, 0.3 * weekend, reason)
        } else if days <= 7 {
            add(.businessTrip, 1.1, .allWorkdays(days: days))
        }

        let freeHours = 1 - evidence.workHourShare
        if evidence.workHourShare >= 0.6 {
            add(.businessTrip, 0.8 * evidence.workHourShare, .workHours)
            add(.daily, 0.3 * evidence.workHourShare)
        } else if freeHours >= 0.6 {
            add(.trip, 0.6 * freeHours, .freeHours)
        }

        let sample = evidence.sceneSample
        if let work = evidence.workSceneShare, sample > 0 {
            let reason = JudgeReason.workScenes(count: Int((work * Double(sample)).rounded()), of: sample)
            add(.businessTrip, 2.2 * work, reason)
            add(.daily, 0.9 * work, reason)
            add(.trip, -2.0 * work)
            add(.homeVisit, -1.0 * work)
        }
        if let leisure = evidence.leisureSceneShare, sample > 0 {
            let reason = JudgeReason.leisureScenes(count: Int((leisure * Double(sample)).rounded()), of: sample)
            add(.trip, 2.0 * leisure, reason)
            add(.homeVisit, 0.4 * leisure)
            add(.businessTrip, -1.4 * leisure)
            add(.daily, -1.0 * leisure)
        }

        let perDay = evidence.photosPerDay
        if perDay >= 15 {
            add(.trip, 0.5, .manyPhotos(perDay: Int(perDay.rounded())))
        } else if perDay < 6 {
            let reason = JudgeReason.fewPhotos(perDay: Int(perDay.rounded()))
            add(.businessTrip, 0.4, reason)
            add(.daily, 0.4, reason)
        }

        if let km = evidence.kmFromBase, let role = evidence.baseRole {
            if km < 150 && days <= 1 {
                // A day out and back near daily life is part of it, whatever
                // was done: work near the site is no business trip.
                let reason = JudgeReason.nearBase(km: Int(km.rounded()), role: role)
                add(.daily, km < 80 ? 1.6 : 0.8, reason)
                add(.businessTrip, -1.4)
            } else if km < 80 {
                add(.daily, 0.5, .nearBase(km: Int(km.rounded()), role: role))
            } else {
                let reason = JudgeReason.farFromBase(km: Int(km.rounded()), role: role)
                add(.trip, 0.3, reason)
                add(.businessTrip, km < 1_500 ? 0.3 : 0, reason)
                if km >= 3_000 && days >= 10 { add(.homeVisit, 0.8, reason) }
            }
        }
        if let km = evidence.kmFromHomeTown, km < 60 {
            add(.homeVisit, 2.6, .nearHomeTown(km: Int(km.rounded())))
            add(.trip, -0.8)
        }
        if evidence.isAbroad == true {
            add(.trip, 0.3, .abroad)
            add(.homeVisit, days >= 10 ? 0.4 : 0, .abroad)
        }
        if days >= 14 {
            let reason = JudgeReason.longStay(days: days)
            add(.homeVisit, 0.6, reason)
            add(.businessTrip, -0.6)
            add(.daily, -1.5)
        } else if days <= 1 {
            let reason = JudgeReason.shortVisit(days: days)
            add(.daily, 0.6, reason)
            add(.homeVisit, -0.5)
        } else if days >= 3 {
            add(.daily, -1.2)
        }

        // The person's own decisions, nearest first.
        var bestExample: (JudgeExample, Double)?
        for example in examples {
            let distance = Self.distance(evidence, example.evidence)
            guard distance < exampleReach else { continue }
            let weight = 1 - distance / exampleReach
            if bestExample == nil || weight > bestExample!.1 { bestExample = (example, weight) }
            if scores[example.kind] == nil { scores[example.kind] = -1.0 }
            add(
                example.kind,
                exampleWeight * weight * (example.corrected ? 1.15 : 1),
                .similar(title: example.title, kind: example.kind, start: example.evidence.start, corrected: example.corrected)
            )
        }

        return Scoring(scores: scores, support: support, bestExample: bestExample)
    }

    /// How far apart two stretches are, from 0 (alike) up. Facts only one of
    /// them has are left out; the same place name halves the distance.
    public static func distance(_ a: SegmentEvidence, _ b: SegmentEvidence) -> Double {
        var parts: [Double] = []
        func compare(_ x: Double?, _ y: Double?, weight: Double = 1) {
            guard let x, let y else { return }
            parts.append(weight * (x - y) * (x - y))
        }
        compare(scaledDays(a.dayCount), scaledDays(b.dayCount), weight: 1.4)
        compare(a.weekendShare, b.weekendShare)
        compare(a.workHourShare, b.workHourShare)
        compare(a.workSceneShare, b.workSceneShare, weight: 1.2)
        compare(a.leisureSceneShare, b.leisureSceneShare, weight: 1.2)
        compare(a.kmFromBase.map(scaledKm), b.kmFromBase.map(scaledKm), weight: 1.2)
        compare(a.kmFromHomeTown.map { $0 < 60 ? 1 : 0 }, b.kmFromHomeTown.map { $0 < 60 ? 1 : 0 })
        compare(a.isAbroad.map { $0 ? 1 : 0 }, b.isAbroad.map { $0 ? 1 : 0 })
        compare(scaledPhotos(a.photosPerDay), scaledPhotos(b.photosPerDay), weight: 0.6)
        guard !parts.isEmpty else { return .infinity }
        var distance = (parts.reduce(0, +) / Double(parts.count)).squareRoot()
        if let left = a.placeName?.lowercased(), let right = b.placeName?.lowercased(), !left.isEmpty, left == right {
            distance *= 0.5
        }
        return distance
    }

    static func scaledDays(_ days: Int) -> Double { min(log2(Double(max(days, 1))) / 5, 1) }
    static func scaledKm(_ km: Double) -> Double { min(log10(km + 1) / 4, 1) }
    static func scaledPhotos(_ perDay: Double) -> Double { min(log2(perDay + 1) / 6, 1) }

    static func softmax(_ values: [Double], temperature: Double) -> [Double] {
        guard let largest = values.max() else { return [] }
        let exps = values.map { exp(($0 - largest) / temperature) }
        let total = exps.reduce(0, +)
        return exps.map { $0 / total }
    }

    /// Puts a model's answer together with the rules'. The model decides;
    /// when the rules strongly disagree it is less sure, and when they agree
    /// it is surer.
    public static func combine(
        rules: ChapterVerdict,
        model: ChapterVerdict,
        evidence: SegmentEvidence,
        book: ChapterJudgeBook
    ) -> ChapterVerdict {
        var verdict = model
        verdict.source = .model
        if rules.kind == model.kind {
            if rules.confidence == .high { verdict.confidence = verdict.confidence.higher }
        } else if rules.confidence == .high {
            verdict.confidence = verdict.confidence.lower
        }
        // Ordinary days remove the chapter: the model alone is never sure
        // enough for that.
        if model.kind == .daily && rules.kind != .daily {
            verdict.confidence = min(verdict.confidence, .medium)
        }
        if verdict.reasons.isEmpty {
            verdict.reasons = rules.kind == model.kind
                ? rules.reasons
                : reasons(for: model.kind, evidence: evidence, book: book)
        }
        var alternatives = model.alternatives
        for kind in [rules.kind] + rules.alternatives where kind != verdict.kind && !alternatives.contains(kind) {
            alternatives.append(kind)
        }
        verdict.alternatives = Array(alternatives.prefix(3))
        return verdict
    }
}

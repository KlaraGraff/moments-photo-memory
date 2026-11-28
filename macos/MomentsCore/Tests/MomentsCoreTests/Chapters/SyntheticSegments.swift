import Foundation
@testable import MomentsCore

/// Made-up stretches of photos with the kind a person would give each. No
/// real place, date or photo is in here.
struct SyntheticSegments {
    struct Case {
        var name: String
        var evidence: SegmentEvidence
        var truth: ChapterKind
    }

    /// A small seeded generator, so every run sees the same stretches.
    struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * next() }
        mutating func int(_ low: Int, _ high: Int) -> Int { low + Int(next() * Double(high - low + 1)) % (high - low + 1) }
    }

    static let start = Date(timeIntervalSince1970: 1_767_225_600) // a Thursday

    static func evidence(
        _ random: inout Random,
        days: Int,
        weekendDays: Int,
        perDay: ClosedRange<Double>,
        workHours: ClosedRange<Double>,
        km: ClosedRange<Double>,
        work: ClosedRange<Double>?,
        leisure: ClosedRange<Double>?,
        homeTownKm: Double? = nil,
        abroad: Bool? = nil,
        place: String? = nil
    ) -> SegmentEvidence {
        let photoDays = max(1, days - random.int(0, days / 4))
        let photos = Int(random.range(perDay.lowerBound, perDay.upperBound) * Double(photoDays))
        let first = start.addingTimeInterval(Double(random.int(0, 300)) * 86_400)
        return SegmentEvidence(
            start: first,
            end: first.addingTimeInterval(Double(days - 1) * 86_400 + 3_600),
            dayCount: days,
            weekendDayCount: weekendDays,
            photoCount: max(photos, 3),
            photoDayCount: photoDays,
            workHourShare: random.range(workHours.lowerBound, workHours.upperBound),
            kmFromBase: random.range(km.lowerBound, km.upperBound),
            baseRole: .work,
            kmFromHomeTown: homeTownKm,
            isAbroad: abroad,
            sceneSample: work == nil ? 0 : 8,
            workSceneShare: work.map { (random.range($0.lowerBound, $0.upperBound) * 8).rounded() / 8 },
            leisureSceneShare: leisure.map { (random.range($0.lowerBound, $0.upperBound) * 8).rounded() / 8 },
            placeName: place
        )
    }

    /// A library's worth of stretches: weekends away, holidays, business
    /// trips, home visits and ordinary days near work.
    static func library(seed: UInt64 = 7) -> [Case] {
        var random = Random(state: seed)
        var cases: [Case] = []
        for index in 0..<12 {
            let days = random.int(2, 4)
            cases.append(Case(name: "weekend \(index)", evidence: evidence(
                &random, days: days, weekendDays: min(2, days), perDay: 12...45, workHours: 0.0...0.3,
                km: 120...700, work: 0.0...0.1, leisure: 0.5...0.9
            ), truth: .trip))
        }
        for index in 0..<8 {
            let days = random.int(5, 12)
            cases.append(Case(name: "holiday \(index)", evidence: evidence(
                &random, days: days, weekendDays: days >= 7 ? 2 : 1, perDay: 15...50, workHours: 0.1...0.4,
                km: 900...3_000, work: 0.0...0.1, leisure: 0.5...0.9, abroad: true
            ), truth: .trip))
        }
        for index in 0..<12 {
            cases.append(Case(name: "business \(index)", evidence: evidence(
                &random, days: random.int(1, 4), weekendDays: 0, perDay: 3...10, workHours: 0.6...0.95,
                km: 150...650, work: 0.4...0.8, leisure: 0.0...0.15
            ), truth: .businessTrip))
        }
        for index in 0..<6 {
            cases.append(Case(name: "home leave \(index)", evidence: evidence(
                &random, days: random.int(12, 35), weekendDays: 4, perDay: 4...20, workHours: 0.2...0.5,
                km: 3_000...9_000, work: 0.0...0.1, leisure: 0.1...0.5,
                homeTownKm: random.range(0, 30), abroad: true
            ), truth: .homeVisit))
        }
        for index in 0..<8 {
            cases.append(Case(name: "site day \(index)", evidence: evidence(
                &random, days: 1, weekendDays: 0, perDay: 3...8, workHours: 0.7...1.0,
                km: 52...78, work: 0.5...0.9, leisure: 0.0...0.1
            ), truth: .daily))
        }
        for index in 0..<6 {
            // Days off in the week: the photos say it was a holiday.
            cases.append(Case(name: "weekday holiday \(index)", evidence: evidence(
                &random, days: random.int(2, 4), weekendDays: 0, perDay: 15...40, workHours: 0.3...0.6,
                km: 200...600, work: 0.0...0.1, leisure: 0.6...0.95
            ), truth: .trip))
        }
        return cases
    }

    /// Stretches only the person can explain: three weekday days away with
    /// no scenes looked at. The judge must not claim to know.
    static func unclear(seed: UInt64 = 11) -> [Case] {
        var random = Random(state: seed)
        return (0..<8).map { index in
            Case(name: "unclear \(index)", evidence: evidence(
                &random, days: 3, weekendDays: index % 2, perDay: 6...14, workHours: 0.4...0.6,
                km: 250...500, work: nil, leisure: nil
            ), truth: .trip)
        }
    }
}

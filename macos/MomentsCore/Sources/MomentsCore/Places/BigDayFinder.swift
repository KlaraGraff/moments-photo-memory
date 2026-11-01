import Foundation

/// Finds the big days of daily life: days at a usual place with far more
/// photos than usual, like a birthday, a party or a wedding at home. Bursts
/// count once, because photos closer together than `momentGap` are one
/// moment.
public struct BigDayFinder: Sendable {
    public struct Photo: Equatable, Sendable {
        /// `yyyy-MM-dd`, the photo's local day.
        public let dayKey: String
        public let date: Date

        public init(dayKey: String, date: Date) {
            self.dayKey = dayKey
            self.date = date
        }
    }

    /// A big day has at least this many moments, and `multipleOfUsual`
    /// times the median of the photo days within `windowDays`.
    public var minimumMoments = 20
    public var multipleOfUsual = 3.0
    public var windowDays = 90
    public var momentGap: TimeInterval = 60
    /// Big days in a row are one event, up to this many days.
    public var maximumDays = 3

    public init() {}

    /// Runs of big days in a row, by day key, oldest first.
    public func bigDays(_ photos: [Photo]) -> [[String]] {
        let byDay = Dictionary(grouping: photos, by: \.dayKey)
        let days: [(key: String, ordinal: Int, moments: Int)] = byDay.compactMap { key, photos in
            guard let ordinal = DayKey.ordinal(key) else { return nil }
            return (key, ordinal, Self.moments(in: photos.map(\.date), gap: momentGap))
        }.sorted { $0.ordinal < $1.ordinal }

        var big: [(key: String, ordinal: Int)] = []
        var low = 0, high = 0
        for (index, day) in days.enumerated() {
            while days[low].ordinal < day.ordinal - windowDays { low += 1 }
            while high < days.count, days[high].ordinal <= day.ordinal + windowDays { high += 1 }
            let usual = (low..<high).filter { $0 != index }.map { days[$0].moments }.sorted()
            let median = usual.isEmpty ? 0 : Double(usual[usual.count / 2])
            if day.moments >= minimumMoments, Double(day.moments) >= multipleOfUsual * median {
                big.append((day.key, day.ordinal))
            }
        }

        var runs: [[String]] = []
        var lastOrdinal = Int.min
        for day in big {
            if day.ordinal == lastOrdinal + 1, let count = runs.last?.count, count < maximumDays {
                runs[runs.count - 1].append(day.key)
            } else {
                runs.append([day.key])
            }
            lastOrdinal = day.ordinal
        }
        return runs
    }

    /// Photos more than `gap` apart are separate moments; a burst is one.
    public static func moments(in dates: [Date], gap: TimeInterval = 60) -> Int {
        let sorted = dates.sorted()
        guard var last = sorted.first else { return 0 }
        var count = 1
        for date in sorted.dropFirst() where date.timeIntervalSince(last) > gap {
            count += 1
            last = date
        }
        return count
    }
}

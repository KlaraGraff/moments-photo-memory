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
            guard let ordinal = Self.ordinal(of: key) else { return nil }
            return (key, ordinal, moments(in: photos.map(\.date)))
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

    private func moments(in dates: [Date]) -> Int {
        let sorted = dates.sorted()
        guard var last = sorted.first else { return 0 }
        var count = 1
        for date in sorted.dropFirst() where date.timeIntervalSince(last) > momentGap {
            count += 1
            last = date
        }
        return count
    }

    /// Days since 1970-01-01 for a `yyyy-MM-dd` key.
    private static func ordinal(of key: String) -> Int? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return Int((date.timeIntervalSince1970 / 86_400).rounded())
    }
}

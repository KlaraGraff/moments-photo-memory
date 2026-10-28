import Foundation

/// `yyyy-MM-dd` day keys, the photo's own local day. Arithmetic runs on
/// day numbers in UTC, so it never depends on the Mac's time zone.
public enum DayKey {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Days since 1970-01-01, or nil for a malformed key.
    public static func ordinal(_ key: String) -> Int? {
        let parts = key.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day),
              let date = utc.date(from: DateComponents(year: year, month: month, day: day)),
              utc.component(.day, from: date) == day else { return nil }
        return Int((date.timeIntervalSince1970 / 86_400).rounded())
    }

    public static func key(ordinal: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(ordinal) * 86_400)
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func adding(_ days: Int, to key: String) -> String? {
        ordinal(key).map { self.key(ordinal: $0 + days) }
    }

    /// Days from `start` to `end`, both included; 0 when either is malformed.
    public static func length(from start: String, to end: String) -> Int {
        guard let first = ordinal(start), let last = ordinal(end), last >= first else { return 0 }
        return last - first + 1
    }
}

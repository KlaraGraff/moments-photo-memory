import Foundation

/// Parsers for the text values that cameras and phones write into QuickTime
/// (MOV/MP4) metadata. They take the item's string value, so the app reads the
/// file with AVFoundation and the parsing is tested on Linux.
public enum QuickTimeMetadata {
    /// A `com.apple.quicktime.creationdate` value.
    public struct CreationDate: Equatable, Sendable {
        /// The UTC instant when the value names a zone (an offset or `Z`).
        /// Without a zone it is the wall-clock time encoded as UTC, the same
        /// convention the photo import uses for offset-less EXIF dates.
        public let date: Date
        /// The local offset from UTC, when the value states one. `Z` names
        /// the instant but not the place's zone, so it has no offset.
        public let offsetMinutes: Int?
        /// True when the value names no zone at all.
        public let isWallClock: Bool

        public init(date: Date, offsetMinutes: Int?, isWallClock: Bool) {
            self.date = date
            self.offsetMinutes = offsetMinutes
            self.isWallClock = isWallClock
        }
    }

    /// Parses an ISO 6709 location such as `+48.8577+002.2950+035.000/`.
    /// Degrees, degrees and minutes (`±DDMM.mm`) and degrees, minutes and
    /// seconds (`±DDMMSS.ss`) are accepted; an altitude and a CRS suffix are
    /// ignored. Returns nil for anything malformed or out of range.
    public static func location(iso6709 value: String) -> GeoPoint? {
        let tokens = signedNumbers(in: value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard tokens.count >= 2,
              let latitude = angle(tokens[0], degreeDigits: 2),
              let longitude = angle(tokens[1], degreeDigits: 3),
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    /// Parses a creation date such as `2026-01-01T12:34:56+0200`. Accepts a
    /// `T` or a space between date and time, optional seconds and fractions,
    /// and a zone written `Z`, `±HH`, `±HHMM` or `±HH:MM`.
    public static func creationDate(_ value: String) -> CreationDate? {
        let characters = Array(value.trimmingCharacters(in: .whitespacesAndNewlines))
        var index = 0

        func digits(_ count: Int) -> Int? {
            guard index + count <= characters.count else { return nil }
            var result = 0
            for character in characters[index..<(index + count)] {
                guard let digit = character.wholeNumberValue, character.isASCII else { return nil }
                result = result * 10 + digit
            }
            index += count
            return result
        }
        func consume(_ character: Character) -> Bool {
            guard index < characters.count, characters[index] == character else { return false }
            index += 1
            return true
        }

        guard let year = digits(4), consume("-"),
              let month = digits(2), consume("-"),
              let day = digits(2) else { return nil }
        guard consume("T") || consume(" ") else { return nil }
        guard let hour = digits(2), consume(":"), let minute = digits(2) else { return nil }
        var second = 0
        var fraction = 0.0
        if consume(":") {
            guard let value = digits(2) else { return nil }
            second = value
            if consume(".") || consume(",") {
                var scale = 0.1
                var sawDigit = false
                while index < characters.count, characters[index].isASCII, let digit = characters[index].wholeNumberValue {
                    fraction += Double(digit) * scale
                    scale /= 10
                    sawDigit = true
                    index += 1
                }
                guard sawDigit else { return nil }
            }
        }
        while consume(" ") {}

        var offsetMinutes: Int?
        var isWallClock = true
        if index < characters.count {
            if consume("Z") || consume("z") {
                isWallClock = false
            } else {
                let sign: Int
                if consume("+") { sign = 1 } else if consume("-") { sign = -1 } else { return nil }
                guard let hours = digits(2) else { return nil }
                var minutes = 0
                if index < characters.count {
                    _ = consume(":")
                    guard let value = digits(2) else { return nil }
                    minutes = value
                }
                guard hours <= 18, minutes < 60 else { return nil }
                offsetMinutes = sign * (hours * 60 + minutes)
                isWallClock = false
            }
        }
        guard index == characters.count else { return nil }
        guard (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        // Reject dates the calendar would roll over, such as 31 February.
        guard let wallClock = calendar.date(from: components),
              calendar.component(.day, from: wallClock) == day,
              calendar.component(.month, from: wallClock) == month else { return nil }
        let local = wallClock.addingTimeInterval(fraction)
        let date = local.addingTimeInterval(TimeInterval(-(offsetMinutes ?? 0) * 60))
        return CreationDate(date: date, offsetMinutes: offsetMinutes, isWallClock: isWallClock)
    }

    /// The signed numbers at the start of an ISO 6709 string, in order:
    /// `+48.8577+002.2950+035.000/` gives `["+48.8577", "+002.2950", "+035.000"]`.
    private static func signedNumbers(in value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in value {
            if character == "+" || character == "-" {
                if !current.isEmpty { tokens.append(current) }
                current = String(character)
            } else if character.isASCII, character.isNumber || character == "." {
                guard !current.isEmpty else { return tokens }
                current.append(character)
            } else {
                // `/` ends the coordinate; a CRS name ends the numbers too.
                break
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Reads one signed ISO 6709 angle. `degreeDigits` is 2 for latitude and
    /// 3 for longitude; the integer part's length says whether minutes and
    /// seconds follow the degrees.
    private static func angle(_ token: String, degreeDigits: Int) -> Double? {
        guard let signCharacter = token.first, signCharacter == "+" || signCharacter == "-" else { return nil }
        let sign: Double = signCharacter == "-" ? -1 : 1
        let body = token.dropFirst()
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let integer = parts.first, !integer.isEmpty,
              integer.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        }
        guard let whole = Double(body) else { return nil }
        let digits = integer.count
        let value: Double
        switch digits {
        case ...degreeDigits:
            value = whole
        case degreeDigits + 2:
            let degrees = (whole / 100).rounded(.towardZero)
            let minutes = whole - degrees * 100
            guard minutes < 60 else { return nil }
            value = degrees + minutes / 60
        case degreeDigits + 4:
            let degrees = (whole / 10_000).rounded(.towardZero)
            let rest = whole - degrees * 10_000
            let minutes = (rest / 100).rounded(.towardZero)
            let seconds = rest - minutes * 100
            guard minutes < 60, seconds < 60 else { return nil }
            value = degrees + minutes / 60 + seconds / 3_600
        default:
            return nil
        }
        return sign * value
    }
}

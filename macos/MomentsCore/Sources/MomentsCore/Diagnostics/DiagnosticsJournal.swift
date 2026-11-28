import Foundation

/// The parts of the app a log line can come from. Each is one category of
/// the app's logger, so Console can show one part at a time.
public enum LogCategory: String, CaseIterable, Sendable {
    case app
    case saving
    case backup
    case decisions
    case trips
    case importing
    case people
    case sharing
}

/// One thing worth logging, made only of parts that cannot carry anything
/// personal: a fixed event name written in the code, where in the code it
/// happened, an error's domain and code, the first characters of an ID and
/// a count. Never a memory, a place, a coordinate, a path or a name: there
/// is no field for them, and every field is cut down to safe characters.
public struct DiagnosticEvent: Equatable, Sendable {
    public var date: Date
    public var category: LogCategory
    public var name: String
    public var site: String?
    public var errorDomain: String?
    public var errorCode: Int?
    public var idPrefix: String?
    public var count: Int?

    /// `name` is a string literal in the code (a `StaticString`), so no value
    /// read at run time can become the event's name.
    public init(
        _ category: LogCategory,
        _ name: StaticString,
        site: String? = nil,
        error: (any Error)? = nil,
        id: String? = nil,
        count: Int? = nil,
        date: Date = Date()
    ) {
        self.date = date
        self.category = category
        self.name = DiagnosticSanitizer.token(name.description) ?? "event"
        self.site = site.flatMap(DiagnosticSanitizer.token)
        if let error {
            let code = DiagnosticSanitizer.errorCode(of: error)
            errorDomain = code.domain
            errorCode = code.code
        }
        idPrefix = id.flatMap(DiagnosticSanitizer.idPrefix)
        self.count = count
    }

    /// "saving save-failed site=TripEdits.swift:358 error=NSCocoaErrorDomain/134030 id=1A2B3C4D count=2"
    public var line: String {
        var parts = [category.rawValue, name]
        if let site { parts.append("site=\(site)") }
        if let errorDomain, let errorCode { parts.append("error=\(errorDomain)/\(errorCode)") }
        if let idPrefix { parts.append("id=\(idPrefix)") }
        if let count { parts.append("count=\(count)") }
        return parts.joined(separator: " ")
    }

    /// "NSCocoaErrorDomain/134030", the part of an event that says which error.
    public var errorText: String? {
        guard let errorDomain, let errorCode else { return nil }
        return "\(errorDomain)/\(errorCode)"
    }
}

/// Turns whatever it is given into something safe to log: only letters,
/// digits and a few punctuation marks, and short.
public enum DiagnosticSanitizer {
    /// Domains, sites and names: ASCII letters, digits and `._:-`, at most
    /// 64 characters. Anything else (spaces, slashes, any other script)
    /// ends the token, so a path or a sentence never gets through whole.
    public static func token(_ text: String) -> String? {
        var kept = ""
        for scalar in text.unicodeScalars {
            guard isTokenScalar(scalar) else { break }
            kept.unicodeScalars.append(scalar)
            if kept.count == 64 { break }
        }
        return kept.isEmpty ? nil : kept
    }

    /// The first 8 letters or digits of an ID, upper-cased: enough to tell
    /// two records apart in a log, never a whole identifier.
    public static func idPrefix(_ id: String) -> String? {
        var kept = ""
        for scalar in id.unicodeScalars where scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)) {
            kept.unicodeScalars.append(scalar)
            if kept.count == 8 { break }
        }
        return kept.isEmpty ? nil : kept.uppercased()
    }

    /// An error's domain and code, without its message: a message can hold
    /// a file path or text from the library.
    public static func errorCode(of error: any Error) -> (domain: String, code: Int) {
        let nsError = error as NSError
        return (token(nsError.domain) ?? "error", nsError.code)
    }

    /// "Moments/Timeline/TripEdits.swift" and 358 → "TripEdits.swift:358".
    public static func site(file: String, line: UInt) -> String {
        let name = file.split(separator: "/").last.map(String.init) ?? file
        return (token(name) ?? "code") + ":\(line)"
    }

    private static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else { return false }
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", ".", "_", ":", "-": return true
        default: return false
        }
    }
}

/// The most recent log events, kept in memory for the diagnostics file.
/// Safe to use from any thread.
public final class DiagnosticsJournal: @unchecked Sendable {
    public let capacity: Int
    private let lock = NSLock()
    private var events: [DiagnosticEvent] = []

    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    public func record(_ event: DiagnosticEvent) {
        lock.lock()
        events.append(event)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        lock.unlock()
    }

    /// Oldest first.
    public var recent: [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// The distinct error codes seen, most recent first.
    public var recentErrorCodes: [String] {
        var seen = Set<String>()
        var codes: [String] = []
        for event in recent.reversed() {
            guard let text = event.errorText, seen.insert(text).inserted else { continue }
            codes.append(text)
        }
        return codes
    }

    public func removeAll() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }
}

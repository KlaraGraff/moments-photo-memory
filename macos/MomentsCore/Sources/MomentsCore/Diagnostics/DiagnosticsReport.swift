import Foundation

/// The file "Export Diagnostics…" writes, for telling someone what went
/// wrong: which version, which macOS, how big the library is, and the
/// recent error codes and log events. Nothing else goes in: every value is
/// a number, a version or an already safe log event, so no memory, name,
/// place, coordinate or path can end up in it.
public struct DiagnosticsReport: Sendable {
    public var appVersion: String
    public var buildNumber: String
    public var systemVersion: String
    public var architecture: String
    public var createdAt: Date
    /// What is in the library: ("photos", 21345), ("memories", 812)…
    public var counts: [(name: StaticString, value: Int)]
    public var events: [DiagnosticEvent]

    public init(
        appVersion: String,
        buildNumber: String,
        systemVersion: String,
        architecture: String,
        createdAt: Date = Date(),
        counts: [(name: StaticString, value: Int)],
        events: [DiagnosticEvent]
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.systemVersion = systemVersion
        self.architecture = architecture
        self.createdAt = createdAt
        self.counts = counts
        self.events = events
    }

    public var text: String {
        let iso = ISO8601DateFormatter()
        var lines = [
            "Moments diagnostics",
            "created: \(iso.string(from: createdAt))",
            "version: \(Self.version(appVersion)) (\(Self.version(buildNumber)))",
            "macOS: \(Self.version(systemVersion))",
            "architecture: \(DiagnosticSanitizer.token(architecture) ?? "unknown")",
            "",
            "library:",
        ]
        if counts.isEmpty {
            lines.append("  no library open")
        } else {
            for count in counts {
                lines.append("  \(DiagnosticSanitizer.token(count.name.description) ?? "items"): \(count.value)")
            }
        }
        lines.append("")
        lines.append("recent errors:")
        let codes = Self.errorCodes(events)
        lines.append(contentsOf: codes.isEmpty ? ["  none"] : codes.map { "  \($0)" })
        lines.append("")
        lines.append("recent events (oldest first):")
        if events.isEmpty {
            lines.append("  none")
        } else {
            for event in events {
                lines.append("  \(iso.string(from: event.date)) \(event.line)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "0.9.0", "14.6.1", "Version 15.1 (Build 24B83)" → its digits, dots
    /// and the build letters only.
    static func version(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == " " || $0 == "(" || $0 == ")") }
        let cut = String(String.UnicodeScalarView(kept.prefix(40))).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? "unknown" : cut
    }

    static func errorCodes(_ events: [DiagnosticEvent]) -> [String] {
        var seen = Set<String>()
        var codes: [String] = []
        for event in events.reversed() {
            guard let text = event.errorText, seen.insert(text).inserted else { continue }
            codes.append(text)
        }
        return codes
    }
}

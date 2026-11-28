import Foundation
import MomentsCore
import os

/// The app's one logger. Every line goes to the system log under the app's
/// own identifier, one category per part of the app, and into a short
/// in-memory journal that "Export Diagnostics…" writes out.
///
/// A line is a `DiagnosticEvent`: a fixed name, where in the code, an
/// error's domain and code, an ID's first characters and a count. There is
/// no way to log a memory, a place name, a coordinate, a path or a person's
/// name, and an error's message (which can hold a path) is never logged.
enum MomentsLog {
    /// The registered bundle identifier; final, see AGENTS.md (CI).
    static let subsystem = "com.momentsphotomemory.Moments"

    static let journal = DiagnosticsJournal()

    static func logger(_ category: LogCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    /// Logs an error-level event and keeps it for diagnostics.
    static func error(
        _ category: LogCategory,
        _ name: StaticString,
        error: (any Error)? = nil,
        id: String? = nil,
        count: Int? = nil,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        let event = DiagnosticEvent(category, name, site: DiagnosticSanitizer.site(file: "\(file)", line: line), error: error, id: id, count: count)
        record(event, level: .error)
    }

    /// Logs a notable but expected event and keeps it for diagnostics.
    static func notice(
        _ category: LogCategory,
        _ name: StaticString,
        id: String? = nil,
        count: Int? = nil,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        let event = DiagnosticEvent(category, name, site: DiagnosticSanitizer.site(file: "\(file)", line: line), id: id, count: count)
        record(event, level: .default)
    }

    /// Writes an event that was already made (the save guard makes its own).
    static func record(_ event: DiagnosticEvent, level: OSLogType) {
        journal.record(event)
        writeToSystemLog(event, level: level)
    }

    /// Only the system log: for events the journal already holds.
    static func writeToSystemLog(_ event: DiagnosticEvent, level: OSLogType) {
        // Public: the line is built only from codes, counts and ID prefixes.
        logger(event.category).log(level: level, "\(event.line, privacy: .public)")
    }
}

import Foundation
import MomentsCore
import SwiftData

extension Notification.Name {
    /// Posted after an import when the model may organize Chapters.
    static let momentsChapterAIRequested = Notification.Name("moments.chapterAI.requested")
}

/// After an import: the model organizes the new days when it can run,
/// otherwise the rules turn big days into events.
enum ChapterOrganizing {
    @MainActor
    static func afterImport(in context: ModelContext) {
        if ChapterAISettings.canRun() {
            NotificationCenter.default.post(name: .momentsChapterAIRequested, object: nil)
        } else {
            EventSuggestions.suggest(in: context)
        }
    }
}

/// Runs `ChapterAIOrganizer` for the app: once over the whole library the
/// first time, then over the days of each import, and when asked on the
/// Chapters page. The last run can be undone.
@MainActor
@Observable
final class ChapterAIController {
    static let lastRunKey = "moments.chapterAI.lastRun"

    enum State: Equatable {
        case idle
        case running(ChapterAIOrganizer.Progress)
        case done(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// What the last run wrote, until undone or replaced.
    private(set) var lastRun: ChapterAIApplier.Written?
    private var container: ModelContainer?
    private var task: Task<Void, Never>?
    /// An import finished while a run was going: look at its days next.
    private var runAgain = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = TripAssignmentLocks.store) {
        self.defaults = defaults
    }

    var isRunning: Bool { task != nil }

    func configure(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        // Tests and runs on a copied library never start a paid run by themselves.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-MomentsUITesting") || arguments.contains("-MomentsUITestStoreDirectory") { return }
        #if DEBUG
        if UnitTestHostDelegate.isUnitTestHost { return }
        #endif
        // The first time, the whole library; later, what came in since.
        if ChapterAISettings.canRun() { organizeNewPhotos() }
    }

    /// The whole library again, from the Chapters page.
    func organizeLibrary() {
        start(scope: nil)
    }

    /// The days of photos imported since the last run; the whole library
    /// if it never ran.
    func organizeNewPhotos() {
        guard !isRunning else {
            runAgain = true
            return
        }
        guard let container else { return }
        guard let last = defaults.object(forKey: Self.lastRunKey) as? Date else {
            start(scope: nil)
            return
        }
        let items = (try? container.mainContext.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        let keys = items.filter { ($0.importedAt ?? .distantPast) > last }.compactMap { PhotoNoteDay.key(for: $0) }
        guard let first = keys.min(), let lastKey = keys.max() else { return }
        start(scope: first...lastKey)
    }

    func undoLastRun() {
        guard let lastRun, let container else { return }
        let applier = ChapterAIApplier(context: container.mainContext, defaults: defaults)
        if (try? applier.changedSince(lastRun)) != false {
            // Undo would throw away what someone changed since.
            self.lastRun = nil
            state = .failed(String(localized: "Chapters were changed since, so this can no longer be undone."))
            return
        }
        ChapterAIApplier.undo(lastRun, context: container.mainContext, defaults: defaults)
        self.lastRun = nil
        state = .idle
    }

    func dismiss() {
        guard !isRunning else { return }
        state = .idle
    }

    private func start(scope: ClosedRange<String>?) {
        guard task == nil, let container, ChapterAISettings.isEnabled(), let key = ChapterAISettings.apiKey() else { return }
        let organizer = ChapterAIOrganizer(context: container.mainContext, client: ClaudeChapterClient(apiKey: key, model: ChapterAISettings.model()))
        organizer.defaults = defaults
        organizer.onProgress = { [weak self] progress in self?.state = .running(progress) }
        let startedAt = Date.now
        state = .running(.init(phase: .describing, done: 0, total: 0))
        task = Task { [weak self] in
            do {
                let outcome = try await organizer.run(scope: scope)
                self?.finish(outcome, startedAt: startedAt)
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
            self?.task = nil
            if self?.runAgain == true {
                self?.runAgain = false
                self?.organizeNewPhotos()
            }
        }
    }

    private func finish(_ outcome: ChapterAIOrganizer.Outcome, startedAt: Date) {
        // Only a run that looked at every day counts: otherwise the next
        // one looks again (descriptions are kept, so that costs little).
        if outcome.windows > 0, outcome.failedWindows == 0 {
            defaults.set(startedAt, forKey: Self.lastRunKey)
        }
        lastRun = outcome.written
        ChapterAIReport.write(outcome, startedAt: startedAt, to: ChapterAIFiles.directory?.appending(path: "last-run.md"))
        let written = outcome.written?.outcome
        let count = (written?.trips ?? 0) + (written?.chapters ?? 0)
        if outcome.windows > 0, outcome.failedWindows == outcome.windows {
            state = .failed(String(localized: "The model could not organize Chapters this time. Nothing was changed."))
        } else {
            state = .done(String(localized: "AI organized \(count) chapters"))
        }
    }
}

/// A plain-text account of one run, kept on this Mac: what was written, what
/// was left out, and what it cost.
enum ChapterAIReport {
    static func text(_ outcome: ChapterAIOrganizer.Outcome, startedAt: Date, extra: [String] = []) -> String {
        var lines = ["# Chapters organized by AI", "", "Started: \(startedAt.formatted(.iso8601))"] + extra
        let usage = outcome.usage
        lines += [
            "",
            "## Cost",
            "",
            "| Step | Requests | Input tokens | Output tokens | US$ |",
            "| --- | ---: | ---: | ---: | ---: |",
            row("Describe photos", outcome.captionUsage),
            row("Find chapters", outcome.chapterUsage),
            row("Total", usage),
            "",
            "Photos described: \(outcome.described); not described (no copy on this Mac, or the request failed): \(outcome.notDescribed).",
            "Windows: \(outcome.windows), failed: \(outcome.failedWindows)."
        ]
        if let written = outcome.written?.outcome {
            lines += ["", "Written: \(written.trips) trips, \(written.chapters) other chapters; replaced \(written.removed) earlier ones; \(written.left) photos left a trip."]
        }
        lines += ["", "## Chapters", "", "| Dates | Kind | Title | Summary | Confidence |", "| --- | --- | --- | --- | --- |"]
        for proposal in outcome.proposals {
            let dates = proposal.start == proposal.end ? proposal.start : "\(proposal.start) – \(proposal.end)"
            lines.append("| \(dates) | \(proposal.type.rawValue) | \(cell(proposal.title)) | \(cell(proposal.summary)) | \(proposal.confidence) |")
        }
        if let skipped = outcome.written?.outcome.skipped, !skipped.isEmpty {
            lines += ["", "Left out (already in a chapter made by hand, deleted before, or without photos):"]
            lines += skipped.map { "- \($0.start) – \($0.end) \($0.type.rawValue): \($0.title)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func write(_ outcome: ChapterAIOrganizer.Outcome, startedAt: Date, extra: [String] = [], to url: URL?) {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text(outcome, startedAt: startedAt, extra: extra).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func row(_ name: String, _ usage: ModelUsage) -> String {
        let dollars = usage.dollars.map { String(format: "%.4f", $0) } ?? "?"
        return "| \(name) | \(usage.requests) | \(usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens) | \(usage.outputTokens) | \(dollars) |"
    }

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "/")
    }
}

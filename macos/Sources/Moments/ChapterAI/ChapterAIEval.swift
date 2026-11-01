#if DEBUG
import AppKit
import Foundation
import MomentsCore
import SwiftData

/// A run on a copied library, with no window, for checking how well the
/// model organizes real photos on the Mac they live on:
///
///     open -g -j -a Moments.app --args \
///       -MomentsUITestStoreDirectory /path/to/copy -MomentsChapterAIRun \
///       [-MomentsChapterAIVision allPhotos|sampled|textOnly] \
///       [-MomentsChapterAIModel claude-haiku-5-5] [-MomentsChapterAIDryRun]
///
/// It refuses to run without a copied store, writes the chapters into the
/// copy (unless dry run), puts a report and every request's text and answer
/// (never the images) under `<copy>/AI/runs/<time>/`, then quits.
@MainActor
enum ChapterAIEval {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-MomentsChapterAIRun") }

    private static func value(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func start(container: ModelContainer) {
        Task { @MainActor in
            let code = await run(container: container)
            exit(code)
        }
    }

    static func run(container: ModelContainer) async -> Int32 {
        guard let root = ChapterAIFiles.directory, value(after: "-MomentsUITestStoreDirectory") != nil else {
            FileHandle.standardError.write(Data("Refusing: -MomentsChapterAIRun needs -MomentsUITestStoreDirectory with a copied store.\n".utf8))
            return 2
        }
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-")
        let folder = root.appending(path: "runs", directoryHint: .isDirectory).appending(path: stamp, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appending(path: "log.txt")
        func note(_ line: String) {
            let text = "\(Date.now.formatted(.iso8601)) \(line)\n"
            if let handle = try? FileHandle(forWritingTo: log) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            } else {
                try? text.write(to: log, atomically: true, encoding: .utf8)
            }
        }

        guard let key = ChapterAISettings.apiKey() else {
            note("No Anthropic key in the Keychain (service \"Moments AI\").")
            return 3
        }
        let model = value(after: "-MomentsChapterAIModel") ?? ChapterAISettings.model()
        let vision = value(after: "-MomentsChapterAIVision").flatMap(ChapterAIVision.init(rawValue:)) ?? ChapterAISettings.vision()
        let dryRun = ProcessInfo.processInfo.arguments.contains("-MomentsChapterAIDryRun")
        let context = container.mainContext
        let before = (try? context.fetchCount(FetchDescriptor<Trip>())) ?? 0
        let chaptersBefore = (try? context.fetchCount(FetchDescriptor<UserGroup>(predicate: #Predicate { $0.kindRaw == "chapter" }))) ?? 0
        let photoCount = (try? context.fetchCount(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil }))) ?? 0
        let screenshots = (try? context.fetchCount(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil && $0.isScreenshot }))) ?? 0
        let undated = ImportCaptureDateSource.fileDateFallback.rawValue
        let withoutDate = (try? context.fetchCount(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil && $0.captureDateSourceRaw == undated }))) ?? 0
        note("Start: \(photoCount) photos, \(before) trips and \(chaptersBefore) other chapters before; model \(model), vision \(vision.rawValue)\(dryRun ? ", dry run" : "").")

        let organizer = ChapterAIOrganizer(context: context, client: ClaudeChapterClient(apiKey: key, model: model))
        organizer.vision = vision
        organizer.writes = !dryRun
        var lastNote = Date.distantPast
        organizer.onProgress = { progress in
            guard Date.now.timeIntervalSince(lastNote) > 15 || progress.done == progress.total else { return }
            lastNote = .now
            note("\(progress.phase) \(progress.done)/\(progress.total)")
        }
        let exchanges = folder.appending(path: "exchanges.md")
        organizer.onExchange = { name, request, answer in
            let text = "## \(name)\n\n### Sent (text only)\n\n```\n\(request)\n```\n\n### Answer\n\n```\n\(answer)\n```\n\n"
            if let handle = try? FileHandle(forWritingTo: exchanges) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            } else {
                try? text.write(to: exchanges, atomically: true, encoding: .utf8)
            }
        }
        let startedAt = Date.now
        do {
            let outcome = try await organizer.run()
            let seconds = Int(Date.now.timeIntervalSince(startedAt))
            let after = (try? context.fetchCount(FetchDescriptor<Trip>())) ?? 0
            let chaptersAfter = (try? context.fetchCount(FetchDescriptor<UserGroup>(predicate: #Predicate { $0.kindRaw == "chapter" }))) ?? 0
            ChapterAIReport.write(outcome, startedAt: startedAt, extra: [
                "Model: \(model); looked at: \(vision.rawValue)\(dryRun ? "; dry run, nothing written" : "")",
                "Photos in the copy: \(photoCount); screenshots (not looked at): \(screenshots); without a capture date (left out): \(withoutDate)",
                "Before: \(before) trips, \(chaptersBefore) other chapters. After: \(after) trips, \(chaptersAfter) other chapters.",
                "Took \(seconds / 60) min \(seconds % 60) s."
            ], to: folder.appending(path: "report.md"))
            note("Done in \(seconds) s: \(outcome.proposals.count) chapters, US$ \(outcome.usage.dollars.map { String(format: "%.4f", $0) } ?? "?").")
            return 0
        } catch {
            note("Failed: \(error.localizedDescription)")
            return 1
        }
    }
}
#endif

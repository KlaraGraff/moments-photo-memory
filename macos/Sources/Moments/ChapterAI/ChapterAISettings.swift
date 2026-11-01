import Foundation
import MomentsCore

/// Settings › AI Model › Chapters, kept in UserDefaults. The API key is the
/// Anthropic key in the Keychain that notes use too.
enum ChapterAISettings {
    static let enabledKey = "moments.chapterAI.enabled"
    static let visionKey = "moments.chapterAI.vision"

    /// On unless turned off: maple chose (2026-10-28) that the model
    /// organizes Chapters, looking at every photo, by default.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func vision(_ defaults: UserDefaults = .standard) -> ChapterAIVision {
        defaults.string(forKey: visionKey).flatMap(ChapterAIVision.init(rawValue:)) ?? .allPhotos
    }

    /// Haiku: every photo is looked at, so the cheapest model that sees
    /// well. The notes model in Settings › AI Model does not apply here.
    static func model() -> String { ClaudeModel.haiku.rawValue }

    static func apiKey() -> String? { AIKeychain.key(for: .claude) }

    /// Turned on and a key is there; otherwise Chapters come from the rules.
    static func canRun(_ defaults: UserDefaults = .standard) -> Bool {
        isEnabled(defaults) && apiKey() != nil
    }

    /// The language titles and descriptions are written in: the app's own.
    static var languageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        if code.hasPrefix("zh") { return "Simplified Chinese" }
        if code.hasPrefix("de") { return "German" }
        return "English"
    }
}

/// Where the descriptions of photos and the last run's report are kept. Tests
/// and runs on a copied store keep theirs next to that store.
enum ChapterAIFiles {
    static var directory: URL? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-MomentsUITestStoreDirectory"), index + 1 < arguments.count,
           arguments[index + 1].hasPrefix("/") {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true).appending(path: "AI", directoryHint: .isDirectory)
        }
        if arguments.contains("-MomentsUITesting") || UnitTestHostDelegate.isUnitTestHost {
            return FileManager.default.temporaryDirectory.appending(path: "MomentsTestAI-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        }
        #endif
        return URL.applicationSupportDirectory
            .appending(path: "Moments", directoryHint: .isDirectory)
            .appending(path: "AI", directoryHint: .isDirectory)
    }
}

/// What the model wrote about each photo, kept on this Mac only, so each
/// photo is looked at once.
@MainActor
final class PhotoCaptionStore {
    static let shared = PhotoCaptionStore(directory: ChapterAIFiles.directory)

    private struct File: Codable {
        var version = 1
        var captions: [String: ChapterPrompts.Caption] = [:]
    }

    private let url: URL?
    private(set) var captions: [String: ChapterPrompts.Caption] = [:]

    init(directory: URL?) {
        url = directory?.appending(path: "photo-captions.json")
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        captions = file.captions
    }

    func caption(for id: String) -> ChapterPrompts.Caption? { captions[id] }

    func add(_ new: [String: ChapterPrompts.Caption]) {
        guard !new.isEmpty else { return }
        captions.merge(new) { _, latest in latest }
        save()
    }

    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(File(captions: captions)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

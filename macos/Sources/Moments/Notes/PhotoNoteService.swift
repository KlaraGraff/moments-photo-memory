import Foundation
import Security
import SwiftData

/// What is left of the AI note organizer, which is gone: the words a person
/// types under a photo are their memory (`MemoryEditor` saves them), and
/// nothing is sent anywhere. These run once on launch to tidy up after it.
enum PhotoNoteService {
    static let earlierWordsWrittenKey = "moments.notes.earlierWordsWritten"

    /// Before words became memories at once, a note became a memory only if
    /// the model wrote one from it; otherwise (no key, offline, failed,
    /// nothing found, or only a place fix) the words lived only in the note,
    /// whose popover is gone. Writes those words once into the author's
    /// memory; a note that wrote a photo, day or trip memory is left alone.
    @discardableResult
    static func writeEarlierWords(context: ModelContext, defaults: UserDefaults = .standard, now: Date = .now) -> Int {
        guard !defaults.bool(forKey: earlierWordsWrittenKey) else { return 0 }
        guard let notes = try? context.fetch(FetchDescriptor<PhotoNote>(sortBy: [SortDescriptor(\.createdAt)])) else { return 0 }
        let pending = notes.filter { note in
            let record = note.undoRecord
            return AuthorNames.isLocal(note.authorAccountID) && record.memories.isEmpty && record.collectionMemoryIDs.isEmpty
        }
        var written = 0
        if !pending.isEmpty {
            let ids = Array(Set(pending.map(\.mediaID)))
            let items = (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
            let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for note in pending {
                guard let item = byID[note.mediaID] else { continue }
                if NoteApplier.writeOwnWords(note.text, on: item, context: context, now: now) != nil { written += 1 }
            }
            do {
                try context.save()
            } catch {
                // Try again next launch rather than mark it done.
                return 0
            }
        }
        defaults.set(true, forKey: earlierWordsWrittenKey)
        return written
    }

    /// The settings the AI organizer kept in UserDefaults.
    static let aiSettingKeys = [
        "moments.ai.enabled",
        "moments.ai.engine",
        "moments.ai.cloudProvider",
        "moments.ai.cloudModel",
        "moments.ai.cloudBaseURL",
        "moments.ai.fallback"
    ]

    /// The Keychain service the AI organizer stored cloud API keys under.
    static let aiKeychainService = "Moments AI"

    /// Forgets the AI organizer's settings and any API key it saved, so no
    /// key is left behind in the Keychain for a feature that is gone. Looks
    /// first (reading only attributes, which never asks), and deletes only
    /// when a key is there.
    static func forgetAISettings(defaults: UserDefaults = .standard) {
        for key in aiSettingKeys { defaults.removeObject(forKey: key) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: aiKeychainService
        ]
        var lookup = query
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitAll
        var found: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &found) == errSecSuccess else { return }
        SecItemDelete(query as CFDictionary)
    }
}

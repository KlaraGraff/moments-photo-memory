import Foundation

/// Gathers everything people wrote in the app under the photos it belongs
/// to, so a search finds those photos: a photo's memories (both people's)
/// and the comments under them, the original words of a note before the AI
/// organized it, a day's memories (every photo of that day), a trip's or
/// chapter's memories (every photo in it) and a place's notes (every photo
/// at that place).
///
/// Plain values only; the app reads its records into these once and builds
/// the index again only when what was written changes.
public enum WrittenTextIndex {
    /// Where a photo belongs: the keys the day, chapter and place texts are
    /// written under.
    public struct Photo: Sendable, Equatable {
        public let id: String
        /// `yyyy-MM-dd`, as day memories are keyed; nil for an undated photo.
        public let dayKey: String?
        /// Its trip's id and the ids of chapters it is in, as trip memories are keyed.
        public let chapterKeys: [String]
        /// Its place names, as given; matched with `placeKey(for:)`.
        public let placeNames: [String]

        public init(id: String, dayKey: String? = nil, chapterKeys: [String] = [], placeNames: [String] = []) {
            self.id = id
            self.dayKey = dayKey
            self.chapterKeys = chapterKeys
            self.placeNames = placeNames
        }
    }

    /// A memory written under one photo, by either person.
    public struct PhotoText: Sendable, Equatable {
        /// The memory's own id, which comments refer to; nil for text that
        /// takes no comments (a note's original words).
        public let id: String?
        public let mediaID: String
        public let text: String

        public init(id: String? = nil, mediaID: String, text: String) {
            self.id = id
            self.mediaID = mediaID
            self.text = text
        }
    }

    /// A memory about a whole day or a whole trip or chapter.
    public struct CollectionText: Sendable, Equatable {
        public enum Scope: Sendable, Equatable {
            case day
            case chapter
        }

        public let id: String
        public let scope: Scope
        public let key: String
        public let text: String

        public init(id: String, scope: Scope, key: String, text: String) {
            self.id = id
            self.scope = scope
            self.key = key
            self.text = text
        }
    }

    /// A place's description, keyed by the place's name.
    public struct PlaceText: Sendable, Equatable {
        public let placeName: String
        public let text: String

        public init(placeName: String, text: String) {
            self.placeName = placeName
            self.text = text
        }
    }

    /// A comment (or a reply) under the memory with id `memoryID`.
    public struct CommentText: Sendable, Equatable {
        public let memoryID: String
        public let text: String

        public init(memoryID: String, text: String) {
            self.memoryID = memoryID
            self.text = text
        }
    }

    public struct Sources: Sendable, Equatable {
        public var photoTexts: [PhotoText]
        public var collectionTexts: [CollectionText]
        public var placeTexts: [PlaceText]
        public var comments: [CommentText]

        public init(
            photoTexts: [PhotoText] = [],
            collectionTexts: [CollectionText] = [],
            placeTexts: [PlaceText] = [],
            comments: [CommentText] = []
        ) {
            self.photoTexts = photoTexts
            self.collectionTexts = collectionTexts
            self.placeTexts = placeTexts
            self.comments = comments
        }
    }

    /// A place name as place notes are keyed: trimmed and lowercased.
    public static func placeKey(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Each photo's written texts, by photo id. Photos with nothing written
    /// are left out; texts that are empty or only whitespace are skipped. A
    /// text reaching a photo twice (a place named twice) is kept once.
    public static func textsByPhoto(photos: [Photo], sources: Sources) -> [String: [String]] {
        func written(_ text: String) -> Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var byPhoto: [String: [String]] = [:]
        // Where a memory sits, so its comments follow it.
        var photoOfMemory: [String: String] = [:]
        for entry in sources.photoTexts {
            if let id = entry.id { photoOfMemory[id] = entry.mediaID }
            if written(entry.text) { byPhoto[entry.mediaID, default: []].append(entry.text) }
        }

        var byDay: [String: [String]] = [:]
        var byChapter: [String: [String]] = [:]
        var collectionOfMemory: [String: CollectionText] = [:]
        for entry in sources.collectionTexts {
            collectionOfMemory[entry.id] = entry
            guard written(entry.text) else { continue }
            switch entry.scope {
            case .day: byDay[entry.key, default: []].append(entry.text)
            case .chapter: byChapter[entry.key, default: []].append(entry.text)
            }
        }

        for comment in sources.comments where written(comment.text) {
            if let mediaID = photoOfMemory[comment.memoryID] {
                byPhoto[mediaID, default: []].append(comment.text)
            } else if let collection = collectionOfMemory[comment.memoryID] {
                switch collection.scope {
                case .day: byDay[collection.key, default: []].append(comment.text)
                case .chapter: byChapter[collection.key, default: []].append(comment.text)
                }
            }
            // A comment whose memory is gone (or not here yet) is shown
            // nowhere, so it finds nothing.
        }

        var byPlace: [String: [String]] = [:]
        for entry in sources.placeTexts where written(entry.text) {
            let key = placeKey(for: entry.placeName)
            guard !key.isEmpty else { continue }
            byPlace[key, default: []].append(entry.text)
        }

        // Only photos that exist get texts: a memory for a photo that is not
        // in the list (trashed, not synced yet) is not searched.
        var result: [String: [String]] = [:]
        result.reserveCapacity(photos.count)
        for photo in photos {
            var texts: [String] = byPhoto[photo.id] ?? []
            if let day = photo.dayKey, let dayTexts = byDay[day] { texts += dayTexts }
            var seenChapters = Set<String>()
            for chapter in photo.chapterKeys where seenChapters.insert(chapter).inserted {
                texts += byChapter[chapter] ?? []
            }
            var seenPlaces = Set<String>()
            for name in photo.placeNames {
                let key = placeKey(for: name)
                guard !key.isEmpty, seenPlaces.insert(key).inserted else { continue }
                texts += byPlace[key] ?? []
            }
            if !texts.isEmpty { result[photo.id] = texts }
        }
        return result
    }
}

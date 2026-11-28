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

    /// A trip's name, found on every photo of the trip.
    public struct TripName: Sendable, Equatable {
        public let tripID: String
        public let name: String

        public init(tripID: String, name: String) {
            self.tripID = tripID
            self.name = name
        }
    }

    public struct Sources: Sendable, Equatable {
        public var photoTexts: [PhotoText]
        public var collectionTexts: [CollectionText]
        public var placeTexts: [PlaceText]
        public var comments: [CommentText]
        public var tripNames: [TripName]

        public init(
            photoTexts: [PhotoText] = [],
            collectionTexts: [CollectionText] = [],
            placeTexts: [PlaceText] = [],
            comments: [CommentText] = [],
            tripNames: [TripName] = []
        ) {
            self.photoTexts = photoTexts
            self.collectionTexts = collectionTexts
            self.placeTexts = placeTexts
            self.comments = comments
            self.tripNames = tripNames
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
        let lookup = Lookup(sources: sources)
        var result: [String: [String]] = [:]
        result.reserveCapacity(photos.count)
        for photo in photos {
            let texts: [String] = lookup.texts(for: photo)
            if !texts.isEmpty { result[photo.id] = texts }
        }
        return result
    }

    /// The written texts gathered by where they belong: a photo, a day, a
    /// trip or chapter, a place. Built from `Sources` once; a photo's texts
    /// are then a few dictionary reads. Comparing two lookups tells which
    /// photos, days, chapters and places a save changed, so only their
    /// photos are indexed again.
    public struct Lookup: Sendable, Equatable {
        /// By photo id: its memories, their comments, its notes' words.
        public internal(set) var byPhoto: [String: [String]] = [:]
        /// By `yyyy-MM-dd`: that day's memories and their comments.
        public internal(set) var byDay: [String: [String]] = [:]
        /// By trip or chapter id: its name, memories and their comments.
        public internal(set) var byChapter: [String: [String]] = [:]
        /// By `placeKey(for:)`: that place's notes.
        public internal(set) var byPlace: [String: [String]] = [:]

        public init() {}

        public init(sources: Sources) {
            func written(_ text: String) -> Bool {
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            // Where a memory sits, so its comments follow it.
            var photoOfMemory: [String: String] = [:]
            for entry in sources.photoTexts {
                if let id = entry.id { photoOfMemory[id] = entry.mediaID }
                if written(entry.text) { byPhoto[entry.mediaID, default: []].append(entry.text) }
            }

            var collectionOfMemory: [String: CollectionText] = [:]
            for entry in sources.collectionTexts {
                collectionOfMemory[entry.id] = entry
                guard written(entry.text) else { continue }
                switch entry.scope {
                case .day: byDay[entry.key, default: []].append(entry.text)
                case .chapter: byChapter[entry.key, default: []].append(entry.text)
                }
            }

            for trip in sources.tripNames where written(trip.name) {
                byChapter[trip.tripID, default: []].append(trip.name)
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

            for entry in sources.placeTexts where written(entry.text) {
                let key = placeKey(for: entry.placeName)
                guard !key.isEmpty else { continue }
                byPlace[key, default: []].append(entry.text)
            }

            // Records come back from the store in no fixed order; sorted, the
            // same records always give the same lookup.
            for key in byPhoto.keys { byPhoto[key]?.sort() }
            for key in byDay.keys { byDay[key]?.sort() }
            for key in byChapter.keys { byChapter[key]?.sort() }
            for key in byPlace.keys { byPlace[key]?.sort() }
        }

        /// What was written for `photo`, wherever it was written. Only
        /// photos that exist are asked for, so a memory for a photo that is
        /// not in the library (trashed, not synced yet) is not searched.
        public func texts(for photo: Photo) -> [String] {
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
            return texts
        }

        /// Where two lookups differ.
        public struct Changes: Sendable, Equatable {
            public var photoIDs = Set<String>()
            public var dayKeys = Set<String>()
            public var chapterKeys = Set<String>()
            public var placeKeys = Set<String>()

            public init() {}

            public var isEmpty: Bool {
                photoIDs.isEmpty && dayKeys.isEmpty && chapterKeys.isEmpty && placeKeys.isEmpty
            }
        }

        /// The photos, days, chapters and places whose texts are not the
        /// same in `old` as here.
        public func changes(from old: Lookup) -> Changes {
            func differing(_ new: [String: [String]], _ old: [String: [String]]) -> Set<String> {
                var keys = Set<String>()
                for (key, value) in new where old[key] != value { keys.insert(key) }
                for key in old.keys where new[key] == nil { keys.insert(key) }
                return keys
            }
            var changes = Changes()
            changes.photoIDs = differing(byPhoto, old.byPhoto)
            changes.dayKeys = differing(byDay, old.byDay)
            changes.chapterKeys = differing(byChapter, old.byChapter)
            changes.placeKeys = differing(byPlace, old.byPlace)
            return changes
        }
    }

    /// Everything written, kept record by record, so a save of a few records
    /// updates only the days, chapters, places and photos they belong to
    /// instead of gathering every record again. `lookup` always equals
    /// `Lookup(sources:)` built from the records it holds.
    public struct Book: Sendable {
        /// One written record, as the app reads it.
        public enum Record: Sendable, Equatable {
            /// A memory or a note's words under one photo; `id` is the
            /// memory's id, which its comments name (nil for a note).
            case photo(id: String?, mediaID: String, text: String)
            /// A memory about a whole day or a whole trip or chapter.
            case collection(id: String, scope: CollectionText.Scope, key: String, text: String)
            case place(placeName: String, text: String)
            case comment(memoryID: String, text: String)
            case tripName(tripID: String, name: String)
        }

        private enum Bucket: Hashable, Sendable {
            case photo(String)
            case day(String)
            case chapter(String)
            case place(String)
        }

        public private(set) var lookup = Lookup()
        /// Records by the key the caller gave them.
        private var records: [String: Record] = [:]
        /// The records (not comments) filed in each bucket.
        private var filed: [Bucket: Set<String>] = [:]
        /// Where each memory sits, so its comments follow it, and which
        /// record it is.
        private var memoryBucket: [String: Bucket] = [:]
        private var memoryRecord: [String: String] = [:]
        /// The memories sitting in each bucket.
        private var memoriesIn: [Bucket: Set<String>] = [:]
        /// The comments under each memory id.
        private var commentsUnder: [String: Set<String>] = [:]

        public init() {}

        /// How many records the book holds.
        public var count: Int { records.count }

        /// Sets each record by its key; nil removes it. Returns where the
        /// lookup changed.
        @discardableResult
        public mutating func set(_ changes: [String: Record?]) -> Lookup.Changes {
            var dirty = Set<Bucket>()
            for (key, new) in changes {
                let old: Record? = records[key]
                if old == new { continue }
                if let old { remove(key, old, &dirty) }
                if let new { add(key, new, &dirty) }
            }
            var result = Lookup.Changes()
            for bucket in dirty {
                let texts: [String] = gather(bucket)
                let value: [String]? = texts.isEmpty ? nil : texts
                switch bucket {
                case .photo(let id):
                    if lookup.byPhoto[id] != value { lookup.byPhoto[id] = value; result.photoIDs.insert(id) }
                case .day(let key):
                    if lookup.byDay[key] != value { lookup.byDay[key] = value; result.dayKeys.insert(key) }
                case .chapter(let key):
                    if lookup.byChapter[key] != value { lookup.byChapter[key] = value; result.chapterKeys.insert(key) }
                case .place(let key):
                    if lookup.byPlace[key] != value { lookup.byPlace[key] = value; result.placeKeys.insert(key) }
                }
            }
            return result
        }

        private static func bucket(of record: Record) -> Bucket? {
            switch record {
            case .photo(_, let mediaID, _): return .photo(mediaID)
            case .collection(_, let scope, let key, _):
                switch scope {
                case .day: return .day(key)
                case .chapter: return .chapter(key)
                }
            case .place(let name, _):
                let key = placeKey(for: name)
                return key.isEmpty ? nil : .place(key)
            case .tripName(let tripID, _): return .chapter(tripID)
            case .comment: return nil
            }
        }

        private static func memoryID(of record: Record) -> String? {
            switch record {
            case .photo(let id, _, _): return id
            case .collection(let id, _, _, _): return id
            default: return nil
            }
        }

        private static func text(of record: Record) -> String {
            switch record {
            case .photo(_, _, let text), .collection(_, _, _, let text), .place(_, let text), .comment(_, let text):
                return text
            case .tripName(_, let name):
                return name
            }
        }

        private mutating func remove(_ key: String, _ record: Record, _ dirty: inout Set<Bucket>) {
            records[key] = nil
            if case .comment(let memoryID, _) = record {
                commentsUnder[memoryID]?.remove(key)
                if let bucket = memoryBucket[memoryID] { dirty.insert(bucket) }
                return
            }
            guard let bucket = Self.bucket(of: record) else { return }
            filed[bucket]?.remove(key)
            dirty.insert(bucket)
            if let id = Self.memoryID(of: record), memoryRecord[id] == key {
                memoryRecord[id] = nil
                memoryBucket[id] = nil
                memoriesIn[bucket]?.remove(id)
            }
        }

        private mutating func add(_ key: String, _ record: Record, _ dirty: inout Set<Bucket>) {
            records[key] = record
            if case .comment(let memoryID, _) = record {
                commentsUnder[memoryID, default: []].insert(key)
                if let bucket = memoryBucket[memoryID] { dirty.insert(bucket) }
                return
            }
            guard let bucket = Self.bucket(of: record) else { return }
            filed[bucket, default: []].insert(key)
            dirty.insert(bucket)
            if let id = Self.memoryID(of: record) {
                if let previous = memoryBucket[id], previous != bucket {
                    memoriesIn[previous]?.remove(id)
                    dirty.insert(previous)
                }
                memoryRecord[id] = key
                memoryBucket[id] = bucket
                memoriesIn[bucket, default: []].insert(id)
            }
        }

        /// A bucket's texts: its records' and their comments', written ones
        /// only, sorted as `Lookup` sorts them.
        private func gather(_ bucket: Bucket) -> [String] {
            func written(_ text: String) -> Bool {
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            var texts: [String] = []
            for key in filed[bucket] ?? [] {
                guard let record = records[key] else { continue }
                let text = Self.text(of: record)
                if written(text) { texts.append(text) }
            }
            for id in memoriesIn[bucket] ?? [] {
                for key in commentsUnder[id] ?? [] {
                    guard let record = records[key] else { continue }
                    let text = Self.text(of: record)
                    if written(text) { texts.append(text) }
                }
            }
            return texts.sorted()
        }
    }
}

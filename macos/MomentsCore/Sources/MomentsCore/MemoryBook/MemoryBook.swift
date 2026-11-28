import Foundation

// A memory book: one chapter's photos with what the two people wrote about
// them, laid out as a printable PDF or a Markdown folder. These types hold
// only words, dates and place names; the app fills them from its store and
// draws the pages. Nothing here knows coordinates, file names or paths.

/// A memory about a whole chapter or a whole day.
public struct MemoryBookNote: Equatable, Sendable {
    public var text: String
    /// Written by the person using this Mac (`false`: by the other person).
    public var isOwn: Bool

    public init(text: String, isOwn: Bool) {
        self.text = text
        self.isOwn = isOwn
    }
}

/// A comment under a photo's memory.
public struct MemoryBookComment: Equatable, Sendable {
    public var text: String
    public var isOwn: Bool
    /// 0 for a comment on the memory, 1 for an answer to a comment.
    public var depth: Int

    public init(text: String, isOwn: Bool, depth: Int = 0) {
        self.text = text
        self.isOwn = isOwn
        self.depth = depth
    }
}

/// One person's memory of a photo, with the comments under it.
public struct MemoryBookMemory: Equatable, Sendable {
    public var text: String
    public var isOwn: Bool
    public var comments: [MemoryBookComment]

    public init(text: String, isOwn: Bool, comments: [MemoryBookComment] = []) {
        self.text = text
        self.isOwn = isOwn
        self.comments = comments
    }
}

/// A description of a place, shown on the day the chapter was there.
public struct MemoryBookPlaceNote: Equatable, Sendable {
    public var placeName: String
    public var text: String
    public var isOwn: Bool

    public init(placeName: String, text: String, isOwn: Bool) {
        self.placeName = placeName
        self.text = text
        self.isOwn = isOwn
    }
}

public struct MemoryBookPhoto: Equatable, Sendable, Identifiable {
    public var id: String
    public var date: Date?
    /// The place's name as the app shows it; never coordinates.
    public var placeName: String?
    public var memories: [MemoryBookMemory]

    public init(id: String, date: Date? = nil, placeName: String? = nil, memories: [MemoryBookMemory] = []) {
        self.id = id
        self.date = date
        self.placeName = placeName
        self.memories = memories
    }

    public var hasMemory: Bool { memories.contains { !$0.text.isBlank } }
}

/// A chapter's memory shown at the start of a day, in the archive's
/// "by date only" order, where chapters have no section of their own.
public struct MemoryBookChapterOpening: Equatable, Sendable {
    public var title: String
    public var memories: [MemoryBookNote]

    public init(title: String, memories: [MemoryBookNote]) {
        self.title = title
        self.memories = memories
    }
}

public struct MemoryBookDay: Equatable, Sendable, Identifiable {
    public var id: String
    /// `yyyy-MM-dd`, the key day memories are stored under.
    public var dayKey: String?
    public var date: Date?
    /// The day's number in the chapter, counting dated days from 1. Set by
    /// ``MemoryBookPlan/prepared(_:options:)``.
    public var number: Int?
    public var memories: [MemoryBookNote]
    public var placeNotes: [MemoryBookPlaceNote]
    public var photos: [MemoryBookPhoto]
    public var openings: [MemoryBookChapterOpening]

    public init(
        id: String,
        dayKey: String? = nil,
        date: Date? = nil,
        number: Int? = nil,
        memories: [MemoryBookNote] = [],
        placeNotes: [MemoryBookPlaceNote] = [],
        photos: [MemoryBookPhoto] = [],
        openings: [MemoryBookChapterOpening] = []
    ) {
        self.id = id
        self.dayKey = dayKey
        self.date = date
        self.number = number
        self.memories = memories
        self.placeNotes = placeNotes
        self.photos = photos
        self.openings = openings
    }

    var isEmpty: Bool { memories.isEmpty && placeNotes.isEmpty && photos.isEmpty && openings.isEmpty }
}

/// One chapter, everything that may go into its book.
public struct MemoryBookDocument: Equatable, Sendable {
    public var title: String
    public var startDate: Date?
    public var endDate: Date?
    public var placeNames: [String]
    /// Memories about the whole chapter ("Before we begin").
    public var chapterMemories: [MemoryBookNote]
    public var days: [MemoryBookDay]

    public init(
        title: String,
        startDate: Date? = nil,
        endDate: Date? = nil,
        placeNames: [String] = [],
        chapterMemories: [MemoryBookNote] = [],
        days: [MemoryBookDay] = []
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.placeNames = placeNames
        self.chapterMemories = chapterMemories
        self.days = days
    }

    public var photos: [MemoryBookPhoto] { days.flatMap(\.photos) }
}

/// What the person chose in the export sheet.
public struct MemoryBookOptions: Equatable, Sendable {
    public enum Photos: String, Equatable, Sendable, CaseIterable {
        /// Only photos someone wrote a memory about (the default).
        case withMemories
        case all
    }

    public var photos: Photos
    /// Chapter memories and day memories.
    public var includesChapterAndDayMemories: Bool
    public var includesPlaceNotes: Bool
    public var includesComments: Bool

    public init(
        photos: Photos = .withMemories,
        includesChapterAndDayMemories: Bool = true,
        includesPlaceNotes: Bool = true,
        includesComments: Bool = true
    ) {
        self.photos = photos
        self.includesChapterAndDayMemories = includesChapterAndDayMemories
        self.includesPlaceNotes = includesPlaceNotes
        self.includesComments = includesComments
    }
}

public enum MemoryBookPlan {
    /// A photo whose memories together are no longer than this, and that has
    /// no comments, may share a row with the next such photo.
    public static let shortMemoryLength = 60

    /// The book as it will be exported: days numbered, blank text dropped,
    /// and only what the options keep. Days left with nothing are dropped.
    public static func prepared(_ document: MemoryBookDocument, options: MemoryBookOptions) -> MemoryBookDocument {
        var result = document
        result.chapterMemories = options.includesChapterAndDayMemories ? cleaned(document.chapterMemories) : []
        var next = 1
        result.days = document.days.compactMap { (original: MemoryBookDay) -> MemoryBookDay? in
            var day = original
            if day.date != nil || day.dayKey != nil {
                day.number = next
                next += 1
            } else {
                day.number = nil
            }
            day.memories = options.includesChapterAndDayMemories ? cleaned(day.memories) : []
            day.openings = options.includesChapterAndDayMemories
                ? day.openings.compactMap { (opening: MemoryBookChapterOpening) -> MemoryBookChapterOpening? in
                    let memories = cleaned(opening.memories)
                    return memories.isEmpty ? nil : MemoryBookChapterOpening(title: opening.title, memories: memories)
                }
                : []
            day.placeNotes = options.includesPlaceNotes
                ? day.placeNotes.filter { !$0.text.isBlank }
                : []
            day.photos = day.photos.compactMap { (photo: MemoryBookPhoto) -> MemoryBookPhoto? in
                var photo = photo
                photo.memories = photo.memories.compactMap { (memory: MemoryBookMemory) -> MemoryBookMemory? in
                    guard !memory.text.isBlank else { return nil }
                    var memory = memory
                    memory.comments = options.includesComments ? memory.comments.filter { !$0.text.isBlank } : []
                    return memory
                }
                if options.photos == .withMemories, photo.memories.isEmpty { return nil }
                return photo
            }
            return day.isEmpty ? nil : day
        }
        return result
    }

    /// How many photos have a memory, and how many there are in all.
    public static func photoCounts(_ document: MemoryBookDocument) -> (withMemories: Int, all: Int) {
        let photos = document.photos
        return (photos.filter(\.hasMemory).count, photos.count)
    }

    /// True when nobody has written anything in the chapter at all.
    public static func hasNoWriting(_ document: MemoryBookDocument) -> Bool {
        document.chapterMemories.allSatisfy { $0.text.isBlank }
            && document.days.allSatisfy { day in
                day.memories.allSatisfy { $0.text.isBlank }
                    && day.placeNotes.allSatisfy { $0.text.isBlank }
                    && !day.photos.contains(where: \.hasMemory)
            }
    }

    /// A day's photos in rows: a photo with a long memory or with comments
    /// gets a row of its own; two short ones in a row share it.
    public static func rows(_ photos: [MemoryBookPhoto]) -> [[MemoryBookPhoto]] {
        var rows: [[MemoryBookPhoto]] = []
        var waiting: MemoryBookPhoto?
        for photo in photos {
            if isShort(photo) {
                if let first = waiting {
                    rows.append([first, photo])
                    waiting = nil
                } else {
                    waiting = photo
                }
            } else {
                if let first = waiting {
                    rows.append([first])
                    waiting = nil
                }
                rows.append([photo])
            }
        }
        if let waiting { rows.append([waiting]) }
        return rows
    }

    static func isShort(_ photo: MemoryBookPhoto) -> Bool {
        let length = photo.memories.reduce(0) { $0 + $1.text.count }
        let hasComments = photo.memories.contains { !$0.comments.isEmpty }
        return !hasComments && length <= shortMemoryLength
    }

    private static func cleaned(_ notes: [MemoryBookNote]) -> [MemoryBookNote] {
        notes.filter { !$0.text.isBlank }
    }
}

/// Splits a book's blocks over pages.
public enum MemoryBookPagination {
    public struct Block: Equatable, Sendable {
        public var height: Double
        /// A day's heading stays on the same page as what follows it.
        public var keepsWithNext: Bool
        /// A new day starts on a new page.
        public var startsPage: Bool

        public init(height: Double, keepsWithNext: Bool = false, startsPage: Bool = false) {
            self.height = height
            self.keepsWithNext = keepsWithNext
            self.startsPage = startsPage
        }
    }

    /// The blocks on each page, by index. A block taller than a page gets a
    /// page of its own (the renderer shrinks its photo to fit).
    public static func pages(_ blocks: [Block], pageHeight: Double, spacing: Double) -> [[Int]] {
        var pages: [[Int]] = []
        var current: [Int] = []
        var used = 0.0
        for (index, block) in blocks.enumerated() {
            var needed = block.height
            if block.keepsWithNext, index + 1 < blocks.count {
                needed += spacing + blocks[index + 1].height
            }
            let gap = current.isEmpty ? 0 : spacing
            let breaks = !current.isEmpty && (block.startsPage || used + gap + min(needed, pageHeight) > pageHeight)
            if breaks {
                pages.append(current)
                current = []
                used = 0
            }
            used += (current.isEmpty ? 0 : spacing) + block.height
            current.append(index)
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

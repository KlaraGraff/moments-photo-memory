import Foundation

/// "Export All Memories": everything the two people wrote, as one Markdown
/// file without photos. The app gathers the pieces; this decides where each
/// one goes and writes the text.
public enum MemoryArchive {
    public enum Order: String, Equatable, Sendable, CaseIterable {
        /// One section per chapter, then what's in no chapter (the default).
        case byChapter
        /// One list of days; a chapter's own memories open its first day.
        case byDate
    }

    public struct Chapter: Equatable, Sendable {
        public var id: String
        public var title: String
        public var startDate: Date?
        public var endDate: Date?
        /// Memories about the whole chapter.
        public var memories: [MemoryBookNote]
        /// Every day the chapter has photos on, `yyyy-MM-dd`.
        public var dayKeys: Set<String>

        public init(id: String, title: String, startDate: Date? = nil, endDate: Date? = nil, memories: [MemoryBookNote] = [], dayKeys: Set<String> = []) {
            self.id = id
            self.title = title
            self.startDate = startDate
            self.endDate = endDate
            self.memories = memories
            self.dayKeys = dayKeys
        }
    }

    /// A photo someone wrote about, and the one chapter it belongs to.
    public struct Photo: Equatable, Sendable {
        public var chapterID: String?
        public var dayKey: String?
        public var photo: MemoryBookPhoto

        public init(chapterID: String?, dayKey: String?, photo: MemoryBookPhoto) {
            self.chapterID = chapterID
            self.dayKey = dayKey
            self.photo = photo
        }
    }

    public struct DayMemories: Equatable, Sendable {
        public var dayKey: String
        public var date: Date?
        public var memories: [MemoryBookNote]

        public init(dayKey: String, date: Date? = nil, memories: [MemoryBookNote]) {
            self.dayKey = dayKey
            self.date = date
            self.memories = memories
        }
    }

    public struct Input: Equatable, Sendable {
        public var chapters: [Chapter]
        public var photos: [Photo]
        public var dayMemories: [DayMemories]
        public var placeNotes: [MemoryBookPlaceNote]

        public init(chapters: [Chapter] = [], photos: [Photo] = [], dayMemories: [DayMemories] = [], placeNotes: [MemoryBookPlaceNote] = []) {
            self.chapters = chapters
            self.photos = photos
            self.dayMemories = dayMemories
            self.placeNotes = placeNotes
        }
    }

    /// One part of the file. A section without a chapter is "Memories not
    /// in a chapter", or the whole list when ordered by date.
    public struct Section: Equatable, Sendable {
        public var chapter: Chapter?
        public var days: [MemoryBookDay]
    }

    public struct Counts: Equatable, Sendable {
        public var photoMemories: Int
        public var chapterAndDayMemories: Int
        public var placeNotes: Int
        public var comments: Int

        public var isEmpty: Bool { photoMemories + chapterAndDayMemories + placeNotes + comments == 0 }
    }

    public struct Strings: Sendable {
        public var book: MemoryBookStrings
        /// "Our memories".
        public var title: String
        /// "A and B · exported on 27 November 2026".
        public var subtitle: String
        /// "Memories not in a chapter".
        public var notInAChapter: String
        /// "Place notes".
        public var placeNotes: String

        public init(book: MemoryBookStrings, title: String, subtitle: String, notInAChapter: String, placeNotes: String) {
            self.book = book
            self.title = title
            self.subtitle = subtitle
            self.notInAChapter = notInAChapter
            self.placeNotes = placeNotes
        }
    }

    /// How much there is to export, counting only written text.
    public static func counts(_ input: Input) -> Counts {
        let memories = input.photos.flatMap { $0.photo.memories }.filter { !$0.text.isBlank }
        return Counts(
            photoMemories: memories.count,
            chapterAndDayMemories: input.chapters.reduce(0) { $0 + $1.memories.filter { !$0.text.isBlank }.count }
                + input.dayMemories.reduce(0) { $0 + $1.memories.filter { !$0.text.isBlank }.count },
            placeNotes: input.placeNotes.filter { !$0.text.isBlank }.count,
            comments: memories.reduce(0) { $0 + $1.comments.filter { !$0.text.isBlank }.count }
        )
    }

    /// The sections in the order chosen. Each photo is in one place; a
    /// day's memories go with the first chapter that has photos that day.
    public static func sections(_ input: Input, order: Order, options: MemoryBookOptions = MemoryBookOptions()) -> [Section] {
        let chapters = input.chapters.sorted(by: chapterComesFirst)
        let known = Set(chapters.map(\.id))
        var photosByChapter: [String?: [Photo]] = [:]
        for photo in input.photos {
            let key = photo.chapterID.flatMap { known.contains($0) ? $0 : nil }
            photosByChapter[key, default: []].append(photo)
        }
        var dayMemoriesByChapter: [String?: [DayMemories]] = [:]
        for day in input.dayMemories {
            let owner = chapters.first { $0.dayKeys.contains(day.dayKey) }?.id
            dayMemoriesByChapter[owner, default: []].append(day)
        }

        func days(for chapterID: String?, opening: Chapter?) -> [MemoryBookDay] {
            var byKey: [String: MemoryBookDay] = [:]
            var undated = MemoryBookDay(id: "undated")
            for entry in photosByChapter[chapterID] ?? [] {
                if let key = entry.dayKey {
                    byKey[key, default: MemoryBookDay(id: key, dayKey: key, date: entry.photo.date)].photos.append(entry.photo)
                } else {
                    undated.photos.append(entry.photo)
                }
            }
            for entry in dayMemoriesByChapter[chapterID] ?? [] {
                var day = byKey[entry.dayKey] ?? MemoryBookDay(id: entry.dayKey, dayKey: entry.dayKey, date: entry.date)
                if day.date == nil { day.date = entry.date }
                day.memories.append(contentsOf: entry.memories)
                byKey[entry.dayKey] = day
            }
            var result = byKey.values.sorted { ($0.dayKey ?? "") < ($1.dayKey ?? "") }
            for index in result.indices {
                result[index].photos.sort(by: photoComesFirst)
            }
            if !undated.photos.isEmpty { result.append(undated) }
            if let opening, !opening.memories.isEmpty {
                let entry = MemoryBookChapterOpening(title: opening.title, memories: opening.memories)
                let first = opening.dayKeys.min() ?? opening.startDate.map(dayKey)
                if let first, let index = result.firstIndex(where: { $0.dayKey == first }) {
                    result[index].openings.append(entry)
                } else if let first {
                    let index = result.firstIndex { day in day.dayKey.map { first < $0 } ?? true } ?? result.endIndex
                    result.insert(MemoryBookDay(id: first, dayKey: first, date: opening.startDate, openings: [entry]), at: index)
                } else if !result.isEmpty {
                    result[0].openings.append(entry)
                } else {
                    result.append(MemoryBookDay(id: "chapter-\(opening.id)", openings: [entry]))
                }
            }
            return result
        }

        func cleaned(_ days: [MemoryBookDay]) -> [MemoryBookDay] {
            let document = MemoryBookDocument(title: "", days: days)
            var prepared = MemoryBookPlan.prepared(document, options: MemoryBookOptions(
                photos: .withMemories,
                includesChapterAndDayMemories: options.includesChapterAndDayMemories,
                includesPlaceNotes: options.includesPlaceNotes,
                includesComments: options.includesComments
            )).days
            // The archive names days by their date, not by number.
            for index in prepared.indices { prepared[index].number = nil }
            return prepared
        }

        switch order {
        case .byChapter:
            var sections: [Section] = []
            for chapter in chapters {
                var chapter = chapter
                if !options.includesChapterAndDayMemories { chapter.memories = [] }
                chapter.memories = chapter.memories.filter { !$0.text.isBlank }
                let chapterDays = cleaned(days(for: chapter.id, opening: nil))
                if chapterDays.isEmpty, chapter.memories.isEmpty { continue }
                sections.append(Section(chapter: chapter, days: chapterDays))
            }
            let rest = cleaned(days(for: nil, opening: nil))
            if !rest.isEmpty { sections.append(Section(chapter: nil, days: rest)) }
            return sections
        case .byDate:
            var all: [MemoryBookDay] = []
            for chapter in chapters {
                all.append(contentsOf: days(for: chapter.id, opening: chapter))
            }
            all.append(contentsOf: days(for: nil, opening: nil))
            // Days that two chapters share stay apart, each under its own.
            let dated = all.filter { $0.dayKey != nil }
            let undated = all.filter { $0.dayKey == nil }
            let ordered = dated.enumerated().sorted { lhs, rhs in
                let left = lhs.element.dayKey ?? "", right = rhs.element.dayKey ?? ""
                return left == right ? lhs.offset < rhs.offset : left < right
            }.map(\.element)
            let merged = cleaned(mergeSameDays(ordered + undated))
            return merged.isEmpty ? [] : [Section(chapter: nil, days: merged)]
        }
    }

    /// The whole file.
    public static func markdown(_ input: Input, order: Order, options: MemoryBookOptions = MemoryBookOptions(), strings: Strings) -> String {
        let book = strings.book
        var lines: [String] = ["# " + MemoryBookMarkdown.heading(strings.title), MemoryBookMarkdown.escape(strings.subtitle)]
        let parts = sections(input, order: order, options: options)
        let dayLevel = order == .byChapter ? "### " : "## "
        for section in parts {
            if order == .byChapter {
                lines.append("")
                if let chapter = section.chapter {
                    var title = chapter.title
                    if chapter.startDate != nil || chapter.endDate != nil {
                        title += " · " + book.dateRange(chapter.startDate, chapter.endDate)
                    }
                    lines.append("## " + MemoryBookMarkdown.heading(title))
                    if !chapter.memories.isEmpty {
                        lines.append("")
                        lines.append(contentsOf: MemoryBookMarkdown.quotes(chapter.memories, strings: book))
                    }
                } else {
                    lines.append("## " + MemoryBookMarkdown.heading(strings.notInAChapter))
                }
            }
            for day in section.days {
                lines.append("")
                lines.append(dayLevel + MemoryBookMarkdown.heading(book.heading(for: day)))
                lines.append(contentsOf: MemoryBookMarkdown.dayBody(day, strings: book) { photo in
                    ["**" + MemoryBookMarkdown.inline(book.photoCaption(photo.date, photo.placeName)) + "**"]
                })
            }
        }
        let placeNotes = options.includesPlaceNotes
            ? input.placeNotes.filter { !$0.text.isBlank }.sorted { $0.placeName.localizedStandardCompare($1.placeName) == .orderedAscending }
            : []
        if !placeNotes.isEmpty {
            lines.append("")
            lines.append("## " + MemoryBookMarkdown.heading(strings.placeNotes))
            for note in placeNotes {
                lines.append("")
                lines.append(contentsOf: MemoryBookMarkdown.placeNote(note, strings: book))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `yyyy-MM-dd` in the current calendar, as day memories are keyed.
    public static func dayKey(_ date: Date) -> String {
        let parts = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func mergeSameDays(_ days: [MemoryBookDay]) -> [MemoryBookDay] {
        var result: [MemoryBookDay] = []
        for day in days {
            if let last = result.last, last.dayKey == day.dayKey {
                var merged = last
                merged.openings.append(contentsOf: day.openings)
                merged.memories.append(contentsOf: day.memories)
                merged.photos.append(contentsOf: day.photos)
                merged.photos.sort(by: photoComesFirst)
                if merged.date == nil { merged.date = day.date }
                result[result.count - 1] = merged
            } else {
                result.append(day)
            }
        }
        return result
    }

    private static func chapterComesFirst(_ lhs: Chapter, _ rhs: Chapter) -> Bool {
        switch (lhs.startDate, rhs.startDate) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    /// Photos by date, undated last, then by id, so the order never changes.
    public static func photoComesFirst(_ lhs: MemoryBookPhoto, _ rhs: MemoryBookPhoto) -> Bool {
        switch (lhs.date, rhs.date) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.id < rhs.id
        }
    }
}

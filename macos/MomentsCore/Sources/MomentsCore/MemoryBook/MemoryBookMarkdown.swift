import Foundation

/// The words a memory book is written with. The app fills these from its
/// translations and the two names from Settings; tests pass plain ones.
public struct MemoryBookStrings: Sendable {
    /// The name shown with something a person wrote.
    public var author: @Sendable (_ isOwn: Bool) -> String
    /// "Memories of A and B".
    public var memoriesOf: String
    /// The heading for chapter memories, "Before we begin".
    public var beforeWeBegin: String
    /// "Day 2 · Monday 4 May".
    public var dayHeading: @Sendable (_ number: Int, _ date: Date?) -> String
    /// A day's date on its own: "Monday 4 May 2026".
    public var dayDate: @Sendable (_ date: Date) -> String
    /// The heading of a day that has no date.
    public var undatedDay: String
    /// "3 May 2026 – 7 May 2026".
    public var dateRange: @Sendable (_ start: Date?, _ end: Date?) -> String
    /// A photo's caption: "8:42 · Fish market".
    public var photoCaption: @Sendable (_ date: Date?, _ placeName: String?) -> String
    /// "Comment · A".
    public var comment: @Sendable (_ author: String) -> String
    /// The folder the Markdown pictures go in, "Pictures".
    public var picturesFolder: String

    public init(
        author: @escaping @Sendable (_ isOwn: Bool) -> String,
        memoriesOf: String,
        beforeWeBegin: String,
        dayHeading: @escaping @Sendable (_ number: Int, _ date: Date?) -> String,
        dayDate: @escaping @Sendable (_ date: Date) -> String,
        undatedDay: String,
        dateRange: @escaping @Sendable (_ start: Date?, _ end: Date?) -> String,
        photoCaption: @escaping @Sendable (_ date: Date?, _ placeName: String?) -> String,
        comment: @escaping @Sendable (_ author: String) -> String,
        picturesFolder: String
    ) {
        self.author = author
        self.memoriesOf = memoriesOf
        self.beforeWeBegin = beforeWeBegin
        self.dayHeading = dayHeading
        self.dayDate = dayDate
        self.undatedDay = undatedDay
        self.dateRange = dateRange
        self.photoCaption = photoCaption
        self.comment = comment
        self.picturesFolder = picturesFolder
    }

    /// The heading of one day: its number and date, or the undated heading.
    public func heading(for day: MemoryBookDay) -> String {
        if let number = day.number { return dayHeading(number, day.date) }
        if let date = day.date { return dayDate(date) }
        return undatedDay
    }
}

/// A memory book as one Markdown file with numbered pictures beside it.
public enum MemoryBookMarkdown {
    public struct Picture: Equatable, Sendable {
        public var photoID: String
        /// Relative to the folder the .md file is in: "Pictures/001.jpg".
        public var path: String
        public var fileName: String
    }

    public struct Output: Equatable, Sendable {
        public var text: String
        public var pictures: [Picture]
    }

    /// The text of a prepared book (see ``MemoryBookPlan/prepared(_:options:)``)
    /// and the picture each image line points at, in order.
    public static func book(_ document: MemoryBookDocument, strings: MemoryBookStrings) -> Output {
        var lines: [String] = []
        lines.append("# " + heading(document.title))
        lines.append("")
        var subtitle: [String] = []
        if document.startDate != nil || document.endDate != nil {
            subtitle.append(strings.dateRange(document.startDate, document.endDate))
        }
        subtitle.append(strings.memoriesOf)
        lines.append(escape(subtitle.joined(separator: " · ")))
        if !document.placeNames.isEmpty {
            lines.append("")
            lines.append(escape(document.placeNames.joined(separator: " · ")))
        }

        if !document.chapterMemories.isEmpty {
            lines.append("")
            lines.append("## " + heading(strings.beforeWeBegin))
            lines.append("")
            lines.append(contentsOf: quotes(document.chapterMemories, strings: strings))
        }

        let photos = document.photos
        let width = max(3, String(photos.count).count)
        var pictures: [Picture] = []
        for day in document.days {
            lines.append("")
            lines.append("## " + heading(strings.heading(for: day)))
            lines.append(contentsOf: dayBody(day, strings: strings) { photo in
                let fileName = String(repeating: "0", count: max(0, width - String(pictures.count + 1).count))
                    + String(pictures.count + 1) + ".jpg"
                let path = strings.picturesFolder + "/" + fileName
                pictures.append(Picture(photoID: photo.id, path: path, fileName: fileName))
                let caption = strings.photoCaption(photo.date, photo.placeName)
                return ["![\(escape(caption))](\(linkTarget(path)))"]
            })
        }
        return Output(text: lines.joined(separator: "\n") + "\n", pictures: pictures)
    }

    /// A day's memories, place notes and photos. `photoLines` gives the
    /// line or lines that stand for the photo itself.
    static func dayBody(
        _ day: MemoryBookDay,
        strings: MemoryBookStrings,
        photoLines: (MemoryBookPhoto) -> [String]
    ) -> [String] {
        var lines: [String] = []
        for opening in day.openings {
            lines.append("")
            lines.append("**" + inline(opening.title) + "**")
            lines.append("")
            lines.append(contentsOf: quotes(opening.memories, strings: strings))
        }
        if !day.memories.isEmpty {
            lines.append("")
            lines.append(contentsOf: quotes(day.memories, strings: strings))
        }
        for note in day.placeNotes {
            lines.append("")
            lines.append(contentsOf: placeNote(note, strings: strings))
        }
        for photo in day.photos {
            lines.append("")
            lines.append(contentsOf: photoLines(photo))
            if !photo.memories.isEmpty {
                lines.append("")
                lines.append(contentsOf: memoryList(photo.memories, strings: strings))
            }
        }
        return lines
    }

    static func placeNote(_ note: MemoryBookPlaceNote, strings: MemoryBookStrings) -> [String] {
        let text = "**" + inline(note.placeName) + "**: " + escape(note.text) + " — " + escape(strings.author(note.isOwn))
        return paragraph(text)
    }

    /// Notes as one block quote, each ending with who wrote it.
    static func quotes(_ notes: [MemoryBookNote], strings: MemoryBookStrings) -> [String] {
        var lines: [String] = []
        for (index, note) in notes.enumerated() {
            if index > 0 { lines.append(">") }
            let text = escape(note.text) + " — " + escape(strings.author(note.isOwn))
            for line in paragraph(text) {
                lines.append(line.isEmpty ? ">" : "> " + line)
            }
        }
        return lines
    }

    /// "- A: memory" with comments nested under it.
    static func memoryList(_ memories: [MemoryBookMemory], strings: MemoryBookStrings) -> [String] {
        var lines: [String] = []
        for memory in memories {
            lines.append(contentsOf: item(escape(strings.author(memory.isOwn)) + ": " + escape(memory.text), indent: 0))
            for comment in memory.comments {
                let label = escape(strings.comment(strings.author(comment.isOwn)))
                lines.append(contentsOf: item(label + ": " + escape(comment.text), indent: 1 + min(max(comment.depth, 0), 1)))
            }
        }
        return lines
    }

    private static func item(_ text: String, indent: Int) -> [String] {
        let pad = String(repeating: "  ", count: indent)
        return paragraph(text).enumerated().map { (index: Int, line: String) -> String in
            if index == 0 { return pad + "- " + line }
            return line.isEmpty ? "" : pad + "  " + line
        }
    }

    /// Lines of a paragraph, with runs of blank lines kept to one.
    static func paragraph(_ text: String) -> [String] {
        let raw = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var lines: [String] = []
        for line in raw {
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.map(guardLineStart)
    }

    /// Escapes what Markdown would read as formatting, so a memory shows as
    /// the words that were written.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            if "\\`*_[]<>|".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// Text inside `**…**` or a heading: escaped and on one line.
    static func inline(_ text: String) -> String {
        escape(text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }

    static func heading(_ text: String) -> String { inline(text) }

    /// A line that starts like a heading, list item or numbered item would
    /// turn into one; a backslash keeps it plain text.
    private static func guardLineStart(_ line: String) -> String {
        guard let first = line.first else { return line }
        if first == "#" || first == "+" || first == "=" { return "\\" + line }
        if first == "-", line.count == 1 || line.dropFirst().first == " " || line.allSatisfy({ $0 == "-" }) {
            return "\\" + line
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count < 10 {
            let rest = line.dropFirst(digits.count)
            if let mark = rest.first, mark == "." || mark == ")",
               rest.count == 1 || rest.dropFirst().first == " " {
                return String(digits) + "\\" + String(rest)
            }
        }
        return line
    }

    private static func linkTarget(_ path: String) -> String {
        path.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }
}

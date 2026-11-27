import AppKit
import Foundation
import MomentsCore

enum MemoryBookFormat: String, CaseIterable, Sendable {
    case pdf
    case markdown
}

/// How far an export has got, for the sheet's progress line.
struct MemoryBookProgress: Equatable, Sendable {
    var done: Int
    var total: Int
    /// The day being laid out, as the book names it.
    var dayLabel: String
}

/// Writes a memory book in the background: photos are read and re-encoded
/// one at a time, the file is built in a temporary place and moved where
/// the person chose only when it is complete, so stopping or failing never
/// leaves half a file behind.
enum MemoryBookExporter {
    struct Result: Sendable {
        let url: URL
        /// Photos whose full copy couldn't be read, so the thumbnail went in.
        let thumbnailsUsed: Int
    }

    // MARK: Words

    /// The book's words in the person's language, with the two names from
    /// Settings (the sheet asks for them first, so neither is empty).
    static func strings(myName: String, partnerName: String) -> MemoryBookStrings {
        let mine = AuthorNames.label(isOwn: true, myName: myName, partnerName: partnerName)
        let theirs = AuthorNames.label(isOwn: false, myName: myName, partnerName: partnerName)
        let range = DateIntervalFormatter()
        range.dateStyle = .long
        range.timeStyle = .none
        let rangeFormatter = UncheckedSendable(range)
        return MemoryBookStrings(
            author: { $0 ? mine : theirs },
            memoriesOf: String(localized: "Memories of \(mine) and \(theirs)"),
            beforeWeBegin: String(localized: "Before we begin"),
            dayHeading: { number, date in
                guard let date else { return String(localized: "Day \(number)") }
                let day = date.formatted(.dateTime.weekday(.wide).month(.wide).day())
                return String(localized: "Day \(number) · \(day)")
            },
            dayDate: { $0.formatted(.dateTime.weekday(.wide).month(.wide).day().year()) },
            undatedDay: String(localized: "Without a date"),
            dateRange: { start, end in
                guard let start = start ?? end else { return "" }
                return rangeFormatter.value.string(from: start, to: end ?? start)
            },
            photoCaption: { date, place in
                let parts = [date?.formatted(date: .omitted, time: .shortened), place].compactMap { $0 }.filter { !$0.isEmpty }
                return parts.isEmpty ? String(localized: "Photo") : parts.joined(separator: " · ")
            },
            comment: { String(localized: "Comment · \($0)") },
            picturesFolder: String(localized: "Pictures")
        )
    }

    /// A name that is safe as a file or folder name.
    static func fileName(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? String(localized: "Memory Book") : String(cleaned.prefix(120))
    }

    // MARK: Export

    /// `book` is prepared (see `MemoryBookPlan.prepared`). `progress` is
    /// called from the export's own task.
    static func export(
        _ book: MemoryBookDocument,
        sources: [String: MemoryBookImages.Source],
        format: MemoryBookFormat,
        strings: MemoryBookStrings,
        to destination: URL,
        progress: @escaping @Sendable (MemoryBookProgress) -> Void
    ) async throws -> Result {
        let fileManager = FileManager.default
        let workFolder = (try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true))
            ?? fileManager.temporaryDirectory.appending(path: "MemoryBook-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: workFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workFolder) }

        let work = workFolder.appending(path: destination.lastPathComponent)
        let dayOfPhoto = dayLabels(book, strings: strings)
        let total = book.photos.count
        var done = 0
        var thumbnails = 0
        func report(_ id: String) {
            done += 1
            progress(MemoryBookProgress(done: min(done, total), total: total, dayLabel: dayOfPhoto[id] ?? ""))
        }
        progress(MemoryBookProgress(done: 0, total: total, dayLabel: book.days.first.map(strings.heading(for:)) ?? ""))

        switch format {
        case .pdf:
            let coverID = book.photos.first?.id
            var ratios: [String: Double] = [:]
            for (id, source) in sources { if let ratio = source.aspectRatio { ratios[id] = ratio } }
            let input = MemoryBookLayout.Input(
                document: book,
                strings: strings,
                aspectRatios: ratios,
                coverPhotoID: coverID,
                coverFooterRight: Date.now.formatted(.dateTime.year().month(.wide)),
                madeWith: String(localized: "Made with Moments")
            )
            let pages = MemoryBookLayout.pages(input, metrics: MemoryBookPDF.metrics, measure: MemoryBookPDF.measure)
            var counted: Set<String> = []
            try await MemoryBookPDF.write(pages, title: book.title, to: work, image: { id, frame, fills in
                guard let source = sources[id] else { return nil }
                let loaded = await MemoryBookImages.load(source)
                if counted.insert(id).inserted {
                    if loaded.quality == .thumbnail || loaded.quality == .missing { thumbnails += 1 }
                    report(id)
                }
                return loaded.image.flatMap { MemoryBookImages.forPDF($0, frame: frame, fills: fills) }
            }, page: { _ in
                try Task.checkCancellation()
            })
        case .markdown:
            try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
            let output = MemoryBookMarkdown.book(book, strings: strings)
            if !output.pictures.isEmpty {
                try fileManager.createDirectory(at: work.appending(path: strings.picturesFolder, directoryHint: .isDirectory), withIntermediateDirectories: true)
            }
            for picture in output.pictures {
                try Task.checkCancellation()
                if let source = sources[picture.photoID] {
                    let loaded = await MemoryBookImages.load(source)
                    if loaded.quality == .thumbnail || loaded.quality == .missing { thumbnails += 1 }
                    if let image = loaded.image, let data = MemoryBookImages.jpeg(image, maxPixelSize: MemoryBookImages.markdownPixelSize) {
                        try data.write(to: work.appending(path: picture.path))
                    }
                }
                report(picture.photoID)
            }
            try Task.checkCancellation()
            let text = work.appending(path: fileName(book.title) + ".md")
            try Data(output.text.utf8).write(to: text)
        }
        try Task.checkCancellation()

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: work)
        } else {
            try fileManager.moveItem(at: work, to: destination)
        }
        return Result(url: destination, thumbnailsUsed: thumbnails)
    }

    /// "Export All Memories": one Markdown file, no photos.
    static func exportArchive(_ text: String, to destination: URL) throws {
        try Data(text.utf8).write(to: destination, options: .atomic)
    }

    private static func dayLabels(_ book: MemoryBookDocument, strings: MemoryBookStrings) -> [String: String] {
        var labels: [String: String] = [:]
        for day in book.days {
            let label = day.date.map { $0.formatted(.dateTime.month(.wide).day()) } ?? strings.heading(for: day)
            for photo in day.photos { labels[photo.id] = label }
        }
        return labels
    }
}

/// A formatter that is only read after it is set up, shared by the
/// closures of `MemoryBookStrings`.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

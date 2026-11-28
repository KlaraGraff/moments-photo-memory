import Foundation

/// Where everything goes on the pages of a memory book's PDF. The app
/// measures text with CoreText and draws what this lays out; the layout
/// itself is plain arithmetic, so Linux tests can check it.

public struct MemoryBookRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func offsetBy(dy: Double) -> MemoryBookRect {
        MemoryBookRect(x: x, y: y + dy, width: width, height: height)
    }

    public func intersects(_ other: MemoryBookRect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    public func contains(_ other: MemoryBookRect) -> Bool {
        other.x >= x - 0.001 && other.maxX <= maxX + 0.001 && other.y >= y - 0.001 && other.maxY <= maxY + 0.001
    }
}

public enum MemoryBookTextStyle: String, Equatable, Sendable, CaseIterable {
    case coverTitle
    case coverDetail
    case coverNames
    case sectionLabel
    case dayHeading
    case body
    case caption
    case comment
    case footer
}

/// A stretch of text in one look. An author run is drawn in that
/// person's colour.
public enum MemoryBookRun: Equatable, Sendable {
    case plain(String)
    case bold(String)
    case author(String, isOwn: Bool)

    public var string: String {
        switch self {
        case let .plain(text), let .bold(text), let .author(text, _): return text
        }
    }
}

public struct MemoryBookText: Equatable, Sendable {
    public var runs: [MemoryBookRun]
    public var style: MemoryBookTextStyle

    public init(_ runs: [MemoryBookRun], style: MemoryBookTextStyle) {
        self.runs = runs
        self.style = style
    }

    public var string: String { runs.map(\.string).joined() }
}

public struct MemoryBookPiece: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case text(MemoryBookText)
        /// `fills`: the photo is cropped to fill its frame (the cover);
        /// otherwise the frame already has the photo's shape.
        case photo(id: String, fills: Bool)
    }

    public var content: Content
    public var frame: MemoryBookRect
}

public struct MemoryBookPage: Equatable, Sendable {
    public var pieces: [MemoryBookPiece]
    /// Left and right of the footer line: the chapter's name and the page
    /// number, or "Made with Moments" and the month on the cover.
    public var footer: (left: String, right: String)

    public static func == (lhs: MemoryBookPage, rhs: MemoryBookPage) -> Bool {
        lhs.pieces == rhs.pieces && lhs.footer.left == rhs.footer.left && lhs.footer.right == rhs.footer.right
    }

    public var photoIDs: [String] {
        pieces.compactMap { piece in
            if case let .photo(id, _) = piece.content { return id }
            return nil
        }
    }

    public var text: String {
        pieces.compactMap { piece in
            if case let .text(text) = piece.content { return text.string }
            return nil
        }.joined(separator: "\n")
    }
}

public struct MemoryBookLayoutMetrics: Equatable, Sendable {
    /// A4 portrait in points.
    public var pageWidth = 595.28
    public var pageHeight = 841.89
    public var margin = 56.0
    /// Room kept at the bottom for the footer line.
    public var footerHeight = 22.0
    public var blockSpacing = 14.0
    /// Between a photo and its caption, and between lines of one block.
    public var innerSpacing = 6.0
    public var columnGap = 18.0
    public var commentIndent = 16.0
    /// The tallest a photo on its own may be.
    public var singlePhotoMaxHeight = 380.0
    /// The tallest a photo in a pair may be.
    public var pairPhotoMaxHeight = 220.0
    /// The cover photo's height as a share of the text width.
    public var coverPhotoRatio = 0.85

    public init() {}

    public static let a4 = MemoryBookLayoutMetrics()

    public var contentWidth: Double { pageWidth - margin * 2 }
    public var contentHeight: Double { pageHeight - margin * 2 - footerHeight }
}

public enum MemoryBookLayout {
    /// The height `text` takes when wrapped at `width`.
    public typealias Measure = @Sendable (_ text: MemoryBookText, _ width: Double) -> Double

    public struct Input: Sendable {
        /// A prepared book (see ``MemoryBookPlan/prepared(_:options:)``).
        public var document: MemoryBookDocument
        public var strings: MemoryBookStrings
        /// Width over height of each photo; 4:3 when unknown.
        public var aspectRatios: [String: Double]
        /// The photo on the cover, if any.
        public var coverPhotoID: String?
        /// The right side of the cover's footer, such as the month of export.
        public var coverFooterRight: String
        /// "Made with Moments".
        public var madeWith: String

        public init(
            document: MemoryBookDocument,
            strings: MemoryBookStrings,
            aspectRatios: [String: Double] = [:],
            coverPhotoID: String? = nil,
            coverFooterRight: String = "",
            madeWith: String
        ) {
            self.document = document
            self.strings = strings
            self.aspectRatios = aspectRatios
            self.coverPhotoID = coverPhotoID
            self.coverFooterRight = coverFooterRight
            self.madeWith = madeWith
        }
    }

    struct Block {
        var height: Double
        var pieces: [MemoryBookPiece]
        var keepsWithNext = false
        var startsPage = false
    }

    /// The pages, in order. Positions are in points from the page's top-left.
    public static func pages(_ input: Input, metrics: MemoryBookLayoutMetrics = .a4, measure: Measure) -> [MemoryBookPage] {
        let laidOut = blocks(input, metrics: metrics, measure: measure)
        let indexes = MemoryBookPagination.pages(
            laidOut.map { MemoryBookPagination.Block(height: $0.height, keepsWithNext: $0.keepsWithNext, startsPage: $0.startsPage) },
            pageHeight: metrics.contentHeight,
            spacing: metrics.blockSpacing
        )
        return indexes.enumerated().map { (pageIndex: Int, blockIndexes: [Int]) -> MemoryBookPage in
            var y = metrics.margin
            var pieces: [MemoryBookPiece] = []
            for (position, index) in blockIndexes.enumerated() {
                if position > 0 { y += metrics.blockSpacing }
                let block = laidOut[index]
                pieces.append(contentsOf: block.pieces.map { MemoryBookPiece(content: $0.content, frame: $0.frame.offsetBy(dy: y)) })
                y += block.height
            }
            let footer = pageIndex == 0
                ? (left: input.madeWith, right: input.coverFooterRight)
                : (left: input.document.title, right: String(pageIndex + 1))
            return MemoryBookPage(pieces: pieces, footer: footer)
        }
    }

    static func blocks(_ input: Input, metrics: MemoryBookLayoutMetrics, measure: Measure) -> [Block] {
        let document = input.document
        let strings = input.strings
        let width = metrics.contentWidth
        let x = metrics.margin
        var blocks: [Block] = []

        // The cover: photo, title, dates and places, whose memories these are.
        var cover = Stack(x: x, width: width, spacing: metrics.innerSpacing)
        if let id = input.coverPhotoID {
            cover.photo(id, width: width, height: (width * metrics.coverPhotoRatio).rounded(), fills: true)
            cover.space(10)
        }
        cover.text(MemoryBookText([.plain(document.title)], style: .coverTitle), measure)
        var details: [String] = []
        if document.startDate != nil || document.endDate != nil {
            details.append(strings.dateRange(document.startDate, document.endDate))
        }
        if !document.placeNames.isEmpty { details.append(document.placeNames.joined(separator: ", ")) }
        if !details.isEmpty { cover.text(MemoryBookText([.plain(details.joined(separator: " · "))], style: .coverDetail), measure) }
        cover.text(MemoryBookText([.plain(strings.memoriesOf)], style: .coverNames), measure)
        blocks.append(cover.block(startsPage: true, keepsWithNext: !document.chapterMemories.isEmpty))

        if !document.chapterMemories.isEmpty {
            blocks.append(textBlock(MemoryBookText([.plain(strings.beforeWeBegin)], style: .sectionLabel), x: x, width: width, measure: measure, keepsWithNext: true))
            for note in document.chapterMemories {
                blocks.append(contentsOf: noteBlocks(note.text, author: strings.author(note.isOwn), isOwn: note.isOwn, style: .body, x: x, width: width, measure: measure))
            }
        }

        for day in document.days {
            blocks.append(textBlock(MemoryBookText([.plain(strings.heading(for: day))], style: .dayHeading), x: x, width: width, measure: measure, keepsWithNext: true, startsPage: true))
            for note in day.memories {
                blocks.append(contentsOf: noteBlocks(note.text, author: strings.author(note.isOwn), isOwn: note.isOwn, style: .body, x: x, width: width, measure: measure))
            }
            for note in day.placeNotes {
                blocks.append(contentsOf: noteBlocks(note.text, lead: note.placeName, author: strings.author(note.isOwn), isOwn: note.isOwn, style: .body, x: x, width: width, measure: measure))
            }
            for row in MemoryBookPlan.rows(day.photos) {
                if row.count == 2 {
                    blocks.append(pairBlock(row, input: input, metrics: metrics, measure: measure))
                } else if let photo = row.first {
                    blocks.append(contentsOf: singleBlocks(photo, input: input, metrics: metrics, measure: measure))
                }
            }
        }
        return blocks
    }

    /// A photo on its own: the photo and caption together, then each memory
    /// and comment, so long writing can carry on to the next page.
    static func singleBlocks(_ photo: MemoryBookPhoto, input: Input, metrics: MemoryBookLayoutMetrics, measure: Measure) -> [Block] {
        let x = metrics.margin
        let width = metrics.contentWidth
        let ratio = aspect(photo.id, input)
        var height = width / ratio
        var photoWidth = width
        if height > metrics.singlePhotoMaxHeight {
            height = metrics.singlePhotoMaxHeight
            photoWidth = height * ratio
        }
        var stack = Stack(x: x, width: width, spacing: metrics.innerSpacing)
        stack.photo(photo.id, width: photoWidth.rounded(.down), height: height.rounded(.down), fills: false)
        stack.text(caption(photo, input.strings), measure)
        var blocks = [stack.block(keepsWithNext: !photo.memories.isEmpty)]
        for memory in photo.memories {
            blocks.append(contentsOf: noteBlocks(memory.text, author: input.strings.author(memory.isOwn), isOwn: memory.isOwn, style: .body, x: x, width: width, measure: measure))
            for comment in memory.comments {
                let indent = metrics.commentIndent * Double(1 + min(max(comment.depth, 0), 1))
                let name = input.strings.author(comment.isOwn)
                let text = MemoryBookText([.author(name + nameSeparator(name), isOwn: comment.isOwn), .plain(comment.text)], style: .comment)
                blocks.append(textBlock(text, x: x + indent, width: width - indent, measure: measure))
            }
        }
        return blocks
    }

    /// Two photos with short memories side by side, each with its words.
    static func pairBlock(_ photos: [MemoryBookPhoto], input: Input, metrics: MemoryBookLayoutMetrics, measure: Measure) -> Block {
        let columnWidth = ((metrics.contentWidth - metrics.columnGap) / 2).rounded(.down)
        var pieces: [MemoryBookPiece] = []
        var height = 0.0
        for (index, photo) in photos.enumerated() {
            let x = metrics.margin + Double(index) * (columnWidth + metrics.columnGap)
            let ratio = aspect(photo.id, input)
            var photoHeight = columnWidth / ratio
            var photoWidth = columnWidth
            if photoHeight > metrics.pairPhotoMaxHeight {
                photoHeight = metrics.pairPhotoMaxHeight
                photoWidth = photoHeight * ratio
            }
            var stack = Stack(x: x, width: columnWidth, spacing: metrics.innerSpacing)
            stack.photo(photo.id, width: photoWidth.rounded(.down), height: photoHeight.rounded(.down), fills: false)
            stack.text(caption(photo, input.strings), measure)
            for memory in photo.memories {
                stack.text(authored(memory.text, author: input.strings.author(memory.isOwn), isOwn: memory.isOwn, style: .body), measure)
            }
            pieces.append(contentsOf: stack.pieces)
            height = max(height, stack.height)
        }
        return Block(height: height, pieces: pieces)
    }

    /// A note split at its paragraphs, the name after the last one, so a
    /// long note doesn't need a page to itself.
    static func noteBlocks(
        _ text: String,
        lead: String? = nil,
        author: String,
        isOwn: Bool,
        style: MemoryBookTextStyle,
        x: Double,
        width: Double,
        measure: Measure
    ) -> [Block] {
        let paragraphs = MemoryBookPlan.paragraphs(text)
        return paragraphs.enumerated().map { (index: Int, paragraph: String) -> Block in
            var runs: [MemoryBookRun] = []
            if index == 0, let lead { runs.append(.bold(lead + "  ")) }
            runs.append(.plain(paragraph))
            if index == paragraphs.count - 1 { runs.append(.author(" — " + author, isOwn: isOwn)) }
            return textBlock(MemoryBookText(runs, style: style), x: x, width: width, measure: measure, keepsWithNext: index < paragraphs.count - 1)
        }
    }

    static func authored(_ text: String, author: String, isOwn: Bool, style: MemoryBookTextStyle) -> MemoryBookText {
        MemoryBookText([.plain(MemoryBookPlan.paragraphs(text).joined(separator: "\n")), .author(" — " + author, isOwn: isOwn)], style: style)
    }

    static func caption(_ photo: MemoryBookPhoto, _ strings: MemoryBookStrings) -> MemoryBookText {
        MemoryBookText([.plain(strings.photoCaption(photo.date, photo.placeName))], style: .caption)
    }

    static func textBlock(
        _ text: MemoryBookText,
        x: Double,
        width: Double,
        measure: Measure,
        keepsWithNext: Bool = false,
        startsPage: Bool = false
    ) -> Block {
        let height = measure(text, width).rounded(.up)
        return Block(
            height: height,
            pieces: [MemoryBookPiece(content: .text(text), frame: MemoryBookRect(x: x, y: 0, width: width, height: height))],
            keepsWithNext: keepsWithNext,
            startsPage: startsPage
        )
    }

    /// "A: " in Latin text, "A：" in Chinese or Japanese.
    static func nameSeparator(_ name: String) -> String {
        name.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) } ? "：" : ": "
    }

    static func aspect(_ id: String, _ input: Input) -> Double {
        guard let ratio = input.aspectRatios[id], ratio.isFinite, ratio > 0.05, ratio < 20 else { return 4.0 / 3.0 }
        return ratio
    }

    /// Pieces stacked top to bottom in one column.
    struct Stack {
        let x: Double
        let width: Double
        let spacing: Double
        var pieces: [MemoryBookPiece] = []
        var height = 0.0
        private var needsSpacing = false

        init(x: Double, width: Double, spacing: Double) {
            self.x = x
            self.width = width
            self.spacing = spacing
        }

        mutating func photo(_ id: String, width photoWidth: Double, height photoHeight: Double, fills: Bool) {
            if needsSpacing { height += spacing }
            pieces.append(MemoryBookPiece(content: .photo(id: id, fills: fills), frame: MemoryBookRect(x: x, y: height, width: photoWidth, height: photoHeight)))
            height += photoHeight
            needsSpacing = true
        }

        mutating func text(_ text: MemoryBookText, _ measure: Measure) {
            if needsSpacing { height += spacing }
            let textHeight = measure(text, width).rounded(.up)
            pieces.append(MemoryBookPiece(content: .text(text), frame: MemoryBookRect(x: x, y: height, width: width, height: textHeight)))
            height += textHeight
            needsSpacing = true
        }

        mutating func space(_ amount: Double) {
            height += amount
            needsSpacing = false
        }

        func block(startsPage: Bool = false, keepsWithNext: Bool = false) -> Block {
            Block(height: height, pieces: pieces, keepsWithNext: keepsWithNext, startsPage: startsPage)
        }
    }
}

extension MemoryBookPlan {
    /// A note's paragraphs, trimmed, blank ones dropped.
    public static func paragraphs(_ text: String) -> [String] {
        let parts = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [text.trimmingCharacters(in: .whitespacesAndNewlines)] : parts
    }
}

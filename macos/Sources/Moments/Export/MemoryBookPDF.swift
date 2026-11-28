import AppKit
import CoreText
import ImageIO
import MomentsCore
import UniformTypeIdentifiers

/// Draws a memory book's pages (laid out by `MemoryBookLayout`) into an A4
/// PDF. Text is real text, so it can be searched and copied; photos are
/// redrawn pixels, so nothing of the original files goes in.
enum MemoryBookPDF {
    static let metrics = MemoryBookLayoutMetrics.a4

    // MARK: Look

    static let ink = CGColor(srgbRed: 0.227, green: 0.165, blue: 0.141, alpha: 1)
    static let muted = CGColor(srgbRed: 0.478, green: 0.365, blue: 0.314, alpha: 1)
    /// The person on this Mac: the app's accent.
    static let ownColor = CGColor(srgbRed: 0.690, green: 0.290, blue: 0.184, alpha: 1)
    /// The other person: the app's partner colour.
    static let partnerColor = CGColor(srgbRed: 0.541, green: 0.353, blue: 0.549, alpha: 1)
    static let rule = CGColor(srgbRed: 0.902, green: 0.804, blue: 0.741, alpha: 1)
    static let placeholder = CGColor(srgbRed: 0.961, green: 0.918, blue: 0.886, alpha: 1)

    private static func font(_ style: MemoryBookTextStyle) -> NSFont {
        switch style {
        case .coverTitle: return serif(28, weight: .semibold)
        case .coverDetail: return .systemFont(ofSize: 10)
        case .coverNames: return serif(14)
        case .sectionLabel: return .systemFont(ofSize: 9, weight: .semibold)
        case .dayHeading: return serif(18, weight: .medium)
        case .body: return serif(10.5)
        case .caption: return .monospacedDigitSystemFont(ofSize: 8, weight: .regular)
        case .comment: return serif(9.5)
        case .footer: return .monospacedDigitSystemFont(ofSize: 7.5, weight: .regular)
        }
    }

    private static func color(_ style: MemoryBookTextStyle) -> CGColor {
        switch style {
        case .coverDetail, .sectionLabel, .caption, .footer: return muted
        default: return ink
        }
    }

    private static func lineSpacing(_ style: MemoryBookTextStyle) -> CGFloat {
        switch style {
        case .body, .comment: return 3
        case .coverDetail, .coverNames: return 2
        default: return 0
        }
    }

    private static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.serif), let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return base
    }

    /// CoreText's own colour key, which takes a CGColor.
    private static let foregroundColor = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

    static func attributed(_ text: MemoryBookText) -> NSAttributedString {
        let base = font(text.style)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing(text.style)
        paragraph.lineBreakMode = .byWordWrapping
        let result = NSMutableAttributedString()
        for run in text.runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: base,
                foregroundColor: color(text.style),
                .paragraphStyle: paragraph,
            ]
            switch run {
            case .plain:
                break
            case .bold:
                attributes[.font] = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
            case let .author(_, isOwn):
                attributes[foregroundColor] = isOwn ? ownColor : partnerColor
            }
            result.append(NSAttributedString(string: run.string, attributes: attributes))
        }
        return result
    }

    /// How tall `text` is when wrapped at `width`, in points.
    static let measure: MemoryBookLayout.Measure = { text, width in
        let setter = CTFramesetterCreateWithAttributedString(attributed(text))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil
        )
        return Double(ceil(size.height)) + 1
    }

    // MARK: Writing

    enum Failure: Error {
        case couldNotCreate
    }

    /// Writes the pages to `url`, one page at a time so a big chapter never
    /// holds all its photos at once. `image` gives the prepared photo for
    /// a photo piece (see `MemoryBookImages.forPDF`), keyed by its place on the page; `page` is called after each
    /// page and throws to stop.
    static func write(
        _ pages: [MemoryBookPage],
        title: String,
        to url: URL,
        image: (_ id: String, _ frame: MemoryBookRect, _ fills: Bool) async -> CGImage?,
        page: (Int) async throws -> Void
    ) async throws {
        var mediaBox = CGRect(x: 0, y: 0, width: metrics.pageWidth, height: metrics.pageHeight)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, [
            kCGPDFContextCreator: "Moments",
            kCGPDFContextTitle: title,
        ] as CFDictionary) else { throw Failure.couldNotCreate }
        var closed = false
        defer { if !closed { context.closePDF() } }
        for (index, content) in pages.enumerated() {
            var images: [Int: CGImage] = [:]
            for (position, piece) in content.pieces.enumerated() {
                if case let .photo(id, fills) = piece.content {
                    images[position] = await image(id, piece.frame, fills)
                }
            }
            context.beginPDFPage(nil)
            context.saveGState()
            // Top-left origin, as the layout measures.
            context.translateBy(x: 0, y: mediaBox.height)
            context.scaleBy(x: 1, y: -1)
            draw(content, images: images, in: context)
            context.restoreGState()
            context.endPDFPage()
            try await page(index)
        }
        context.closePDF()
        closed = true
    }

    /// One page into a context whose origin is the page's top left.
    static func draw(_ content: MemoryBookPage, images: [Int: CGImage], in context: CGContext) {
        for (position, piece) in content.pieces.enumerated() {
            switch piece.content {
            case let .text(text):
                drawText(text, in: cgRect(piece.frame), context: context)
            case let .photo(_, fills):
                let frame = cgRect(piece.frame)
                if let image = images[position] {
                    drawImage(image, in: frame, fills: fills, context: context)
                } else {
                    context.setFillColor(placeholder)
                    context.fill(frame)
                }
            }
        }
        // The footer: a thin rule, the chapter's name and the page number.
        let y = metrics.pageHeight - metrics.margin + 6
        let left = CGFloat(metrics.margin)
        let width = CGFloat(metrics.contentWidth)
        context.setStrokeColor(rule)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: left, y: y))
        context.addLine(to: CGPoint(x: left + width, y: y))
        context.strokePath()
        let box = CGRect(x: left, y: y + 5, width: width, height: 14)
        drawText(MemoryBookText([.plain(content.footer.left)], style: .footer), in: box, alignment: .left, context: context)
        drawText(MemoryBookText([.plain(content.footer.right)], style: .footer), in: box, alignment: .right, context: context)
    }

    private static func cgRect(_ rect: MemoryBookRect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private static func drawText(_ text: MemoryBookText, in rect: CGRect, alignment: NSTextAlignment = .natural, context: CGContext) {
        guard !text.string.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let string = NSMutableAttributedString(attributedString: attributed(text))
        if alignment != .natural {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byTruncatingTail
            string.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: string.length))
        }
        let setter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        context.saveGState()
        // CoreText draws bottom-up: flip back for the text alone.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private static func drawImage(_ image: CGImage, in rect: CGRect, fills: Bool, context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        var target = rect
        if fills, image.width > 0, image.height > 0 {
            // Fill the frame, cropping the middle of the photo.
            let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        }
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: target.size))
        context.restoreGState()
    }
}

/// Reading photos for an export and writing them out again without any of
/// the original file's metadata.
enum MemoryBookImages {
    /// Where one photo can be read from, gathered on the store's context.
    struct Source: Sendable {
        let id: String
        let original: PeopleMediaDescriptor
        /// The other person's photo, when only its shared preview is here.
        let sharedPreview: URL?
        let thumbnail: ThumbnailSource
        /// Width over height, from the library; 4:3 when unknown.
        let aspectRatio: Double?
    }

    enum Quality: Equatable, Sendable {
        case original
        case sharedPreview
        case thumbnail
        case missing
    }

    /// The photo at up to about 2,000 pixels, never downloading from iCloud:
    /// the original or Photos' copy, else the shared preview, else the
    /// thumbnail the app keeps.
    static func load(_ source: Source) async -> (image: CGImage?, quality: Quality) {
        if source.original.photosLocalIdentifier != nil || source.original.bookmarkData != nil,
           let image = await PeopleImageLoader.load(source.original, allowDownload: false) {
            return (image, .original)
        }
        if let url = source.sharedPreview, let image = decoded(url: url, maxPixelSize: 2_000) {
            return (image, .sharedPreview)
        }
        let thumbnail = await ThumbnailCache.shared.image(for: source.thumbnail, width: 1_024, height: 1_024)
        if let image = thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return (image, .thumbnail)
        }
        return (nil, .missing)
    }

    static func decoded(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false,
        ] as CFDictionary)
    }

    /// Redraws the pixels at no more than `maxPixelSize` on the long side
    /// (never larger than they are) and encodes a JPEG with no metadata:
    /// no location, camera, dates or original name.
    static func jpeg(_ image: CGImage, maxPixelSize: Int, quality: Double = 0.85) -> Data? {
        let longEdge = max(image.width, image.height)
        guard longEdge > 0 else { return nil }
        let scale = min(1, Double(maxPixelSize) / Double(longEdge))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// A photo for one frame of the PDF: at most 300 dpi for the frame,
    /// re-encoded as JPEG so the PDF stays small and carries no metadata.
    /// `fills`: the photo is cropped to fill the frame (the cover).
    static func forPDF(_ image: CGImage, frame: MemoryBookRect, fills: Bool = false) -> CGImage? {
        guard image.width > 0, image.height > 0 else { return nil }
        let width = Double(image.width), height = Double(image.height)
        let fit = fills ? max(frame.width / width, frame.height / height) : min(frame.width / width, frame.height / height)
        let pixels = Int((max(width, height) * fit / 72 * 300).rounded(.up))
        guard let data = jpeg(image, maxPixelSize: max(64, pixels)),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The Markdown folder's pictures: 1,600 pixels on the long side.
    static let markdownPixelSize = 1_600
}

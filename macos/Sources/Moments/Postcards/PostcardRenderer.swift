import AppKit
import CoreText
import MomentsCore

/// What goes on one postcard; the sheet edits it, the renderer draws it.
struct PostcardContent: Equatable {
    var template: PostcardTemplate = .fullBleed
    var orientation: PostcardOrientation = .landscape
    /// Where the photo's visible part sits (see `PostcardCrop`).
    var focus = CGPoint(x: 0.5, y: 0.5)
    /// Nil when the person turned it off.
    var dateText: String?
    var placeText: String?
    var message = ""
    /// The words in the stamp box.
    var stampLabel = ""
}

enum PostcardSide {
    case front
    case back
}

/// Draws a postcard into a PDF for a print shop, and into bitmaps for the
/// sheet's preview, from the same code, so what the sheet shows is what is
/// printed. All drawing is in millimetres, origin top left of the page with
/// its bleed.
enum PostcardRenderer {
    static let spec = PostcardSpec.standard

    // MARK: Colours

    /// The print colours, in CMYK so the PDF needs no conversion at the shop.
    private static let cmyk = CGColorSpace(name: CGColorSpace.genericCMYK)!

    private static func printColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
        let rgb = CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        return rgb.converted(to: cmyk, intent: .perceptual, options: nil) ?? rgb
    }

    static let paper = printColor(0.992, 0.980, 0.965)
    static let ink = printColor(0.227, 0.165, 0.141)
    static let muted = printColor(0.478, 0.365, 0.314)
    static let rule = printColor(0.851, 0.761, 0.702)
    static let white = printColor(1, 1, 1)

    // MARK: PDF

    /// Two pages, picture side then message side, each the card plus its
    /// bleed, with the trim and bleed boxes a print shop reads. The photo is
    /// converted to CMYK and scaled to what 300 dpi needs; nothing about the
    /// original file (location, camera, dates) goes into the PDF.
    static func pdfData(_ content: PostcardContent, image: CGImage) -> Data? {
        let pageMM = spec.pageSize(content.orientation)
        let scale = PostcardSpec.pointsPerMillimetre
        var mediaBox = CGRect(x: 0, y: 0, width: pageMM.width * scale, height: pageMM.height * scale)
        let bleed = spec.bleed * scale
        let trimBox = mediaBox.insetBy(dx: bleed, dy: bleed)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, [
                  kCGPDFContextCreator: "Moments",
                  kCGPDFContextTitle: String(localized: "Postcard"),
              ] as CFDictionary) else { return nil }
        let pageInfo = [
            kCGPDFContextMediaBox: boxData(mediaBox),
            kCGPDFContextBleedBox: boxData(mediaBox),
            kCGPDFContextTrimBox: boxData(trimBox),
        ] as CFDictionary
        let printImage = preparedPhoto(content, image: image)
        for side in [PostcardSide.front, .back] {
            context.beginPDFPage(pageInfo)
            context.saveGState()
            context.translateBy(x: 0, y: mediaBox.height)
            context.scaleBy(x: scale, y: -scale)
            draw(side, content, image: printImage, in: context, photoIsCropped: true)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private static func boxData(_ rect: CGRect) -> CFData {
        var box = rect
        return Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
    }

    /// The visible part of the photo, at no more pixels than 300 dpi needs,
    /// in CMYK.
    static func preparedPhoto(_ content: PostcardContent, image: CGImage) -> CGImage {
        let frame = PostcardFrontLayout(template: content.template, orientation: content.orientation).photo
        let source = cropRect(content, frame: frame, image: image)
        guard let cropped = image.cropping(to: source.integral) else { return image }
        let width = min(cropped.width, spec.pixels(forMillimetres: frame.width))
        let height = min(cropped.height, spec.pixels(forMillimetres: frame.height))
        guard let bitmap = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: cmyk, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return cropped }
        bitmap.interpolationQuality = .high
        bitmap.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bitmap.makeImage() ?? cropped
    }

    private static func cropRect(_ content: PostcardContent, frame: CGRect, image: CGImage) -> CGRect {
        PostcardCrop.sourceRect(
            imageSize: CGSize(width: image.width, height: image.height),
            frame: frame.size,
            focus: content.focus
        )
    }

    // MARK: Preview

    /// One side as a bitmap `pixelWidth` wide, bleed included and marked with
    /// faint stripes, as the sheet shows it.
    static func previewImage(_ side: PostcardSide, _ content: PostcardContent, image: CGImage?, pixelWidth: Int) -> CGImage? {
        let pageMM = spec.pageSize(content.orientation)
        let scale = CGFloat(pixelWidth) / pageMM.width
        let pixelHeight = Int((pageMM.height * scale).rounded())
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        draw(side, content, image: image, in: context, photoIsCropped: false)
        markBleed(content.orientation, in: context)
        return context.makeImage()
    }

    private static func markBleed(_ orientation: PostcardOrientation, in context: CGContext) {
        let page = CGRect(origin: .zero, size: spec.pageSize(orientation))
        let trim = spec.trimRect(orientation)
        context.saveGState()
        let band = CGMutablePath()
        band.addRect(page)
        band.addRect(trim)
        context.addPath(band)
        context.clip(using: .evenOdd)
        context.setFillColor(CGColor(srgbRed: 0.984, green: 0.945, blue: 0.918, alpha: 0.55))
        context.fill(page)
        context.setStrokeColor(CGColor(srgbRed: 0.690, green: 0.290, blue: 0.184, alpha: 0.35))
        context.setLineWidth(0.35)
        var x = -page.height
        while x < page.width {
            context.move(to: CGPoint(x: x, y: page.height))
            context.addLine(to: CGPoint(x: x + page.height, y: 0))
            x += 1.6
        }
        context.strokePath()
        context.restoreGState()
    }

    // MARK: Drawing

    /// `photoIsCropped`: the image is already the visible part (the PDF);
    /// otherwise the crop is taken here (the preview).
    private static func draw(_ side: PostcardSide, _ content: PostcardContent, image: CGImage?, in context: CGContext, photoIsCropped: Bool) {
        let page = CGRect(origin: .zero, size: spec.pageSize(content.orientation))
        context.setFillColor(side == .front && content.template == .fullBleed ? ink : paper)
        context.fill(page)
        switch side {
        case .front:
            drawFront(content, image: image, in: context, photoIsCropped: photoIsCropped)
        case .back:
            if content.orientation == .portrait {
                // The back is laid out landscape; on a portrait card it is
                // turned a quarter, its top along the page's right edge.
                context.saveGState()
                context.translateBy(x: page.width, y: 0)
                context.rotate(by: .pi / 2)
                drawBack(content, in: context)
                context.restoreGState()
            } else {
                drawBack(content, in: context)
            }
        }
    }

    private static func drawFront(_ content: PostcardContent, image: CGImage?, in context: CGContext, photoIsCropped: Bool) {
        let layout = PostcardFrontLayout(template: content.template, orientation: content.orientation)
        if let image {
            let visible: CGImage?
            if photoIsCropped {
                visible = image
            } else {
                visible = image.cropping(to: cropRect(content, frame: layout.photo, image: image).integral)
            }
            if let visible { drawImage(visible, in: layout.photo, context: context) }
        } else {
            context.setFillColor(rule)
            context.fill(layout.photo)
        }

        let caption = layout.caption
        switch content.template {
        case .fullBleed:
            let line = [content.dateText, content.placeText].compactMap { $0 }.joined(separator: " · ")
            guard !line.isEmpty else { return }
            context.saveGState()
            // Shadows are measured in the page's own units (points or pixels).
            let unit = abs(context.convertToDeviceSpace(CGSize(width: 1, height: 0)).width)
            context.setShadow(offset: CGSize(width: 0, height: -0.3 * unit), blur: 0.8 * unit, color: CGColor(gray: 0, alpha: 0.45))
            drawText(line, font: serif(11), color: white, in: caption, verticalAlignment: .bottom, context: context)
            context.restoreGState()
        case .border:
            if let place = content.placeText {
                drawText(place, font: serif(10.5), color: ink, in: caption, verticalAlignment: .center, context: context)
            }
            if let date = content.dateText {
                drawText(date, font: serif(10.5), color: muted, in: caption, alignment: .right, verticalAlignment: .center, context: context)
            }
        case .note:
            var top = caption
            if let date = content.dateText {
                let height = drawText(date, font: serif(15), color: ink, in: top, context: context)
                top = CGRect(x: top.minX, y: top.minY + height + 1.5, width: top.width, height: max(0, top.height - height - 1.5))
            }
            if let place = content.placeText {
                drawText(place, font: .systemFont(ofSize: mm(9)), color: muted, in: top, context: context)
            }
            let quote = PostcardText.firstLine(of: content.message)
            if !quote.isEmpty {
                let box = CGRect(x: caption.minX, y: caption.maxY - 13, width: caption.width, height: 13)
                context.setStrokeColor(rule)
                context.setLineWidth(0.25)
                context.move(to: CGPoint(x: box.minX, y: box.minY))
                context.addLine(to: CGPoint(x: box.maxX, y: box.minY))
                context.strokePath()
                drawText(quote, font: hand(9.5), color: ink, in: box.insetBy(dx: 0, dy: 1.5), context: context)
            }
        }
    }

    private static func drawBack(_ content: PostcardContent, in context: CGContext) {
        let layout = PostcardBackLayout(spec: spec)
        context.setStrokeColor(rule)
        context.setLineWidth(0.25)
        context.move(to: CGPoint(x: layout.dividerX, y: layout.dividerTop))
        context.addLine(to: CGPoint(x: layout.dividerX, y: layout.dividerBottom))
        for y in layout.addressLines {
            context.move(to: CGPoint(x: layout.addressMinX, y: y))
            context.addLine(to: CGPoint(x: layout.addressMaxX, y: y))
        }
        context.strokePath()

        context.saveGState()
        context.setLineDash(phase: 0, lengths: [1, 0.8])
        context.stroke(layout.stamp)
        context.restoreGState()
        drawText(content.stampLabel, font: .systemFont(ofSize: mm(7)), color: rule, in: layout.stamp.insetBy(dx: 1, dy: 0), alignment: .center, verticalAlignment: .center, context: context)
        drawText("MOMENTS", font: .systemFont(ofSize: mm(5.5), weight: .medium), color: muted, in: CGRect(x: layout.mark.x, y: layout.mark.y - 3, width: 30, height: 3), kern: 0.4, verticalAlignment: .bottom, context: context)

        drawMessage(content.message, in: layout.message, context: context)
    }

    /// The message on ruled lines; the rules follow the text's lines, and go
    /// on to the bottom so the rest can be written by hand.
    private static func drawMessage(_ message: String, in rect: CGRect, context: CGContext) {
        let fit = messageFit(message, width: rect.width, height: rect.height)
        let pitch = lineHeight(fit.fontSize)
        let font = hand(fit.fontSize)
        var baselines: [CGFloat] = []
        if !message.isEmpty, let frame = messageFrame(message, size: fit.fontSize, width: rect.width, height: rect.height) {
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            context.restoreGState()
            let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
            baselines = origins.map { rect.minY + rect.height - $0.y }
        }
        // The first rule sits under the first line of text, or where it would be.
        var y = baselines.last ?? (rect.minY + pitch + font.descender)
        var rules = baselines.isEmpty ? [y] : baselines
        while y + pitch <= rect.maxY - 1 {
            y += pitch
            rules.append(y)
        }
        context.setStrokeColor(rule)
        context.setLineWidth(0.2)
        for baseline in rules {
            context.move(to: CGPoint(x: rect.minX, y: baseline + 1))
            context.addLine(to: CGPoint(x: rect.maxX, y: baseline + 1))
        }
        context.strokePath()
    }

    /// The size the back's message is set in, and whether it all fits.
    static func messageFit(_ message: String, width: CGFloat? = nil, height: CGFloat? = nil) -> PostcardText.Fit {
        let box = PostcardBackLayout(spec: spec).message
        let width = width ?? box.width
        let height = height ?? box.height
        guard !message.isEmpty else { return PostcardText.Fit(fontSize: PostcardText.largestMessageSize, fitsCompletely: true) }
        return PostcardText.fittingSize { size in
            guard let frame = messageFrame(message, size: size, width: width, height: height) else { return false }
            return CTFrameGetVisibleStringRange(frame).length >= (message as NSString).length
        }
    }

    /// CoreText's own colour key, which takes a CGColor.
    private static let foregroundColor = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

    private static func lineHeight(_ points: Double) -> CGFloat { mm(points) * 1.9 }

    private static func messageFrame(_ message: String, size: Double, width: CGFloat, height: CGFloat) -> CTFrame? {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight(size)
        paragraph.maximumLineHeight = lineHeight(size)
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSAttributedString(string: message, attributes: [
            .font: hand(size),
            foregroundColor: ink,
            .paragraphStyle: paragraph,
        ])
        let setter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        return CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
    }

    // MARK: Helpers

    /// A size in points, as millimetres of the drawing space.
    private static func mm(_ points: Double) -> CGFloat { points / PostcardSpec.pointsPerMillimetre }

    private static func serif(_ points: Double) -> NSFont {
        let base = NSFont.systemFont(ofSize: mm(points))
        if let descriptor = base.fontDescriptor.withDesign(.serif), let font = NSFont(descriptor: descriptor, size: mm(points)) {
            return font
        }
        return base
    }

    /// The message's face: Baskerville, with Songti SC for Chinese. Both
    /// come with macOS. Faces that macOS only downloads on first use (Kaiti
    /// SC, STKaiti) are never asked for by name: asking blocks the caller
    /// until the download ends, which froze the sheet for minutes.
    private static func hand(_ points: Double) -> NSFont {
        let size = mm(points)
        guard installedFamilies.contains("Baskerville"), let base = NSFont(name: "Baskerville", size: size) else {
            return serif(points)
        }
        guard installedFamilies.contains("Songti SC") else { return base }
        let chinese = NSFontDescriptor(fontAttributes: [.family: "Songti SC"])
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [chinese]])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// The font families installed on this Mac, read once.
    private static let installedFamilies = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])

    private static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private enum VerticalAlignment { case top, center, bottom }

    /// One run of text in `rect`, cut off at its edge; returns the height used.
    @discardableResult
    private static func drawText(
        _ string: String,
        font: NSFont,
        color: CGColor,
        in rect: CGRect,
        alignment: NSTextAlignment = .left,
        kern: CGFloat = 0,
        verticalAlignment: VerticalAlignment = .top,
        context: CGContext
    ) -> CGFloat {
        guard !string.isEmpty, rect.width > 0, rect.height > 0 else { return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: string, attributes: [
            .font: font,
            foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: kern,
        ])
        let setter = CTFramesetterCreateWithAttributedString(text)
        let needed = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: rect.width, height: rect.height), nil)
        let height = min(rect.height, ceil(needed.height * 100) / 100)
        let offset: CGFloat
        switch verticalAlignment {
        case .top: offset = 0
        case .center: offset = (rect.height - height) / 2
        case .bottom: offset = rect.height - height
        }
        let box = CGRect(x: rect.minX, y: rect.minY + offset, width: rect.width, height: height)
        context.saveGState()
        context.translateBy(x: box.minX, y: box.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(origin: .zero, size: box.size), transform: nil), nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
        return height
    }
}

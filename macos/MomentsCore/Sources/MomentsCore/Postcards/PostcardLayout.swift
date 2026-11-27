import Foundation

/// Where everything sits on a print-ready postcard, in millimetres.
///
/// Every rectangle is measured from the top-left corner of the whole page,
/// bleed included, with y growing downwards. The app turns millimetres into
/// PDF points or preview pixels; nothing here draws.
public enum PostcardTemplate: String, CaseIterable, Sendable {
    /// The photo fills the card, out to the bleed; date and place over it.
    case fullBleed
    /// The photo inside a paper margin, date and place on the margin below.
    case border
    /// The photo on two thirds of the card, a paper strip with date, place
    /// and the first line of the message on the rest.
    case note
}

public enum PostcardOrientation: Equatable, Sendable {
    case landscape
    case portrait

    /// Taller-than-wide photos make portrait cards; square ones landscape.
    public init(pixelWidth: Int, pixelHeight: Int) {
        self = pixelHeight > pixelWidth ? .portrait : .landscape
    }
}

/// The print format. The defaults follow what online print shops commonly
/// ask for: a 148 × 100 mm card with 3 mm bleed on each side, photos at
/// 300 dpi.
public struct PostcardSpec: Equatable, Sendable {
    public var longSide: Double
    public var shortSide: Double
    public var bleed: Double
    public var dpi: Double
    /// Text and stamp box stay this far inside the trim, clear of the cut.
    public var safeMargin: Double

    public static let standard = PostcardSpec(longSide: 148, shortSide: 100, bleed: 3, dpi: 300, safeMargin: 5)

    public static let pointsPerMillimetre = 72.0 / 25.4

    public init(longSide: Double, shortSide: Double, bleed: Double, dpi: Double, safeMargin: Double) {
        self.longSide = longSide
        self.shortSide = shortSide
        self.bleed = bleed
        self.dpi = dpi
        self.safeMargin = safeMargin
    }

    /// The finished card's size, without bleed.
    public func trimSize(_ orientation: PostcardOrientation) -> CGSize {
        orientation == .landscape
            ? CGSize(width: longSide, height: shortSide)
            : CGSize(width: shortSide, height: longSide)
    }

    /// The whole page as printed, bleed included.
    public func pageSize(_ orientation: PostcardOrientation) -> CGSize {
        let trim = trimSize(orientation)
        return CGSize(width: trim.width + 2 * bleed, height: trim.height + 2 * bleed)
    }

    /// Where the card is cut, on the page.
    public func trimRect(_ orientation: PostcardOrientation) -> CGRect {
        CGRect(origin: CGPoint(x: bleed, y: bleed), size: trimSize(orientation))
    }

    /// Pixels a frame this many millimetres across needs at the print resolution.
    public func pixels(forMillimetres length: Double) -> Int {
        Int((length / 25.4 * dpi).rounded(.up))
    }
}

/// The picture side.
public struct PostcardFrontLayout: Equatable, Sendable {
    /// Where the photo is drawn; reaches into the bleed where it touches an edge.
    public var photo: CGRect
    /// Where date, place and (on the note strip) the message's first line go.
    public var caption: CGRect

    public init(template: PostcardTemplate, orientation: PostcardOrientation, spec: PostcardSpec = .standard) {
        let page = CGRect(origin: .zero, size: spec.pageSize(orientation))
        let trim = spec.trimRect(orientation)
        let safe = trim.insetBy(dx: spec.safeMargin, dy: spec.safeMargin)
        switch template {
        case .fullBleed:
            photo = page
            let height = 9.0
            caption = CGRect(x: safe.minX, y: safe.maxY - height, width: safe.width, height: height)
        case .border:
            let margin = 6.0
            let strip = 14.0
            photo = CGRect(
                x: trim.minX + margin,
                y: trim.minY + margin,
                width: trim.width - 2 * margin,
                height: trim.height - margin - strip
            )
            caption = CGRect(x: photo.minX, y: photo.maxY + 2, width: photo.width, height: safe.maxY - photo.maxY - 2)
        case .note:
            switch orientation {
            case .landscape:
                let split = trim.minX + trim.width * 0.64
                photo = CGRect(x: 0, y: 0, width: split, height: page.height)
                caption = CGRect(x: split + spec.safeMargin, y: safe.minY + 3, width: safe.maxX - split - spec.safeMargin, height: safe.height - 6)
            case .portrait:
                let split = trim.minY + trim.height * 0.68
                photo = CGRect(x: 0, y: 0, width: page.width, height: split)
                caption = CGRect(x: safe.minX, y: split + spec.safeMargin, width: safe.width, height: safe.maxY - split - spec.safeMargin)
            }
        }
    }
}

/// The message side, always laid out landscape: message on the left, stamp
/// box and address lines on the right. On a portrait card the app turns it
/// a quarter turn onto the portrait page.
public struct PostcardBackLayout: Equatable, Sendable {
    public var message: CGRect
    /// The vertical line between message and address.
    public var dividerX: Double
    public var dividerTop: Double
    public var dividerBottom: Double
    public var stamp: CGRect
    /// The y of each address line, between `addressMinX` and `addressMaxX`.
    public var addressLines: [Double]
    public var addressMinX: Double
    public var addressMaxX: Double
    /// Where the small app mark sits, bottom left of the address half.
    public var mark: CGPoint

    public init(spec: PostcardSpec = .standard) {
        let trim = spec.trimRect(.landscape)
        let top = trim.minY + trim.height * 0.10
        let bottom = trim.maxY - trim.height * 0.10
        let left = trim.minX + trim.width * 0.06
        let right = trim.maxX - trim.width * 0.06
        dividerX = trim.minX + trim.width * 0.56
        dividerTop = top
        dividerBottom = bottom
        message = CGRect(x: left, y: top, width: dividerX - 6 - left, height: bottom - top)
        let stampWidth = trim.width * 0.16
        stamp = CGRect(x: right - stampWidth, y: top, width: stampWidth, height: stampWidth * 1.25)
        addressMinX = dividerX + trim.width * 0.05
        addressMaxX = right
        let firstLine = trim.minY + trim.height * 0.52
        addressLines = (0..<3).map { firstLine + Double($0) * 11 }
        mark = CGPoint(x: addressMinX, y: bottom)
    }
}

/// Which part of the photo shows in a frame of another shape.
public enum PostcardCrop {
    /// The part of an image of `imageSize` pixels that fills `frame` (any
    /// unit) without bars. `focus` picks where the visible part sits: 0 is
    /// the left or top edge, 1 the right or bottom, 0.5 the middle. Origin
    /// top left, in pixels.
    public static func sourceRect(imageSize: CGSize, frame: CGSize, focus: CGPoint) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, frame.width > 0, frame.height > 0 else {
            return CGRect(origin: .zero, size: imageSize)
        }
        let frameAspect = frame.width / frame.height
        var width = imageSize.width
        var height = imageSize.height
        if imageSize.width / imageSize.height > frameAspect {
            width = imageSize.height * frameAspect
        } else {
            height = imageSize.width / frameAspect
        }
        let fx = clamp(focus.x)
        let fy = clamp(focus.y)
        return CGRect(
            x: (imageSize.width - width) * fx,
            y: (imageSize.height - height) * fy,
            width: width,
            height: height
        )
    }

    /// The focus after dragging the photo by `translation`, measured in the
    /// same unit as `frame`. Dragging right shows more of the left of the
    /// photo, as when moving a print under a mount. An axis with nothing to
    /// spare keeps its focus.
    public static func focus(
        afterDragging translation: CGSize,
        from start: CGPoint,
        imageSize: CGSize,
        frame: CGSize
    ) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0, frame.width > 0, frame.height > 0 else { return start }
        let scale = max(frame.width / imageSize.width, frame.height / imageSize.height)
        let spareX = imageSize.width * scale - frame.width
        let spareY = imageSize.height * scale - frame.height
        let x = spareX > 0.001 ? clamp(start.x - translation.width / spareX) : start.x
        let y = spareY > 0.001 ? clamp(start.y - translation.height / spareY) : start.y
        return CGPoint(x: x, y: y)
    }

    /// The resolution the visible part prints at, in dots per inch.
    public static func effectiveDPI(source: CGRect, frameMillimetres frame: CGSize) -> Double {
        guard frame.width > 0, frame.height > 0 else { return 0 }
        let across = source.width / (frame.width / 25.4)
        let down = source.height / (frame.height / 25.4)
        return min(across, down)
    }

    /// Below this a photo prints visibly soft, so the sheet says so; it is
    /// half the 300 dpi print shops ask for.
    public static let lowResolutionDPI = 150.0

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }
}

/// The words on the card.
public enum PostcardText {
    public struct Memory: Equatable, Sendable {
        public var text: String
        public var createdAt: Date

        public init(text: String, createdAt: Date) {
            self.text = text
            self.createdAt = createdAt
        }
    }

    /// The message the back starts with: the photo's memories, both people's,
    /// oldest first, a blank line between them; empty ones left out.
    public static func defaultMessage(from memories: [Memory]) -> String {
        memories
            .sorted { ($0.createdAt, $0.text) < ($1.createdAt, $1.text) }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// The first line of the message, for the note strip on the front.
    public static func firstLine(of message: String, maximumLength: Int = 40) -> String {
        let line = message
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard line.count > maximumLength else { return line }
        return String(line.prefix(maximumLength - 1)) + "…"
    }

    public struct Fit: Equatable, Sendable {
        /// In points.
        public var fontSize: Double
        /// False when even the smallest size cuts the end off.
        public var fitsCompletely: Bool
    }

    /// Print shops ask for text no smaller than 8 pt.
    public static let largestMessageSize = 13.0
    public static let smallestMessageSize = 8.0

    /// The largest size, in half points from `largest` down to `smallest`,
    /// at which `fits` says the text fits.
    public static func fittingSize(
        largest: Double = largestMessageSize,
        smallest: Double = smallestMessageSize,
        fits: (Double) -> Bool
    ) -> Fit {
        var size = largest
        while size >= smallest {
            if fits(size) { return Fit(fontSize: size, fitsCompletely: true) }
            size -= 0.5
        }
        return Fit(fontSize: smallest, fitsCompletely: false)
    }
}

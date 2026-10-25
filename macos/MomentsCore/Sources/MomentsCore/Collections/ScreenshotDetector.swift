import Foundation

/// The category of evidence used by ``ScreenshotDetector``.
public enum ScreenshotDetectionReason: String, Equatable, Sendable, CustomStringConvertible {
    case explicitFlag = "explicit-flag"
    case filenameHint = "filename-hint"
    case deviceScreenPixelSize = "device-screen-pixel-size"
    case deviceScreenAspectRatio = "device-screen-aspect-ratio"
    case notDetected = "not-detected"

    public var description: String { rawValue }
}

/// The decision and the evidence behind it for one media item.
public struct ScreenshotDetection: Equatable, Sendable {
    public let isScreenshot: Bool
    public let reason: ScreenshotDetectionReason
    public let explanation: String

    public init(
        isScreenshot: Bool,
        reason: ScreenshotDetectionReason,
        explanation: String
    ) {
        self.isScreenshot = isScreenshot
        self.reason = reason
        self.explanation = explanation
    }

    /// A short, stable string suitable for logs or a UI tooltip.
    public var reasonText: String { "\(reason.rawValue): \(explanation)" }
}

/// Detects phone and tablet screenshots without reading GPS or other personal
/// metadata. The explicit PhotoKit flag always wins over every heuristic.
public struct ScreenshotDetector: Sendable {
    public let aspectRatioTolerance: Double

    /// Common Apple and Android screen pixel dimensions. The aspect-ratio
    /// heuristic covers newer devices whose exact dimensions are not listed.
    public static let knownScreenPixelSizes: Set<ScreenPixelSize> = [
        ScreenPixelSize(width: 640, height: 1_136),
        ScreenPixelSize(width: 640, height: 1_280),
        ScreenPixelSize(width: 720, height: 1_280),
        ScreenPixelSize(width: 720, height: 1_480),
        ScreenPixelSize(width: 750, height: 1_334),
        ScreenPixelSize(width: 828, height: 1_792),
        ScreenPixelSize(width: 1_080, height: 1_920),
        ScreenPixelSize(width: 1_080, height: 2_160),
        ScreenPixelSize(width: 1_080, height: 2_280),
        ScreenPixelSize(width: 1_080, height: 2_340),
        ScreenPixelSize(width: 1_080, height: 2_400),
        ScreenPixelSize(width: 1_125, height: 2_436),
        ScreenPixelSize(width: 1_170, height: 2_532),
        ScreenPixelSize(width: 1_242, height: 2_688),
        ScreenPixelSize(width: 1_280, height: 2_560),
        ScreenPixelSize(width: 1_284, height: 2_778),
        ScreenPixelSize(width: 1_290, height: 2_796),
        ScreenPixelSize(width: 1_440, height: 2_560),
        ScreenPixelSize(width: 1_440, height: 2_960),
        ScreenPixelSize(width: 1_440, height: 3_200),
        ScreenPixelSize(width: 1_536, height: 2_048),
        ScreenPixelSize(width: 1_640, height: 2_360),
        ScreenPixelSize(width: 1_668, height: 2_388),
        ScreenPixelSize(width: 2_048, height: 2_732)
    ]

    /// The short edge values used by common phone and tablet displays.
    private static let knownScreenShortEdges: Set<Int> = [
        640, 720, 750, 828, 1_080, 1_125, 1_170, 1_242, 1_280,
        1_284, 1_290, 1_440, 1_536, 1_640, 1_668, 2_048
    ]

    public init(aspectRatioTolerance: Double = 0.012) {
        self.aspectRatioTolerance = max(0, aspectRatioTolerance)
    }

    public func detect(_ media: MediaDescriptor) -> ScreenshotDetection {
        if let explicitFlag = media.isScreenshotFlag {
            return ScreenshotDetection(
                isScreenshot: explicitFlag,
                reason: .explicitFlag,
                explanation: explicitFlag
                    ? "the media provider marked it as a screenshot"
                    : "the media provider marked it as a non-screenshot"
            )
        }

        if let hint = screenshotFileNameHint(in: media.fileNameHint) {
            return ScreenshotDetection(
                isScreenshot: true,
                reason: .filenameHint,
                explanation: "filename contains \"\(hint)\""
            )
        }

        if isKnownScreenPixelSize(width: media.pixelWidth, height: media.pixelHeight) {
            return ScreenshotDetection(
                isScreenshot: true,
                reason: .deviceScreenPixelSize,
                explanation: "dimensions match a common device screen"
            )
        }

        if isDeviceScreenAspectRatio(width: media.pixelWidth, height: media.pixelHeight) {
            return ScreenshotDetection(
                isScreenshot: true,
                reason: .deviceScreenAspectRatio,
                explanation: "dimensions match a device screen aspect ratio"
            )
        }

        return ScreenshotDetection(
            isScreenshot: false,
            reason: .notDetected,
            explanation: "no screenshot flag, filename hint, or device-screen dimensions matched"
        )
    }

    public func detectAll(_ media: [MediaDescriptor]) -> [ScreenshotDetection] {
        media.map(detect)
    }

    public func isScreenshot(_ media: MediaDescriptor) -> Bool {
        detect(media).isScreenshot
    }

    /// Returns only the media that should be shown in the photo collection.
    public func visibleMedia(from media: [MediaDescriptor]) -> [MediaDescriptor] {
        media.filter { !isScreenshot($0) }
    }

    private func screenshotFileNameHint(in fileName: String?) -> String? {
        guard let fileName else { return nil }
        let normalized = fileName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        let hints = ["screenshot", "screen shot", "screen capture", "截屏", "截图"]
        return hints.first { normalized.contains($0) }
    }

    private func isKnownScreenPixelSize(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let size = ScreenPixelSize(width: width, height: height)
        return Self.knownScreenPixelSizes.contains(size)
            || Self.knownScreenPixelSizes.contains(ScreenPixelSize(width: height, height: width))
    }

    private func isDeviceScreenAspectRatio(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let shortEdge = min(width, height)
        let longEdge = max(width, height)
        guard longEdge >= 1_280, Self.knownScreenShortEdges.contains(shortEdge) else {
            return false
        }

        let ratio = Double(shortEdge) / Double(longEdge)
        let knownRatios = [
            9.0 / 20.0,
            9.0 / 19.5,
            9.0 / 19.0,
            9.0 / 16.0,
            3.0 / 4.0
        ]
        return knownRatios.contains { abs(ratio - $0) <= aspectRatioTolerance }
    }
}

public struct ScreenPixelSize: Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

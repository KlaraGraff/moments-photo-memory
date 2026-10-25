import Foundation

/// The metadata needed by the collection pipeline.
///
/// The descriptor deliberately contains no file URL or photo-library object. It
/// can therefore be built from synthetic fixtures in tests and from PhotoKit
/// in the application layer without making this package depend on PhotoKit.
public struct MediaDescriptor: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let captureDate: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isScreenshotFlag: Bool?
    public let fileNameHint: String?
    public let featurePrint: [Float]?

    public init(
        id: String,
        captureDate: Date? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        isScreenshotFlag: Bool? = nil,
        fileNameHint: String? = nil,
        featurePrint: [Float]? = nil
    ) {
        self.id = id
        self.captureDate = captureDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isScreenshotFlag = isScreenshotFlag
        self.fileNameHint = fileNameHint
        self.featurePrint = featurePrint
    }

    /// The number of pixels, used as a deterministic sharpness proxy.
    public var pixelCount: Int64 {
        Int64(max(0, pixelWidth)) * Int64(max(0, pixelHeight))
    }
}

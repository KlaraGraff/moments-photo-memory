import CoreGraphics
import XCTest
@testable import Moments

final class ReviewNoiseClassifierTests: XCTestCase {
    func testHighlyConfidentDocumentIsNoise() {
        let observations: [(identifier: String, confidence: Float)] = [
            (identifier: "document", confidence: 0.9)
        ]

        XCTAssertTrue(ReviewNoiseClassifier.isNoise(observations: observations))
    }

    func testDocumentWithPeopleStaysInReview() {
        let observations: [(identifier: String, confidence: Float)] = [
            (identifier: "document", confidence: 0.9),
            (identifier: "people", confidence: 0.5)
        ]

        XCTAssertFalse(ReviewNoiseClassifier.isNoise(observations: observations))
    }

    func testUnsureIllustrationStaysInReview() {
        let observations: [(identifier: String, confidence: Float)] = [
            (identifier: "illustrations", confidence: 0.7)
        ]

        XCTAssertFalse(ReviewNoiseClassifier.isNoise(observations: observations))
    }

    func testNoObservationsStaysInReview() {
        let observations: [(identifier: String, confidence: Float)] = []

        XCTAssertFalse(ReviewNoiseClassifier.isNoise(observations: observations))
    }

    func testLowConfidencePhotoLabelDoesNotKeepTheItem() {
        let observations: [(identifier: String, confidence: Float)] = [
            (identifier: "document", confidence: 0.9),
            (identifier: "outdoor", confidence: 0.2)
        ]

        XCTAssertTrue(ReviewNoiseClassifier.isNoise(observations: observations))
    }

    func testConfidentOutdoorSceneIsNoise() {
        let observations: [(identifier: String, confidence: Float)] = [
            (identifier: "screenshot", confidence: 0.95),
            (identifier: "outdoor", confidence: 0.3)
        ]

        XCTAssertFalse(ReviewNoiseClassifier.isNoise(observations: observations))
    }

    func testCacheRoundTripsThroughJSON() throws {
        let directory: URL = FileManager.default.temporaryDirectory
            .appending(path: "ReviewNoiseClassifierTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL: URL = directory.appending(path: "review-noise.json")

        let cache = ReviewNoiseCache(fileURL: fileURL)
        cache.record(true, for: "synthetic-document")
        cache.record(false, for: "synthetic-photo")
        try cache.save()

        let reloaded = ReviewNoiseCache(fileURL: fileURL)
        XCTAssertTrue(reloaded.isNoise("synthetic-document"))
        XCTAssertFalse(reloaded.isNoise("synthetic-photo"))
        XCTAssertTrue(reloaded.hasValue(for: "synthetic-photo"))
        XCTAssertFalse(reloaded.hasValue(for: "synthetic-unknown"))
    }

    /// Synthetic only: a white page with black text lines and a colour
    /// gradient, rendered here in code. Records what Vision says, so the
    /// confidence choice can be seen on the runner; never fails on the guess.
    func testSyntheticPageAndGradientClassification() throws {
        let page: CGImage = try XCTUnwrap(SyntheticReviewImage.textPage())
        let gradient: CGImage = try XCTUnwrap(SyntheticReviewImage.gradient())
        let pageObservations: [(identifier: String, confidence: Float)] = ReviewNoiseClassifier.observations(for: page)
        let gradientObservations: [(identifier: String, confidence: Float)] = ReviewNoiseClassifier.observations(for: gradient)

        let pageTop: [(String, Float)] = pageObservations
            .sorted { (first: (identifier: String, confidence: Float), second: (identifier: String, confidence: Float)) -> Bool in
                first.confidence > second.confidence
            }
            .prefix(5)
            .map { (observation: (identifier: String, confidence: Float)) -> (String, Float) in
                (observation.identifier, observation.confidence)
            }
        let gradientTop: [(String, Float)] = gradientObservations
            .sorted { (first: (identifier: String, confidence: Float), second: (identifier: String, confidence: Float)) -> Bool in
                first.confidence > second.confidence
            }
            .prefix(5)
            .map { (observation: (identifier: String, confidence: Float)) -> (String, Float) in
                (observation.identifier, observation.confidence)
            }
        print("REVIEW-NOISE synthetic page top: \(pageTop)")
        print("REVIEW-NOISE synthetic gradient top: \(gradientTop)")
        let pageIsNoise: Bool = ReviewNoiseClassifier.isNoise(observations: pageObservations)
        let gradientIsNoise: Bool = ReviewNoiseClassifier.isNoise(observations: gradientObservations)
        print("REVIEW-NOISE page isNoise=\(pageIsNoise)")
        print("REVIEW-NOISE gradient isNoise=\(gradientIsNoise)")
        // Vision is only recorded here, never asserted: a runner without the
        // classifier model should not fail this suite.
        try XCTSkipIf(pageObservations.isEmpty || gradientObservations.isEmpty, "Vision returned no classifications in this environment")
    }
}

enum SyntheticReviewImage {
    /// A white page with black text lines, like a photographed document.
    static func textPage() -> CGImage? {
        let width = 800
        let height = 1_000
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        var y = height - 120
        var lineIndex = 0
        while y > 100 {
            let fullWidth = lineIndex % 7 != 6
            let lineWidth = fullWidth ? width - 160 : (width - 160) / 2
            context.fill(CGRect(x: 80, y: y, width: lineWidth, height: 18))
            y -= 46
            lineIndex += 1
        }
        return context.makeImage()
    }

    /// A smooth two-stop gradient, unlike any document.
    static func gradient() -> CGImage? {
        let width = 800
        let height = 800
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let start = CGColor(colorSpace: colorSpace, components: [0.9, 0.5, 0.2, 1]),
              let end = CGColor(colorSpace: colorSpace, components: [0.1, 0.3, 0.7, 1]),
              let gradient = CGGradient(colorsSpace: colorSpace, colors: [start, end] as CFArray, locations: [0, 1]) else {
            return nil
        }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: width, y: height),
            options: []
        )
        return context.makeImage()
    }
}

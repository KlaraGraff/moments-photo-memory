import Foundation
import XCTest
@testable import MomentsCore

final class ScreenshotDetectorEdgeCaseTests: XCTestCase {
    func testTheExplicitFlagBeatsFilenameAndSizeHeuristics() {
        let detector = ScreenshotDetector()
        let forcedPhoto = detector.detect(MediaDescriptor(
            id: "forced-photo",
            pixelWidth: 1_170,
            pixelHeight: 2_532,
            isScreenshotFlag: false,
            fileNameHint: "Screenshot 1.png"
        ))
        let forcedScreenshot = detector.detect(MediaDescriptor(
            id: "forced-screenshot",
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            isScreenshotFlag: true
        ))

        XCTAssertFalse(forcedPhoto.isScreenshot)
        XCTAssertEqual(forcedPhoto.reason, .explicitFlag)
        XCTAssertEqual(forcedPhoto.explanation, "the media provider marked it as a non-screenshot")
        XCTAssertTrue(forcedScreenshot.isScreenshot)
        XCTAssertEqual(forcedScreenshot.reason, .explicitFlag)
        XCTAssertEqual(forcedScreenshot.explanation, "the media provider marked it as a screenshot")
    }

    func testFilenameHintsAreCaseAndSeparatorInsensitive() {
        let detector = ScreenshotDetector()
        let hints = [
            "Screen_Shot_2024.png",
            "SCREENSHOT.PNG",
            "screen-capture.jpg",
            "截屏2024.png",
            "截图.jpg"
        ]

        for hint in hints {
            let detection = detector.detect(MediaDescriptor(id: hint, pixelWidth: 4_032, pixelHeight: 3_024, fileNameHint: hint))
            XCTAssertTrue(detection.isScreenshot, hint)
            XCTAssertEqual(detection.reason, .filenameHint, hint)
        }

        let ordinary = detector.detect(MediaDescriptor(id: "ordinary", pixelWidth: 4_032, pixelHeight: 3_024, fileNameHint: "IMG_0001.HEIC"))
        XCTAssertFalse(ordinary.isScreenshot)
        XCTAssertEqual(ordinary.reason, .notDetected)
    }

    func testAKnownDeviceSizeIsDetectedInBothOrientations() {
        let detector = ScreenshotDetector()
        let portrait = detector.detect(MediaDescriptor(id: "portrait", pixelWidth: 1_170, pixelHeight: 2_532))
        let landscape = detector.detect(MediaDescriptor(id: "landscape", pixelWidth: 2_532, pixelHeight: 1_170))

        XCTAssertTrue(portrait.isScreenshot)
        XCTAssertEqual(portrait.reason, .deviceScreenPixelSize)
        XCTAssertTrue(landscape.isScreenshot)
        XCTAssertEqual(landscape.reason, .deviceScreenPixelSize)
    }

    func testTheAspectRatioRuleCoversUnlistedScreenSizesButNotCameraPhotos() {
        XCTAssertFalse(ScreenshotDetector.knownScreenPixelSizes.contains(ScreenPixelSize(width: 1_440, height: 1_920)))

        let detector = ScreenshotDetector()
        let tablet = detector.detect(MediaDescriptor(id: "tablet", pixelWidth: 1_440, pixelHeight: 1_920))
        let camera = detector.detect(MediaDescriptor(id: "camera", pixelWidth: 4_032, pixelHeight: 3_024))
        let empty = detector.detect(MediaDescriptor(id: "empty", pixelWidth: 0, pixelHeight: 0))

        XCTAssertTrue(tablet.isScreenshot)
        XCTAssertEqual(tablet.reason, .deviceScreenAspectRatio)
        XCTAssertFalse(camera.isScreenshot)
        XCTAssertEqual(camera.reason, .notDetected)
        XCTAssertFalse(empty.isScreenshot)
        XCTAssertEqual(empty.reason, .notDetected)
    }

    func testDetectAllKeepsInputOrderAndReasonTextJoinsReasonAndExplanation() {
        let detector = ScreenshotDetector()
        let media = [
            MediaDescriptor(id: "explicit", pixelWidth: 4_032, pixelHeight: 3_024, isScreenshotFlag: true),
            MediaDescriptor(id: "named", pixelWidth: 4_032, pixelHeight: 3_024, fileNameHint: "Screenshot 1.png"),
            MediaDescriptor(id: "sized", pixelWidth: 1_170, pixelHeight: 2_532),
            MediaDescriptor(id: "ratio", pixelWidth: 1_440, pixelHeight: 1_920),
            MediaDescriptor(id: "ordinary", pixelWidth: 4_032, pixelHeight: 3_024, fileNameHint: "IMG_0001.HEIC")
        ]

        let detections = detector.detectAll(media)

        XCTAssertEqual(detections.count, media.count)
        XCTAssertEqual(detections.map(\.reason), [
            .explicitFlag,
            .filenameHint,
            .deviceScreenPixelSize,
            .deviceScreenAspectRatio,
            .notDetected
        ])
        XCTAssertEqual(detections.map(\.isScreenshot), [true, true, true, true, false])
        for detection in detections {
            XCTAssertEqual(detection.reasonText, "\(detection.reason.rawValue): \(detection.explanation)")
        }
        XCTAssertEqual(detections[0].reasonText, "explicit-flag: the media provider marked it as a screenshot")
    }
}

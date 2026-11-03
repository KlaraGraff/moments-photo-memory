import XCTest
@testable import Moments

/// Synthetic file names only; no real photo names or paths.
final class ScreenshotFileNameTests: XCTestCase {
    private static let screenshotNames: [String] = [
        "Screenshot 2024-05-01 at 10.12.33.png",
        "Screenshot.png",
        "screenshot_2024.png",
        "Screenshot_2024.05.01.png",
        "Screen Shot 2024-05-01 at 10.12.33.png",
        "screen shot 1.png",
        "截屏2024-05-01 10.12.33.png",
        "屏幕快照 2024-05-01 10.12.33.png",
        "屏幕截图 2024-05-01 10.12.33.png",
        "Bildschirmfoto 2024-05-01 um 10.12.33.png",
        "bildschirmfoto.png",
        "Simulator Screenshot - iPhone 15 - 2024-05-01 at 10.12.33.png",
        "simulator screenshot 1.png",
        "Screenshot_2024-05-01-10-12-33-123_com.example.app.jpg",
        "微信截图_20240501101233.png"
    ]

    private static let ordinaryNames: [String] = [
        "IMG_1234.JPG",
        "IMG_0001.HEIC",
        "mmexport123.jpg",
        "wx_camera_1.jpg",
        "photo.png",
        "DSC_0042.NEF",
        "",
        "   "
    ]

    func testScreenshotFileNamesAreRecognised() {
        for name: String in Self.screenshotNames {
            XCTAssertTrue(ScreenshotFileName.looksLikeScreenshot(name), "expected screenshot name: \(name)")
        }
    }

    func testOrdinaryPhotoFileNamesAreNotScreenshots() {
        for name: String in Self.ordinaryNames {
            XCTAssertFalse(ScreenshotFileName.looksLikeScreenshot(name), "expected ordinary name: \(name)")
        }
    }

    /// A screenshot stays in the library but never asks for import review.
    func testScreenshotWithPendingReasonNeedsNoImportReview() {
        let screenshot = MediaItem(
            id: "synthetic-screenshot",
            isScreenshot: true,
            importReviewReasonsRaw: ImportReviewReason.missingLocation.rawValue,
            reviewDecisionRaw: ImportReviewDecision.pending.rawValue
        )
        XCTAssertFalse(screenshot.importReviewReasons.isEmpty)
        XCTAssertFalse(screenshot.needsImportReview)

        let photo = MediaItem(
            id: "synthetic-photo",
            isScreenshot: false,
            importReviewReasonsRaw: ImportReviewReason.missingLocation.rawValue,
            reviewDecisionRaw: ImportReviewDecision.pending.rawValue
        )
        XCTAssertTrue(photo.needsImportReview)
    }
}

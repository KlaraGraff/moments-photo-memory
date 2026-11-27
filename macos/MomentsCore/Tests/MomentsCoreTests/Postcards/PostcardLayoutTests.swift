import Foundation
import XCTest
@testable import MomentsCore

final class PostcardLayoutTests: XCTestCase {
    private let spec = PostcardSpec.standard

    func testTheStandardCardIs148By100WithThreeMillimetresOfBleed() {
        XCTAssertEqual(spec.trimSize(.landscape), CGSize(width: 148, height: 100))
        XCTAssertEqual(spec.pageSize(.landscape), CGSize(width: 154, height: 106))
        XCTAssertEqual(spec.pageSize(.portrait), CGSize(width: 106, height: 154))
        XCTAssertEqual(spec.trimRect(.portrait), CGRect(x: 3, y: 3, width: 100, height: 148))
        // 154 mm at 300 dpi.
        XCTAssertEqual(spec.pixels(forMillimetres: 154), 1819)
    }

    func testTallPhotosMakePortraitCardsAndSquareOnesLandscape() {
        XCTAssertEqual(PostcardOrientation(pixelWidth: 3000, pixelHeight: 4000), .portrait)
        XCTAssertEqual(PostcardOrientation(pixelWidth: 4000, pixelHeight: 3000), .landscape)
        XCTAssertEqual(PostcardOrientation(pixelWidth: 2000, pixelHeight: 2000), .landscape)
    }

    func testEveryTemplateKeepsItsTextInsideTheSafeAreaAndOffThePhoto() {
        for orientation in [PostcardOrientation.landscape, .portrait] {
            let safe = spec.trimRect(orientation).insetBy(dx: spec.safeMargin, dy: spec.safeMargin)
            for template in PostcardTemplate.allCases {
                let layout = PostcardFrontLayout(template: template, orientation: orientation)
                XCTAssertTrue(safe.contains(layout.caption), "\(template) \(orientation): caption crosses the safe margin")
                XCTAssertGreaterThan(layout.caption.width, 0)
                XCTAssertGreaterThan(layout.caption.height, 0)
                let page = CGRect(origin: .zero, size: spec.pageSize(orientation))
                XCTAssertTrue(page.contains(layout.photo), "\(template) \(orientation): photo leaves the page")
                if template != .fullBleed {
                    XCTAssertFalse(layout.photo.intersects(layout.caption), "\(template) \(orientation): text over the photo")
                }
            }
        }
    }

    func testFullBleedAndNotePhotosReachIntoTheBleed() {
        let full = PostcardFrontLayout(template: .fullBleed, orientation: .landscape)
        XCTAssertEqual(full.photo, CGRect(x: 0, y: 0, width: 154, height: 106))
        let note = PostcardFrontLayout(template: .note, orientation: .landscape)
        XCTAssertEqual(note.photo.minX, 0)
        XCTAssertEqual(note.photo.height, 106)
        let border = PostcardFrontLayout(template: .border, orientation: .landscape)
        XCTAssertTrue(spec.trimRect(.landscape).contains(border.photo))
    }

    func testTheBackKeepsMessageStampAndAddressApartAndInsideTheCard() {
        let back = PostcardBackLayout()
        let safe = spec.trimRect(.landscape).insetBy(dx: spec.safeMargin, dy: spec.safeMargin)
        XCTAssertTrue(safe.contains(back.message))
        XCTAssertTrue(safe.contains(back.stamp))
        XCTAssertLessThan(back.message.maxX, back.dividerX)
        XCTAssertGreaterThan(back.stamp.minX, back.dividerX)
        XCTAssertEqual(back.addressLines.count, 3)
        XCTAssertGreaterThan(back.addressLines[0], back.stamp.maxY)
        XCTAssertLessThan(back.addressLines[2], back.dividerBottom)
    }

    func testAWidePhotoInATallerFrameIsCroppedAtTheSides() {
        let source = PostcardCrop.sourceRect(
            imageSize: CGSize(width: 4000, height: 2000),
            frame: CGSize(width: 150, height: 100),
            focus: CGPoint(x: 0.5, y: 0.5)
        )
        XCTAssertEqual(source, CGRect(x: 500, y: 0, width: 3000, height: 2000))
        let left = PostcardCrop.sourceRect(
            imageSize: CGSize(width: 4000, height: 2000),
            frame: CGSize(width: 150, height: 100),
            focus: CGPoint(x: 0, y: 0.5)
        )
        XCTAssertEqual(left.minX, 0)
        let outOfRange = PostcardCrop.sourceRect(
            imageSize: CGSize(width: 4000, height: 2000),
            frame: CGSize(width: 150, height: 100),
            focus: CGPoint(x: 3, y: -1)
        )
        XCTAssertEqual(outOfRange.maxX, 4000)
    }

    func testATallPhotoInAWideFrameIsCroppedAtTopAndBottom() {
        let source = PostcardCrop.sourceRect(
            imageSize: CGSize(width: 3000, height: 4000),
            frame: CGSize(width: 148, height: 100),
            focus: CGPoint(x: 0.5, y: 1)
        )
        XCTAssertEqual(source.width, 3000, accuracy: 0.001)
        XCTAssertEqual(source.height, 3000 * 100 / 148, accuracy: 0.001)
        XCTAssertEqual(source.maxY, 4000, accuracy: 0.001)
    }

    func testDraggingMovesTheCropOnlyWhereThereIsPhotoToSpare() {
        // 4000 × 2000 into 150 × 100: drawn 200 wide, 50 to spare across, none down.
        let image = CGSize(width: 4000, height: 2000)
        let frame = CGSize(width: 150, height: 100)
        let start = CGPoint(x: 0.5, y: 0.5)
        let right = PostcardCrop.focus(afterDragging: CGSize(width: 25, height: 40), from: start, imageSize: image, frame: frame)
        XCTAssertEqual(right.x, 0, accuracy: 0.0001)
        XCTAssertEqual(right.y, 0.5)
        let far = PostcardCrop.focus(afterDragging: CGSize(width: -500, height: 0), from: start, imageSize: image, frame: frame)
        XCTAssertEqual(far.x, 1)
    }

    func testResolutionIsMeasuredOnTheVisiblePart() {
        // 1819 pixels across 154 mm is 300 dpi.
        let dpi = PostcardCrop.effectiveDPI(
            source: CGRect(x: 0, y: 0, width: 1819, height: 1252),
            frameMillimetres: CGSize(width: 154, height: 106)
        )
        XCTAssertEqual(dpi, 300, accuracy: 1)
        let small = PostcardCrop.effectiveDPI(
            source: CGRect(x: 0, y: 0, width: 900, height: 600),
            frameMillimetres: CGSize(width: 154, height: 106)
        )
        XCTAssertLessThan(small, PostcardCrop.lowResolutionDPI)
    }

    func testTheMessageStartsFromTheMemoriesOldestFirst() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let memories = [
            PostcardText.Memory(text: "  Next time, the sunset.  ", createdAt: base.addingTimeInterval(60)),
            PostcardText.Memory(text: "Windy on the pier.", createdAt: base),
            PostcardText.Memory(text: " \n ", createdAt: base.addingTimeInterval(30)),
        ]
        XCTAssertEqual(PostcardText.defaultMessage(from: memories), "Windy on the pier.\n\nNext time, the sunset.")
        XCTAssertEqual(PostcardText.defaultMessage(from: []), "")
    }

    func testTheNoteStripShowsTheFirstLineShortened() {
        XCTAssertEqual(PostcardText.firstLine(of: "\n  First line  \nSecond"), "First line")
        XCTAssertEqual(PostcardText.firstLine(of: String(repeating: "a", count: 50), maximumLength: 10), "aaaaaaaaa…")
        XCTAssertEqual(PostcardText.firstLine(of: ""), "")
    }

    func testLongTextShrinksInHalfPointsButNeverBelowEightPoints() {
        let fit = PostcardText.fittingSize { $0 <= 10.2 }
        XCTAssertEqual(fit, PostcardText.Fit(fontSize: 10, fitsCompletely: true))
        XCTAssertEqual(PostcardText.fittingSize { _ in true }.fontSize, 13)
        XCTAssertEqual(PostcardText.fittingSize { _ in false }, PostcardText.Fit(fontSize: 8, fitsCompletely: false))
    }
}

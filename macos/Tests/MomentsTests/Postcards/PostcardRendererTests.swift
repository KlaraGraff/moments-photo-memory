import AppKit
import CoreGraphics
import MomentsCore
import PDFKit
import XCTest
@testable import Moments

/// The postcard PDF is what a print shop receives: two pages of the card
/// plus bleed, with trim and bleed boxes, the photo in CMYK at no more than
/// 300 dpi, and nothing of the original file but its pixels.
final class PostcardRendererTests: XCTestCase {
    private let millimetre = PostcardSpec.pointsPerMillimetre

    func testALandscapePhotoMakesTwoLandscapePagesWithBleedAndTrimBoxes() throws {
        let pdf = try document(PostcardContent(message: "Windy on the pier."), image: syntheticPhoto(width: 2000, height: 1333))
        XCTAssertEqual(pdf.numberOfPages, 2)
        for number in 1...2 {
            let page = try XCTUnwrap(pdf.page(at: number))
            let media = page.getBoxRect(.mediaBox)
            XCTAssertEqual(media.width, 154 * millimetre, accuracy: 0.01)
            XCTAssertEqual(media.height, 106 * millimetre, accuracy: 0.01)
            let trim = page.getBoxRect(.trimBox)
            XCTAssertEqual(trim.width, 148 * millimetre, accuracy: 0.01)
            XCTAssertEqual(trim.height, 100 * millimetre, accuracy: 0.01)
            XCTAssertEqual(trim.minX, 3 * millimetre, accuracy: 0.01)
            XCTAssertEqual(page.getBoxRect(.bleedBox), media)
        }
    }

    func testATallPhotoMakesPortraitPages() throws {
        var content = PostcardContent()
        content.orientation = .portrait
        let pdf = try document(content, image: syntheticPhoto(width: 1200, height: 1800))
        let media = try XCTUnwrap(pdf.page(at: 2)).getBoxRect(.mediaBox)
        XCTAssertEqual(media.width, 106 * millimetre, accuracy: 0.01)
        XCTAssertEqual(media.height, 154 * millimetre, accuracy: 0.01)
    }

    func testThePrintedPhotoIsCMYKAndNoLargerThan300Dpi() {
        let image = syntheticPhoto(width: 6000, height: 4000)
        for template in PostcardTemplate.allCases {
            let content = PostcardContent(template: template)
            let printed = PostcardRenderer.preparedPhoto(content, image: image)
            XCTAssertEqual(printed.colorSpace?.model, .cmyk, "\(template)")
            let frame = PostcardFrontLayout(template: template, orientation: .landscape).photo
            XCTAssertLessThanOrEqual(printed.width, PostcardSpec.standard.pixels(forMillimetres: frame.width))
            XCTAssertLessThanOrEqual(printed.height, PostcardSpec.standard.pixels(forMillimetres: frame.height))
            // The frame's shape, so nothing is stretched.
            XCTAssertEqual(Double(printed.width) / Double(printed.height), frame.width / frame.height, accuracy: 0.01)
        }
    }

    func testASmallPhotoIsNotScaledUp() {
        let printed = PostcardRenderer.preparedPhoto(PostcardContent(), image: syntheticPhoto(width: 900, height: 600))
        XCTAssertLessThanOrEqual(printed.width, 900)
    }

    func testTheMessageShrinksBeforeItIsCutOff() {
        let short = PostcardRenderer.messageFit("Windy on the pier.")
        XCTAssertEqual(short.fontSize, PostcardText.largestMessageSize)
        XCTAssertTrue(short.fitsCompletely)
        let long = PostcardRenderer.messageFit(String(repeating: "We walked along the harbour wall until the light went. ", count: 6))
        XCTAssertLessThan(long.fontSize, PostcardText.largestMessageSize)
        let tooLong = PostcardRenderer.messageFit(String(repeating: "We walked along the harbour wall until the light went. ", count: 60))
        XCTAssertFalse(tooLong.fitsCompletely)
        XCTAssertEqual(tooLong.fontSize, PostcardText.smallestMessageSize)
    }

    func testThePreviewShowsTheWholePageWithItsBleed() throws {
        for side in [PostcardSide.front, .back] {
            let preview = try XCTUnwrap(PostcardRenderer.previewImage(side, PostcardContent(), image: syntheticPhoto(width: 2000, height: 1333), pixelWidth: 770))
            XCTAssertEqual(preview.width, 770)
            XCTAssertEqual(preview.height, 530)
        }
    }

    func testTheMessageIsRealTextOnTheSecondPage() throws {
        let content = PostcardContent(message: "Synthetic harbour note")
        let data = try XCTUnwrap(PostcardRenderer.pdfData(content, image: syntheticPhoto(width: 2000, height: 1333)))
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertTrue(pdf.page(at: 1)?.string?.contains("Synthetic harbour note") == true)
        XCTAssertFalse(pdf.page(at: 0)?.string?.contains("Synthetic harbour note") == true)
    }

    // MARK: Helpers

    private func document(_ content: PostcardContent, image: CGImage) throws -> CGPDFDocument {
        let data = try XCTUnwrap(PostcardRenderer.pdfData(content, image: image))
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGPDFDocument(provider))
    }

    /// A gradient, standing in for a photo.
    private func syntheticPhoto(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [CGColor(srgbRed: 0.95, green: 0.72, blue: 0.56, alpha: 1), CGColor(srgbRed: 0.25, green: 0.44, blue: 0.51, alpha: 1)] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        return context.makeImage()!
    }
}

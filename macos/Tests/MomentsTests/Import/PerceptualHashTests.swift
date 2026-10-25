import CoreGraphics
import Foundation
import XCTest
@testable import Moments

final class PerceptualHashTests: XCTestCase {
    func testDHashIsStableForSameImageAndScaledCopy() throws {
        let image = syntheticGradient(reverse: false)
        let scaled = scaledCopy(of: image)
        let hash = try XCTUnwrap(PerceptualHash.dHash(image))

        XCTAssertEqual(PerceptualHash.dHash(image), hash)
        XCTAssertEqual(PerceptualHash.dHash(scaled), hash)
        XCTAssertEqual(hash.count, 16)
        XCTAssertEqual(hash, hash.lowercased())
    }

    func testDHashDiffersForDifferentImage() throws {
        let first = try XCTUnwrap(PerceptualHash.dHash(syntheticGradient(reverse: false)))
        let second = try XCTUnwrap(PerceptualHash.dHash(syntheticGradient(reverse: true)))

        XCTAssertNotEqual(first, second)
        XCTAssertGreaterThan(try XCTUnwrap(PerceptualHash.hammingDistance(first, second)), 10)
    }

    func testDHashPinsRowAndBitOrderForVerticalStripes() throws {
        XCTAssertEqual(try XCTUnwrap(PerceptualHash.dHash(syntheticVerticalStripes())), "5555555555555555")
    }

    private func syntheticGradient(reverse: Bool) -> CGImage {
        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8((x * 255) / (width - 1))
                pixels[y * width + x] = reverse ? 255 - value : value
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private func scaledCopy(of image: CGImage) -> CGImage {
        let context = CGContext(
            data: nil,
            width: 128,
            height: 128,
            bitsPerComponent: 8,
            bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        return context.makeImage()!
    }

    private func syntheticVerticalStripes() -> CGImage {
        let width = 9
        let height = 8
        let pixels = (0..<(width * height)).map { index in
            index % width % 2 == 0 ? UInt8(0) : UInt8(255)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}

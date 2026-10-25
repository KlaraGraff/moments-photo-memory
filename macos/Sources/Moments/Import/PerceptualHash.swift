import CoreGraphics
import Foundation

public enum PerceptualHash {
    private static let width = 9
    private static let height = 8

    /// Computes the classic 64-bit difference hash from a small grayscale image.
    public static func dHash(_ image: CGImage) -> String? {
        guard image.width > 0, image.height > 0 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) ?? CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)

        var hash: UInt64 = 0
        for row in 0..<height {
            let offset = row * width
            for column in 0..<(width - 1) {
                hash <<= 1
                if pixels[offset + column] > pixels[offset + column + 1] {
                    hash |= 1
                }
            }
        }
        return String(format: "%016llx", hash)
    }

    public static func hammingDistance(_ lhs: String, _ rhs: String) -> Int? {
        guard lhs.count == 16, rhs.count == 16,
              let left = UInt64(lhs, radix: 16),
              let right = UInt64(rhs, radix: 16) else { return nil }
        return (left ^ right).nonzeroBitCount
    }
}

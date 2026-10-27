// Writes a synthetic photo folder for import checks: JPEGs with EXIF capture
// dates, time-zone offsets and GPS near 0,0, plus the edge cases the importer
// flags, and one short video for the viewer's player. Everything is
// generated; no real photos, places or people.
//
// Usage: swift scripts/make_synthetic_import_fixtures.swift <output-folder>
// The output folder must be outside the repository.
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Fixture {
    let name: String
    let date: String?          // EXIF "yyyy:MM:dd HH:mm:ss", nil = no EXIF date
    let offset: String?        // EXIF OffsetTimeOriginal, e.g. "+02:00"
    let gps: (Double, Double)? // latitude, longitude
    let shade: Double
    var size = (width: 320, height: 240)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift scripts/make_synthetic_import_fixtures.swift <output-folder>\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
// Resolve symlinks of the deepest existing ancestor and compare without case,
// since macOS volumes are usually case-insensitive.
func resolvedPath(_ url: URL) -> String {
    var existing = url
    var rest: [String] = []
    while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
        rest.insert(existing.lastPathComponent, at: 0)
        existing.deleteLastPathComponent()
    }
    var resolved = existing.resolvingSymlinksInPath()
    for component in rest { resolved.appendPathComponent(component) }
    return resolved.path.lowercased()
}
let outputPath = resolvedPath(output)
let repoPath = resolvedPath(repoRoot)
guard !outputPath.hasPrefix(repoPath + "/"), outputPath != repoPath else {
    FileHandle.standardError.write("Refusing to write fixtures inside the repository.\n".data(using: .utf8)!)
    exit(2)
}

var fixtures: [Fixture] = []
// Trip A: three days, two spots about 1 km apart, one time zone.
for day in 0..<3 {
    for shot in 0..<4 {
        let lat = 0.010 + Double(shot % 2) * 0.009
        let lon = 0.020 + Double(day) * 0.002
        fixtures.append(Fixture(
            name: "trip-a-day\(day + 1)-\(shot + 1)",
            date: String(format: "2025:05:%02d %02d:%02d:00", 10 + day, 9 + shot * 2, shot * 7),
            offset: "+02:00",
            gps: (lat, lon),
            shade: Double(day * 4 + shot) / 24
        ))
    }
}
// A GPS jump in the middle of trip A (about 200 km away for 10 minutes).
fixtures.append(Fixture(name: "trip-a-gps-jump", date: "2025:05:11 12:05:00", offset: "+02:00", gps: (1.8, 0.02), shade: 0.51))
// Trip A without location.
fixtures.append(Fixture(name: "trip-a-no-gps", date: "2025:05:11 18:30:00", offset: "+02:00", gps: nil, shade: 0.55))
// Trip A without a time-zone offset (time zone unknown).
fixtures.append(Fixture(name: "trip-a-no-offset", date: "2025:05:12 08:15:00", offset: nil, gps: (0.011, 0.024), shade: 0.58))
// Near-duplicate: same scene as trip-a-day1-1, smaller size.
fixtures.append(Fixture(name: "trip-a-day1-1-small-copy", date: "2025:05:10 09:00:00", offset: "+02:00", gps: (0.010, 0.020), shade: 0, size: (160, 120)))
// Trip B: ten days later, another area, another time zone.
for shot in 0..<5 {
    fixtures.append(Fixture(
        name: "trip-b-\(shot + 1)",
        date: String(format: "2025:05:%02d %02d:30:00", 22 + shot / 3, 10 + shot),
        offset: "-03:00",
        gps: (-0.30 + Double(shot) * 0.001, 0.40),
        shade: 0.6 + Double(shot) / 20
    ))
}
// No EXIF at all: the importer falls back to the file date.
for shot in 0..<3 {
    fixtures.append(Fixture(name: "no-exif-\(shot + 1)", date: nil, offset: nil, gps: nil, shade: 0.9 + Double(shot) / 40))
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func image(shade: Double, width: Int, height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: shade, green: 0.55, blue: 1 - shade, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // A simple shape so each scene has structure for perceptual hashing.
    context.setFillColor(CGColor(red: 1 - shade, green: 0.3, blue: shade, alpha: 1))
    context.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
    return context.makeImage()!
}

for fixture in fixtures {
    var properties: [CFString: Any] = [:]
    if let date = fixture.date {
        var exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: date, kCGImagePropertyExifDateTimeDigitized: date]
        if let offset = fixture.offset {
            exif[kCGImagePropertyExifOffsetTimeOriginal] = offset
            exif[kCGImagePropertyExifOffsetTimeDigitized] = offset
        }
        properties[kCGImagePropertyExifDictionary] = exif
    }
    if let (lat, lon) = fixture.gps {
        properties[kCGImagePropertyGPSDictionary] = [
            kCGImagePropertyGPSLatitude: abs(lat),
            kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(lon),
            kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W"
        ]
    }
    let url = output.appendingPathComponent(fixture.name + ".jpg")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        fatalError("Cannot create \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(destination, image(shade: fixture.shade, width: fixture.size.width, height: fixture.size.height), properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(url.lastPathComponent)") }
}
// One second of solid colour as H.264, so the viewer has a real video to play.
func writeVideo(to url: URL) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<10 {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 320, height: 240, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        context.draw(image(shade: Double(frame) / 10, width: 320, height: 240), in: CGRect(x: 0, y: 0, width: 320, height: 240))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}
try writeVideo(to: output.appendingPathComponent("clip-1.mov"))
print("Wrote \(fixtures.count) synthetic photos and 1 video to \(output.path)")

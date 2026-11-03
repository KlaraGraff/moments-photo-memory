import Foundation

/// File-name check for screenshots found in a folder import.
///
/// Only names that a screenshot tool is known to produce count. A photo sent
/// by a friend (for example `IMG_1234.JPG` or `mmexport123.jpg`) must never be
/// treated as a screenshot just because it lacks a camera model.
enum ScreenshotFileName {
    /// Name prefixes (compared case-insensitively) written by screenshot tools
    /// on iOS, iPadOS, the Mac, the Vision Pro simulator, Android, WeChat and
    /// Windows.
    static let screenshotPrefixes: [String] = [
        "Screenshot",
        "Screen Shot",
        "截屏",
        "屏幕快照",
        "屏幕截图",
        "Bildschirmfoto",
        "Simulator Screenshot",
        "微信截图"
    ]

    /// True when the file name starts with a known screenshot prefix.
    ///
    /// - Parameter fileName: a file name, not a path; `url.lastPathComponent`.
    static func looksLikeScreenshot(_ fileName: String) -> Bool {
        let name: String = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return screenshotPrefixes.contains { (prefix: String) -> Bool in
            name.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
        }
    }
}

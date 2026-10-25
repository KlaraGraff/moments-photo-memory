import Foundation

enum OriginalMediaBookmark {
    static let pathFallbackPrefix = "moments-path-fallback:\u{0}"

    static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        if let value = String(data: data, encoding: .utf8), value.hasPrefix(pathFallbackPrefix) {
            return (URL(fileURLWithPath: String(value.dropFirst(pathFallbackPrefix.count))), false)
        }
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }
        return (url, isStale)
    }
}

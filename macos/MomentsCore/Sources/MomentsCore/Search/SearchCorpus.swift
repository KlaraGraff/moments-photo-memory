import Foundation

/// How search compares words: case, accents and full/half width do not
/// matter, so "cafe" finds "Café" and "ＡＢＣ" finds "abc". Chinese, Japanese
/// and other scripts are left as they are.
public enum SearchFolding {
    public static func fold(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    /// The words of a query, folded: split on any whitespace (a full-width
    /// space included). Every word has to be found for a photo to match.
    public static func words(of query: String) -> [String] {
        query
            .split(whereSeparator: \.isWhitespace)
            .map { (word: Substring) -> String in fold(String(word)) }
            .filter { (word: String) -> Bool in !word.isEmpty }
    }
}

/// Every searchable text of every photo, folded once and laid end to end, so
/// a search reads one buffer per typed word instead of every photo's
/// fields. A photo matches when each word is inside one of its texts (the
/// words may sit in different texts), the same rule the Library's search
/// always had.
///
/// Texts are joined by a newline. A query word never holds whitespace, so a
/// word cannot match across two texts or two photos.
public struct SearchCorpus: Sendable {
    /// All photos' folded texts, UTF-8, each photo's block ending in a newline.
    private let bytes: [UInt8]
    /// Where each photo's block starts in `bytes`, ascending.
    private let starts: [Int]
    /// The photo id of each block, in the same order as `starts`.
    private let ids: [String]

    private static let separator: UInt8 = 0x0A

    /// `textsByID`: each photo's texts. Empty and whitespace-only texts are
    /// dropped; a photo with none is still counted, and matches nothing.
    public init(textsByID: [String: [String]]) {
        var bytes: [UInt8] = []
        var starts: [Int] = []
        var ids: [String] = []
        starts.reserveCapacity(textsByID.count)
        ids.reserveCapacity(textsByID.count)
        // Sorted so the same texts always give the same corpus.
        for id in textsByID.keys.sorted() {
            starts.append(bytes.count)
            ids.append(id)
            for text in textsByID[id] ?? [] {
                let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                // A newline inside a text would split a phrase the same way a
                // query's space does, so it stays harmless.
                bytes.append(contentsOf: SearchFolding.fold(trimmed).utf8)
                bytes.append(Self.separator)
            }
            // An empty photo still ends its (empty) block, so blocks never touch.
            if bytes.last != Self.separator { bytes.append(Self.separator) }
        }
        self.bytes = bytes
        self.starts = starts
        self.ids = ids
    }

    /// How many photos the corpus holds.
    public var count: Int { ids.count }

    /// Folded bytes held, for measurements.
    public var byteCount: Int { bytes.count }

    /// The photos whose texts hold every word of `query`. Nil when the query
    /// has no words: then search does not narrow anything.
    public func ids(matching query: String) -> Set<String>? {
        let words: [String] = SearchFolding.words(of: query)
        guard !words.isEmpty else { return nil }
        // Rarest-looking first: the longest word usually leaves the fewest
        // photos, and later words only check those.
        let ordered: [String] = words.sorted { $0.utf8.count > $1.utf8.count }
        var blocks: Set<Int>? = nil
        for word in ordered {
            let found: Set<Int> = blocksContaining(Array(word.utf8), among: blocks)
            if found.isEmpty { return [] }
            blocks = found
        }
        return Set((blocks ?? []).map { ids[$0] })
    }

    /// Blocks holding `needle`, all of them or only those in `candidates`.
    private func blocksContaining(_ needle: [UInt8], among candidates: Set<Int>?) -> Set<Int> {
        guard !needle.isEmpty, !bytes.isEmpty else { return [] }
        var found = Set<Int>()
        bytes.withUnsafeBufferPointer { (hay: UnsafeBufferPointer<UInt8>) in
            needle.withUnsafeBufferPointer { (pin: UnsafeBufferPointer<UInt8>) in
                if let candidates {
                    for block in candidates where search(hay, pin, from: starts[block], to: end(of: block)) != nil {
                        found.insert(block)
                    }
                    return
                }
                var position = 0
                while let hit = search(hay, pin, from: position, to: hay.count) {
                    let block = self.block(at: hit)
                    found.insert(block)
                    // The rest of this photo cannot add anything.
                    position = end(of: block)
                }
            }
        }
        return found
    }

    private func end(of block: Int) -> Int {
        block + 1 < starts.count ? starts[block + 1] : bytes.count
    }

    /// The block a byte offset falls in.
    private func block(at offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The first offset in `from..<to` where `pin` starts, or nil. UTF-8 is
    /// self-synchronizing, so a match of whole characters is a byte match.
    private func search(_ hay: UnsafeBufferPointer<UInt8>, _ pin: UnsafeBufferPointer<UInt8>, from: Int, to: Int) -> Int? {
        let length = pin.count
        guard length > 0, to - from >= length else { return nil }
        let first: UInt8 = pin[0]
        var index = from
        let last = to - length
        while index <= last {
            if hay[index] == first {
                var matched = 1
                while matched < length && hay[index + matched] == pin[matched] { matched += 1 }
                if matched == length { return index }
            }
            index += 1
        }
        return nil
    }
}

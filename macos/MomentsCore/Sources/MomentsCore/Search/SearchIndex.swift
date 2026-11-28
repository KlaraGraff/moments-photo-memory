import Foundation

/// The search index the Library keeps: every photo's texts, folded into
/// small corpora of `chunkSize` photos each, so a change to a few photos
/// folds only the chunks they are in instead of the whole library.
///
/// Matching follows `SearchCorpus`: a photo matches when each word of the
/// query is inside one of its texts.
public struct SearchIndex: Sendable {
    /// How many photos one chunk holds at most.
    public let chunkSize: Int
    /// Each photo's texts as given.
    private var texts: [String: [String]] = [:]
    /// The chunk each photo is in.
    private var chunkOf: [String: Int] = [:]
    /// The photos of each chunk.
    private var members: [[String]] = []
    /// Each chunk, folded.
    private var corpora: [SearchCorpus] = []

    public init(chunkSize: Int = 256) {
        self.chunkSize = max(1, chunkSize)
    }

    public init(textsByID: [String: [String]], chunkSize: Int = 256) {
        self.init(chunkSize: chunkSize)
        update(textsByID.mapValues { Optional($0) })
    }

    /// How many photos the index holds.
    public var count: Int { texts.count }

    /// How many chunks the index is split into.
    public var chunkCount: Int { corpora.count }

    public func contains(_ id: String) -> Bool { texts[id] != nil }

    public func texts(of id: String) -> [String]? { texts[id] }

    /// Every photo the index holds.
    public var ids: Dictionary<String, [String]>.Keys { texts.keys }

    /// Sets each photo's texts; nil takes the photo out. A photo whose texts
    /// are unchanged costs nothing. Only the chunks that changed are folded
    /// again. Returns how many photos changed.
    @discardableResult
    public mutating func update(_ changes: [String: [String]?]) -> Int {
        var dirty = Set<Int>()
        var added: [String] = []
        var changed = 0
        for (id, value) in changes {
            if let value {
                if let old = texts[id] {
                    guard old != value else { continue }
                    texts[id] = value
                    if let chunk = chunkOf[id] { dirty.insert(chunk) }
                } else {
                    texts[id] = value
                    added.append(id)
                }
                changed += 1
            } else {
                guard texts.removeValue(forKey: id) != nil else { continue }
                if let chunk = chunkOf.removeValue(forKey: id) {
                    if let index = members[chunk].firstIndex(of: id) {
                        members[chunk].swapAt(index, members[chunk].count - 1)
                        members[chunk].removeLast()
                    }
                    dirty.insert(chunk)
                }
                changed += 1
            }
        }
        // Sorted, so the same photos always land in the same chunks.
        added.sort()
        for id in added {
            if members.last.map({ $0.count >= chunkSize }) ?? true {
                members.append([])
                corpora.append(SearchCorpus(textsByID: [:]))
            }
            let chunk = members.count - 1
            members[chunk].append(id)
            chunkOf[id] = chunk
            dirty.insert(chunk)
        }
        for chunk in dirty {
            var chunkTexts: [String: [String]] = [:]
            chunkTexts.reserveCapacity(members[chunk].count)
            for id in members[chunk] { chunkTexts[id] = texts[id] ?? [] }
            corpora[chunk] = SearchCorpus(textsByID: chunkTexts)
        }
        return changed
    }

    /// The photos whose texts hold every word of `query`; nil when the query
    /// has no words.
    public func ids(matching query: String) -> Set<String>? {
        let words: [String] = SearchFolding.words(of: query)
        guard !words.isEmpty else { return nil }
        let ordered: [[UInt8]] = SearchCorpus.ordered(words)
        var result = Set<String>()
        for corpus in corpora where corpus.count > 0 {
            result.formUnion(corpus.ids(matchingOrderedWords: ordered))
        }
        return result
    }
}

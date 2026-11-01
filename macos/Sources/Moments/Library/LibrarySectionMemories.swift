import Foundation

/// Works out each Library section's memories once, for the page that builds
/// the sections, instead of a query and a pass over the section's photos in
/// every section's body.
enum LibrarySectionMemories {
    /// Each section's memories, in `memories` order: a trip memory for a
    /// "trip:<id>" section, and day or photo memories for the days its
    /// photos were taken. Same rule as `LibrarySectionView.sectionMemories` had.
    /// The day keys come ready-made from the page (`cachedSectionDayKeys`).
    static func make(
        sections: [LibrarySection],
        dayKeysBySection: [String: Set<String>],
        memories: [CollectionMemory]
    ) -> [String: [CollectionMemory]] {
        guard !memories.isEmpty else { return [:] }
        var result: [String: [CollectionMemory]] = [:]
        result.reserveCapacity(sections.count)
        for section in sections {
            let tripID: String? = section.id.hasPrefix("trip:")
                ? String(section.id.dropFirst("trip:".count))
                : nil
            let dayKeys: Set<String> = dayKeysBySection[section.id] ?? []
            var matched: [CollectionMemory] = []
            for memory in memories {
                switch memory.scope {
                case .trip:
                    if let tripID, memory.scopeKey == tripID { matched.append(memory) }
                case .day, .photo:
                    if dayKeys.contains(memory.scopeKey) { matched.append(memory) }
                }
            }
            if !matched.isEmpty { result[section.id] = matched }
        }
        return result
    }

    /// Whether two maps hold the same memory ids, in the same order, for every
    /// section. The page assigns a freshly matched map only when this is false:
    /// a section list rebuilt with unchanged memories must not redraw every
    /// section. Only the ids are compared, because a memory's text is read from
    /// the same model object either way.
    static func sameIDs(
        _ current: [String: [CollectionMemory]],
        _ next: [String: [CollectionMemory]]
    ) -> Bool {
        let currentIDs: [String: [String]] = current.mapValues { (memories: [CollectionMemory]) -> [String] in
            memories.map { (memory: CollectionMemory) -> String in memory.id }
        }
        let nextIDs: [String: [String]] = next.mapValues { (memories: [CollectionMemory]) -> [String] in
            memories.map { (memory: CollectionMemory) -> String in memory.id }
        }
        return currentIDs == nextIDs
    }
}

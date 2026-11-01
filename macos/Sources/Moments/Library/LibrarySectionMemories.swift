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
}

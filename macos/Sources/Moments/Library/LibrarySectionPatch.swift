import Foundation
import MomentsCore

/// Updates the Library's sections for a few changed photos instead of
/// building every section again.
///
/// A background save (a place name found, a time zone repaired) moves the
/// dates or chapters of a few dozen photos out of tens of thousands. Only the
/// sections those photos left or joined can change, so only those are built
/// again, with the same `LibraryFilterEngine.sections` the full path uses, and
/// put back among the others in the same order. `LibrarySectionPatchTests`
/// checks every result against a full rebuild.
enum LibrarySectionPatch {
    /// The unfolded sections after `changedIDs` changed.
    ///
    /// - Parameters:
    ///   - old: the unfolded sections built before the change, from exactly
    ///     the photos `itemByID` holds now (none added or removed since).
    ///   - itemByID: every photo the sections show, by id, as they are now.
    ///   - changedIDs: the photos whose date, chapter or other fields moved.
    /// - Returns: the new sections and the ids of the sections that were
    ///   built again or dropped, or nil when the change cannot be applied
    ///   this way (a changed photo the sections do not know): the caller then
    ///   rebuilds in full.
    static func sections(
        _ old: [LibrarySection],
        itemByID: [String: MediaItem],
        changedIDs: Set<String>,
        grouping: LibraryGrouping,
        sortOrder: LibrarySortOrder
    ) -> (sections: [LibrarySection], affectedIDs: Set<String>)? {
        guard !changedIDs.isEmpty else { return (old, []) }

        // The sections the changed photos were in.
        var affected = Set<String>()
        var found = 0
        for section in old {
            for id in section.itemIDs where changedIDs.contains(id) {
                affected.insert(section.id)
                found += 1
            }
        }
        // A changed photo the old sections did not show, or one they showed
        // twice, is not a change this can apply.
        guard found == changedIDs.count else { return nil }

        // The sections the changed photos belong to now.
        var changedItems: [MediaItem] = []
        changedItems.reserveCapacity(changedIDs.count)
        for id in changedIDs {
            guard let item = itemByID[id] else { return nil }
            changedItems.append(item)
        }
        let joined: [LibrarySection] = LibraryFilterEngine.sections(
            forVisibleItems: changedItems,
            by: grouping,
            sortOrder: sortOrder
        )
        for section in joined { affected.insert(section.id) }

        // Every photo of an affected section, built again in the order the
        // full path reads them (the store's: capture date, then id), so each
        // section takes its title from the same photo.
        var memberIDs = Set<String>()
        for section in old where affected.contains(section.id) {
            memberIDs.formUnion(section.itemIDs)
        }
        var members: [(date: Date, id: String, item: MediaItem)] = []
        members.reserveCapacity(memberIDs.count)
        for id in memberIDs {
            guard let item = itemByID[id] else { return nil }
            members.append((date: item.captureDate ?? .distantPast, id: id, item: item))
        }
        members.sort { (lhs: (date: Date, id: String, item: MediaItem), rhs: (date: Date, id: String, item: MediaItem)) -> Bool in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.id < rhs.id
        }
        let rebuilt: [LibrarySection] = LibraryFilterEngine.sections(
            forVisibleItems: members.map(\.item),
            by: grouping,
            sortOrder: sortOrder
        )

        var result: [LibrarySection] = old.filter { !affected.contains($0.id) }
        result.append(contentsOf: rebuilt)
        result.sort { (lhs: LibrarySection, rhs: LibrarySection) -> Bool in
            sectionOrder(lhs, rhs, sortOrder: sortOrder)
        }
        return (result, affected)
    }

    /// The order `LibraryFilterEngine.sections` puts sections in.
    static func sectionOrder(_ lhs: LibrarySection, _ rhs: LibrarySection, sortOrder: LibrarySortOrder) -> Bool {
        let oldest: Bool = sortOrder == .oldestFirst
        let left: Date = (oldest ? lhs.startDate : lhs.endDate) ?? .distantPast
        let right: Date = (oldest ? rhs.startDate : rhs.endDate) ?? .distantPast
        if left != right { return oldest ? left < right : left > right }
        return lhs.id < rhs.id
    }

    /// The folded sections and stack counts after the unfolded sections in
    /// `affectedIDs` were built again: those are folded again, every other
    /// section keeps its old folded form. Same result as
    /// `LibraryFilterEngine.folding(unfolded, with: index)` when `index` is
    /// the one `oldFolded` was folded with.
    static func folding(
        unfolded: [LibrarySection],
        oldFolded: [LibrarySection],
        oldStackCounts: [String: Int],
        affectedIDs: Set<String>,
        with index: PhotoStackIndex
    ) -> (sections: [LibrarySection], stackCounts: [String: Int]) {
        guard !index.isEmpty else { return (unfolded, [:]) }
        var foldedByID: [String: LibrarySection] = [:]
        foldedByID.reserveCapacity(oldFolded.count)
        for section in oldFolded where !affectedIDs.contains(section.id) {
            foldedByID[section.id] = section
        }
        var counts: [String: Int] = oldStackCounts
        for section in oldFolded where affectedIDs.contains(section.id) {
            for id in section.itemIDs { counts[id] = nil }
        }
        var sections: [LibrarySection] = []
        sections.reserveCapacity(unfolded.count)
        for section in unfolded {
            if let kept = foldedByID[section.id] {
                sections.append(kept)
                continue
            }
            let entries = index.collapse(section.itemIDs)
            for entry in entries where entry.isStack { counts[entry.id] = entry.count }
            sections.append(LibrarySection(
                id: section.id,
                title: section.title,
                itemIDs: entries.map(\.id),
                startDate: section.startDate,
                endDate: section.endDate
            ))
        }
        return (sections, counts)
    }
}

import Foundation
import MomentsCore
import SwiftData

/// Gathers what goes into a memory book, or into "Export All Memories",
/// from the library on a context of its own, so a big chapter or library
/// never holds up the window. Only words, dates and place names are read
/// into the export; where a photo can be read from stays with the images.
enum MemoryBookCollector {
    struct Book: Sendable {
        /// Everything, before the sheet's choices (see `MemoryBookPlan`).
        var document: MemoryBookDocument
        var sources: [String: MemoryBookImages.Source]
        /// The other person's photos that are only a shared preview here.
        var previewOnlyIDs: Set<String>
    }

    /// The chapter as the Chapters page shows it: its days and places as
    /// laid out there, with the memories, comments and notes of each.
    static func book(_ trip: TimelineTrip, title: String, startDate: Date?, endDate: Date?, container: ModelContainer) throws -> Book {
        let context = ModelContext(container)
        let ids = trip.orderedItems.map(\.id)
        let items = try mediaItems(ids, context: context)
        let memories = items.values.flatMap(\.writtenMemories)
        let comments = try commentsByMemory(Set(memories.map(\.id)), context: context)
        let collection = try context.fetch(FetchDescriptor<CollectionMemory>())
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        let placeNotes = Dictionary(grouping: try context.fetch(FetchDescriptor<PlaceNote>())
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, by: \.placeKey)

        var sources: [String: MemoryBookImages.Source] = [:]
        var previewOnly: Set<String> = []
        var notedPlaces: Set<String> = []
        var placeNames: [String] = []
        var days: [MemoryBookDay] = []
        for day in trip.days {
            var bookDay = MemoryBookDay(id: day.id, dayKey: day.memoryKey, date: day.date)
            if let key = day.memoryKey {
                bookDay.memories = collection
                    .filter { $0.scope != .trip && $0.scopeKey == key }
                    .map { MemoryBookNote(text: $0.text, isOwn: AuthorNames.isLocal($0.authorAccountID)) }
            }
            for place in day.places {
                if let name = place.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    if !placeNames.contains(name) { placeNames.append(name) }
                    // A place visited on two days gets its note on the first.
                    let key = PlaceNote.key(for: name)
                    if notedPlaces.insert(key).inserted {
                        for note in placeNotes[key] ?? [] {
                            bookDay.placeNotes.append(MemoryBookPlaceNote(placeName: name, text: note.text, isOwn: AuthorNames.isLocal(note.authorAccountID)))
                        }
                    }
                }
                for snapshot in place.items {
                    guard let item = items[snapshot.id] else { continue }
                    let photoMemories = item.writtenMemories.map { memory in
                        MemoryBookMemory(text: memory.text, isOwn: memory.isOwn, comments: comments[memory.id] ?? [])
                    }
                    bookDay.photos.append(MemoryBookPhoto(id: item.id, date: snapshot.date, placeName: place.name, memories: photoMemories))
                    let source = source(for: item)
                    sources[item.id] = source
                    if source.sharedPreview != nil, source.original.photosLocalIdentifier == nil, source.original.bookmarkData == nil {
                        previewOnly.insert(item.id)
                    }
                }
            }
            days.append(bookDay)
        }

        let chapterMemories = trip.isUnsorted ? [] : collection
            .filter { $0.scope == .trip && $0.scopeKey == trip.id }
            .map { MemoryBookNote(text: $0.text, isOwn: AuthorNames.isLocal($0.authorAccountID)) }
        let document = MemoryBookDocument(
            title: title,
            startDate: startDate ?? trip.startDate,
            endDate: endDate ?? trip.endDate,
            placeNames: Array(placeNames.prefix(5)),
            chapterMemories: chapterMemories,
            days: days
        )
        return Book(document: document, sources: sources, previewOnlyIDs: previewOnly)
    }

    /// Everything both people wrote, for "Export All Memories". Each photo
    /// goes with its trip, else the earliest chapter it was added to.
    static func archive(container: ModelContainer) throws -> MemoryArchive.Input {
        let context = ModelContext(container)
        let memories = try context.fetch(FetchDescriptor<Memory>())
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        let comments = try commentsByMemory(Set(memories.map(\.id)), context: context)

        let trips = try context.fetch(FetchDescriptor<Trip>())
        let chapterRaw = UserGroup.Kind.chapter.rawValue
        let groups = try context.fetch(FetchDescriptor<UserGroup>(predicate: #Predicate { $0.kindRaw == chapterRaw }))
        var chapters: [String: MemoryArchive.Chapter] = [:]
        for trip in trips {
            chapters[trip.id] = MemoryArchive.Chapter(id: trip.id, title: trip.effectiveName, startDate: trip.startDate, endDate: trip.endDate, dayKeys: dayKeys(from: trip.startDate, to: trip.endDate))
        }
        for group in groups {
            let info = group.chapterInfo
            chapters[group.id] = MemoryArchive.Chapter(id: group.id, title: group.name, startDate: info.startDate, endDate: info.endDate, dayKeys: dayKeys(from: info.startDate, to: info.endDate))
        }
        // The earliest chapter each photo is in, for photos in no trip.
        let groupIDs = Set(groups.map(\.id))
        var groupOfMedia: [String: String] = [:]
        if !groupIDs.isEmpty {
            let links = try context.fetch(FetchDescriptor<UserGroupItem>(predicate: #Predicate { !$0.excluded }))
            for link in links where groupIDs.contains(link.groupID) {
                if let current = groupOfMedia[link.mediaID], let a = chapters[current], let b = chapters[link.groupID],
                   !startsBefore(b.startDate, a.startDate) {
                    continue
                }
                groupOfMedia[link.mediaID] = link.groupID
            }
        }

        var photos: [String: MemoryArchive.Photo] = [:]
        for memory in memories {
            guard let item = memory.mediaItem, item.deletedAt == nil else { continue }
            let entry = MemoryBookMemory(text: memory.text, isOwn: memory.isOwn, comments: comments[memory.id] ?? [])
            if photos[item.id] != nil {
                photos[item.id]?.photo.memories.append(entry)
                continue
            }
            let chapterID = item.tripID.flatMap { chapters[$0] == nil ? nil : $0 } ?? groupOfMedia[item.id]
            let dayKey = PhotoNoteDay.key(for: item)
            if let chapterID, let dayKey { chapters[chapterID]?.dayKeys.insert(dayKey) }
            photos[item.id] = MemoryArchive.Photo(
                chapterID: chapterID,
                dayKey: dayKey,
                photo: MemoryBookPhoto(id: item.id, date: item.effectiveCaptureDate, placeName: item.namedPlace, memories: [entry])
            )
        }
        let collection = try context.fetch(FetchDescriptor<CollectionMemory>())
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        var dayMemories: [String: [MemoryBookNote]] = [:]
        for record in collection {
            let note = MemoryBookNote(text: record.text, isOwn: AuthorNames.isLocal(record.authorAccountID))
            if record.scope == .trip {
                chapters[record.scopeKey]?.memories.append(note)
            } else {
                dayMemories[record.scopeKey, default: []].append(note)
            }
        }
        let placeNotes = try context.fetch(FetchDescriptor<PlaceNote>())
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { MemoryBookPlaceNote(placeName: $0.placeName, text: $0.text, isOwn: AuthorNames.isLocal($0.authorAccountID)) }

        return MemoryArchive.Input(
            chapters: Array(chapters.values),
            photos: photos.values.sorted { MemoryArchive.photoComesFirst($0.photo, $1.photo) },
            dayMemories: dayMemories.map { MemoryArchive.DayMemories(dayKey: $0.key, date: date(fromKey: $0.key), memories: $0.value) },
            placeNotes: placeNotes
        )
    }

    // MARK: Pieces

    static func source(for item: MediaItem) -> MemoryBookImages.Source {
        let ratio = item.width > 0 && item.height > 0 ? Double(item.width) / Double(item.height) : nil
        return MemoryBookImages.Source(
            id: item.id,
            original: PeopleMediaDescriptor(item),
            sharedPreview: SharedPreviewFiles.previewURL(for: item),
            thumbnail: ThumbnailSource(item: item),
            aspectRatio: ratio
        )
    }

    private static func mediaItems(_ ids: [String], context: ModelContext) throws -> [String: MediaItem] {
        var result: [String: MediaItem] = [:]
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(ids.count, start + 400)])
            start += 400
            let descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { chunk.contains($0.id) })
            for item in try context.fetch(descriptor) where item.deletedAt == nil {
                result[item.id] = item
            }
        }
        return result
    }

    /// Each memory's comments in reading order: a comment, then the answers
    /// to it, oldest first.
    private static func commentsByMemory(_ memoryIDs: Set<String>, context: ModelContext) throws -> [String: [MemoryBookComment]] {
        guard !memoryIDs.isEmpty else { return [:] }
        let all = try context.fetch(FetchDescriptor<Comment>())
            .filter { memoryIDs.contains($0.memoryID) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var result: [String: [MemoryBookComment]] = [:]
        for (memoryID, comments) in Dictionary(grouping: all, by: \.memoryID) {
            let sorted = comments.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
            let ids = Set(sorted.map(\.id))
            let children = Dictionary(grouping: sorted.filter { $0.parentCommentID.map(ids.contains) ?? false }, by: { $0.parentCommentID ?? "" })
            var ordered: [MemoryBookComment] = []
            var visited: Set<String> = []
            func visit(_ comment: Comment, depth: Int) {
                guard visited.insert(comment.id).inserted else { return }
                ordered.append(MemoryBookComment(text: comment.text, isOwn: AuthorNames.isLocal(comment.authorAccountID), depth: min(depth, 1)))
                for child in children[comment.id] ?? [] { visit(child, depth: depth + 1) }
            }
            for comment in sorted where !(comment.parentCommentID.map(ids.contains) ?? false) {
                visit(comment, depth: 0)
            }
            result[memoryID] = ordered
        }
        return result
    }

    /// Every day from `start` to `end`, as day memories are keyed.
    static func dayKeys(from start: Date?, to end: Date?) -> Set<String> {
        guard let start else { return [] }
        let calendar = Calendar.current
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end ?? start)
        let count = calendar.dateComponents([.day], from: first, to: last).day ?? 0
        var keys: Set<String> = []
        for offset in 0...min(max(count, 0), 400) {
            if let day = calendar.date(byAdding: .day, value: offset, to: first) {
                keys.insert(PhotoNoteDay.key(for: day, calendar: calendar))
            }
        }
        return keys
    }

    /// Noon on the day a `yyyy-MM-dd` key names, for showing it.
    static func date(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    private static func startsBefore(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?): return left < right
        case (.some, nil): return true
        default: return false
        }
    }
}

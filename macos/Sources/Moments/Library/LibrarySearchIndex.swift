import Foundation
import MomentsCore
import QuartzCore
import SwiftData

/// The search behind the Library's search field and every page's shared
/// search: one index of every word written in the app, by photo id, built
/// once and kept until something people wrote, or the photos, changes.
///
/// Each photo's entry holds its own words (place, trip, memories, tags), the
/// year and month it was taken, the names of the people in it, and what was
/// written about it anywhere else: the comments under its memories, the
/// original words of its notes, its day's memories, its trip's or
/// chapter's memories and its place's notes. Typing then reads this index
/// only; nothing is fetched per keystroke.
@MainActor
enum LibrarySearchIndex {
    /// The last index built and the inputs it was built from.
    private static var cached: (key: Int, corpus: SearchCorpus)?

    #if DEBUG
    /// How many times an index was built, for tests.
    private(set) static var buildCount = 0
    #endif

    /// The photos that match `query`, or nil when it has no words (then the
    /// search narrows nothing).
    static func matchingIDs(
        query: String,
        store: LibraryStore,
        people: [Person],
        personIndex: [String: Set<String>],
        context: ModelContext,
        calendar: Calendar = .current
    ) -> Set<String>? {
        guard !SearchFolding.words(of: query).isEmpty else { return nil }
        let corpus: SearchCorpus = corpus(store: store, people: people, personIndex: personIndex, context: context, calendar: calendar)
        return corpus.ids(matching: query)
    }

    /// The index for the library as it is now: the cached one while nothing
    /// it reads has changed, else a new one.
    static func corpus(
        store: LibraryStore,
        people: [Person],
        personIndex: [String: Set<String>],
        context: ModelContext,
        calendar: Calendar = .current
    ) -> SearchCorpus {
        let key: Int = key(store: store, people: people, calendar: calendar)
        if let cached, cached.key == key { return cached.corpus }
        #if DEBUG
        let started: CFTimeInterval = CACurrentMediaTime()
        #endif
        let corpus: SearchCorpus = makeCorpus(
            items: store.items,
            people: people,
            personIndex: personIndex,
            context: context,
            calendar: calendar
        )
        cached = (key, corpus)
        #if DEBUG
        buildCount += 1
        PageProbe.tally("search index built", seconds: CACurrentMediaTime() - started)
        #endif
        return corpus
    }

    /// What the index depends on, as revisions the store already keeps, so
    /// working it out reads no records. People's names are few and read here.
    static func key(store: LibraryStore, people: [Person], calendar: Calendar) -> Int {
        var hasher = Hasher()
        // Photos added, removed, moved in time or place, faces assigned.
        hasher.combine(store.photoFaceRevision)
        hasher.combine(store.placeRevision)
        // Memories, memberships, tags and overrides.
        hasher.combine(store.groupSourcesRevision)
        // Comments, notes, day and trip memories, place notes, trip and person names.
        hasher.combine(store.writtenTextRevision)
        hasher.combine(store.items.count)
        for person in people {
            hasher.combine(person.id)
            hasher.combine(person.name)
            hasher.combine(person.hidden)
        }
        hasher.combine(calendar.identifier)
        hasher.combine(calendar.timeZone.identifier)
        hasher.combine(calendar.locale?.identifier)
        return hasher.finalize()
    }

    /// Drops the cached index; the next search builds one.
    static func reset() {
        cached = nil
    }

    /// Builds the index from the given photos and everything written in
    /// `context`. Each kind of record is fetched once.
    static func makeCorpus(
        items: [MediaItem],
        people: [Person],
        personIndex: [String: Set<String>],
        context: ModelContext,
        calendar: Calendar = .current
    ) -> SearchCorpus {
        let sources: WrittenTextIndex.Sources = writtenSources(context: context)
        let chapterMemberships: [String: [String]] = chapterKeysByPhoto(context: context)

        var photos: [WrittenTextIndex.Photo] = []
        photos.reserveCapacity(items.count)
        for item in items {
            var chapters: [String] = chapterMemberships[item.id] ?? []
            if let tripID = item.tripID { chapters.append(tripID) }
            if let tripID = item.trip?.id, tripID != item.tripID { chapters.append(tripID) }
            let placeNames: [String] = [item.namedPlace, item.effectivePlaceName, item.displayPlaceName].compactMap { $0 }
            photos.append(
                WrittenTextIndex.Photo(
                    id: item.id,
                    dayKey: PhotoNoteDay.key(for: item),
                    chapterKeys: chapters,
                    placeNames: placeNames
                )
            )
        }
        let written: [String: [String]] = WrittenTextIndex.textsByPhoto(photos: photos, sources: sources)
        // The names of the people in each photo; hidden people are not searched.
        var nameByPerson: [String: String] = [:]
        for person in people where !person.hidden {
            let name: String = person.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty { nameByPerson[person.id] = name }
        }

        var texts: [String: [String]] = [:]
        texts.reserveCapacity(items.count)
        for item in items {
            var entry: [String] = LibraryFilterEngine.searchableOwnTexts(of: item)
            entry += LibraryFilterEngine.dateWords(of: item, calendar: calendar)
            if !nameByPerson.isEmpty, let personIDs = personIndex[item.id] {
                entry += personIDs.compactMap { nameByPerson[$0] }
            }
            entry += written[item.id] ?? []
            texts[item.id] = entry
        }
        return SearchCorpus(textsByID: texts)
    }

    /// Every written record, as plain values.
    static func writtenSources(context: ModelContext) -> WrittenTextIndex.Sources {
        var sources = WrittenTextIndex.Sources()
        // Both people's memories, also one whose photo link is not set yet.
        for memory in (try? context.fetch(FetchDescriptor<Memory>())) ?? [] {
            guard let mediaID = memory.mediaID ?? memory.mediaItem?.id else { continue }
            sources.photoTexts.append(.init(id: memory.id, mediaID: mediaID, text: memory.text))
        }
        // What was typed before the AI organized it.
        for note in (try? context.fetch(FetchDescriptor<PhotoNote>())) ?? [] {
            sources.photoTexts.append(.init(mediaID: note.mediaID, text: note.text))
        }
        for memory in (try? context.fetch(FetchDescriptor<CollectionMemory>())) ?? [] {
            switch memory.scope {
            case .day:
                sources.collectionTexts.append(.init(id: memory.id, scope: .day, key: memory.scopeKey, text: memory.text))
            case .trip:
                sources.collectionTexts.append(.init(id: memory.id, scope: .chapter, key: memory.scopeKey, text: memory.text))
            case .photo:
                // Not written by the app; a photo's memory is a `Memory`.
                sources.photoTexts.append(.init(id: memory.id, mediaID: memory.scopeKey, text: memory.text))
            }
        }
        for note in (try? context.fetch(FetchDescriptor<PlaceNote>())) ?? [] {
            sources.placeTexts.append(.init(placeName: note.placeName, text: note.text))
            // Keyed by its stored key too, in case the name was corrected since.
            if note.placeKey != WrittenTextIndex.placeKey(for: note.placeName) {
                sources.placeTexts.append(.init(placeName: note.placeKey, text: note.text))
            }
        }
        for comment in (try? context.fetch(FetchDescriptor<Comment>())) ?? [] {
            sources.comments.append(.init(memoryID: comment.memoryID, text: comment.text))
        }
        return sources
    }

    /// The chapters (that are not trips) each photo is in, by the id a
    /// chapter's memories are written under.
    static func chapterKeysByPhoto(context: ModelContext) -> [String: [String]] {
        let chapterKind: String = UserGroup.Kind.chapter.rawValue
        let groups: [UserGroup] = (try? context.fetch(FetchDescriptor<UserGroup>(predicate: #Predicate<UserGroup> { $0.kindRaw == chapterKind }))) ?? []
        guard !groups.isEmpty else { return [:] }
        var keyByGroupID: [String: String] = [:]
        for group in groups { keyByGroupID[group.id] = TripsScreen.chapterID(group) }
        var result: [String: [String]] = [:]
        for member in (try? context.fetch(FetchDescriptor<UserGroupItem>())) ?? [] where !member.excluded {
            guard let key = keyByGroupID[member.groupID] else { continue }
            result[member.mediaID, default: []].append(key)
        }
        return result
    }
}

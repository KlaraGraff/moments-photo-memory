import Foundation
import MomentsCore
import QuartzCore
import SwiftData

/// The search behind the Library's search field and every page's shared
/// search: one index of every word written in the app, by photo id, kept up
/// to date a few photos at a time.
///
/// Each photo's entry holds its place names and the year and month it was
/// taken, its tags, the names of the people in it, and everything written
/// about it anywhere: its memories (both people's) and their comments, the
/// original words of its notes, its day's memories, its trip's or chapter's
/// name and memories, and its place's notes. Typing reads this index only.
///
/// Nothing is built again in full on the main thread while someone types:
/// - A save of something written reads again only the rows it saved and
///   updates only the photos whose texts changed (a comment: one photo; a
///   day's memory: that day's photos). Every row of a kind is read again
///   only when the store cannot say which rows a save touched.
/// - Reading every photo (the first time, or after places were renamed)
///   happens in slices between other main-thread work, while the index from
///   before keeps answering. A photo not read yet is matched the old way.
@MainActor
enum LibrarySearchIndex {
    // MARK: What a search asks

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
        let state: State = prepare(store: store, people: people, personIndex: personIndex, context: context, calendar: calendar)
        // A few photos changed by the last save are read now; a whole
        // library waits for the slices.
        state.readPending(budget: Self.keystrokeBudget)
        scheduleSlices(state)
        guard var found: Set<String> = state.index.ids(matching: query) else { return nil }
        // Photos not read yet: the old search, so none is missing meanwhile.
        let unread: [String] = state.pending.filter { !state.index.contains($0) }
        if !unread.isEmpty {
            var nameByPerson: [String: String] = [:]
            for person in people where !person.hidden {
                if let name = person.name, !name.isEmpty { nameByPerson[person.id] = name }
            }
            for id in unread {
                guard let item = store.itemsByID[id] else { continue }
                var extras: [String] = LibraryFilterEngine.dateWords(of: item, calendar: calendar)
                extras += (personIndex[id] ?? []).compactMap { nameByPerson[$0] }
                if LibraryFilterEngine.matchesSearch(item, query, extras: extras) { found.insert(id) }
            }
            #if DEBUG
            PageProbe.tally("search matched photos not indexed yet")
            #endif
        }
        return found
    }

    /// Starts reading the library into the index, a slice at a time, so it
    /// is ready before the first word is typed. Cheap when it is ready.
    static func warmUp(
        store: LibraryStore,
        people: [Person],
        personIndex: [String: Set<String>],
        context: ModelContext,
        calendar: Calendar = .current
    ) {
        if let state, state.belongs(to: store, calendar: calendar) {
            _ = prepare(store: store, people: people, personIndex: personIndex, context: context, calendar: calendar)
            scheduleSlices(state)
            return
        }
        // The first time: after the page has drawn.
        warmUpTask?.cancel()
        warmUpTask = Task { @MainActor [weak store] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let store else { return }
            let state: State = prepare(store: store, people: people, personIndex: personIndex, context: context, calendar: calendar)
            scheduleSlices(state)
        }
    }

    /// Drops the index; the next search starts again.
    static func reset() {
        state?.sliceTask?.cancel()
        state = nil
        warmUpTask?.cancel()
        warmUpTask = nil
    }

    /// How long a keystroke may spend reading photos changed since the last
    /// one, and how long one slice of a full read takes at most.
    static let keystrokeBudget: CFTimeInterval = 0.04
    static let sliceBudget: CFTimeInterval = 0.025
    /// A full read (every photo) starts at most this often after the last
    /// one ended; the index from before answers meanwhile.
    static let fullReadInterval: CFTimeInterval = 10

    #if DEBUG
    /// Photos whose fields were read, and photos whose entries changed, for tests.
    static var photosRead: Int { state?.photosRead ?? 0 }
    static var entriesChanged: Int { state?.entriesChanged ?? 0 }
    /// Written rows (memories, notes, comments, trips) read so far.
    static var writtenRowsRead: Int { state?.rowsRead ?? 0 }
    /// True when every photo is read and nothing waits.
    static var isReady: Bool { state.map { $0.pending.isEmpty && !$0.fullReadRequested } ?? false }
    /// The longest a slice of a full read took, for the 50,000-photo test.
    static var longestSlice: CFTimeInterval { state?.longestSlice ?? 0 }
    /// Reads everything still waiting, at once. Tests only.
    static func finishReading() {
        guard let state else { return }
        if state.fullReadRequested { state.queueFullRead() }
        state.readPending(budget: .infinity)
    }
    #endif

    // MARK: State

    private static var state: State?
    private static var warmUpTask: Task<Void, Never>?

    /// What a photo's own fields give the index, and where the photo belongs.
    private struct Fields: Equatable {
        var texts: [String]
        var dayKey: String?
        var tripIDs: [String]
        var placeNames: [String]
    }

    /// Where a photo's entry was filed, so a change of day, chapter or
    /// place can unfile it.
    private struct Filed: Equatable {
        var dayKey: String?
        var chapterKeys: Set<String>
        var placeKeys: Set<String>
    }

    private static let writtenEntities: [String] = [
        String(describing: Memory.self),
        String(describing: PhotoNote.self),
        String(describing: CollectionMemory.self),
        String(describing: PlaceNote.self),
        String(describing: Comment.self),
        String(describing: Trip.self),
    ]
    private static let writtenEntitySet: Set<String> = Set(writtenEntities)
    private static let tagEntities: [String] = [String(describing: MediaTag.self), String(describing: Tag.self)]
    private static let chapterEntities: [String] = [String(describing: UserGroup.self), String(describing: UserGroupItem.self)]
    private static let placeOverrideEntity: String = String(describing: PlaceOverride.self)

    @MainActor
    private final class State {
        let storeID: ObjectIdentifier
        let calendarKey: Int
        let calendar: Calendar
        weak var store: LibraryStore?

        var index = SearchIndex()
        var fields: [String: Fields] = [:]
        var tags: [String: [String]] = [:]
        var names: [String: [String]] = [:]
        var memberships: [String: [String]] = [:]
        /// Everything written, record by record, and which records each
        /// row gave, so a save reads again only the rows it changed.
        var book = WrittenTextIndex.Book()
        var recordKeysByRow: [PersistentIdentifier: [String]] = [:]
        var rowIDs: [PersistentIdentifier: String] = [:]
        var rowsByEntity: [String: Set<PersistentIdentifier>] = [:]
        var writtenMark: LibraryStore.SearchSourceMark?
        var rowsRead = 0
        var filed: [String: Filed] = [:]
        var photosByDay: [String: Set<String>] = [:]
        var photosByChapter: [String: Set<String>] = [:]
        var photosByPlace: [String: Set<String>] = [:]

        /// The revisions the index is current to; nil before the first read.
        var photoRevision: Int?
        var placeKey: Int?
        var sourceRevisions: [String: Int] = [:]
        var namesKey: Int?

        /// Photos whose fields wait to be read, oldest first.
        var pending: [String] = []
        var pendingSet: Set<String> = []
        /// Every photo should be read again (places renamed, a save that
        /// could not say which photos changed), once the interval allows.
        var fullReadRequested = false
        var lastFullReadEnded: CFTimeInterval = -.infinity
        var fullReadInProgress = false
        var sliceTask: Task<Void, Never>?

        var photosRead = 0
        var entriesChanged = 0
        var longestSlice: CFTimeInterval = 0

        init(store: LibraryStore, calendar: Calendar) {
            self.storeID = ObjectIdentifier(store)
            self.store = store
            self.calendar = calendar
            self.calendarKey = LibrarySearchIndex.calendarKey(calendar)
        }

        func belongs(to store: LibraryStore, calendar: Calendar) -> Bool {
            storeID == ObjectIdentifier(store) && calendarKey == LibrarySearchIndex.calendarKey(calendar)
        }

        var hasWork: Bool { !pending.isEmpty || fullReadRequested }

        func enqueue<S: Sequence>(_ ids: S) where S.Element == String {
            for id in ids where pendingSet.insert(id).inserted { pending.append(id) }
        }

        /// Every photo the store lists, to be read again.
        func queueFullRead() {
            guard let store else { return }
            fullReadRequested = false
            fullReadInProgress = true
            enqueue(store.items.map(\.id))
        }

        /// Takes out photos the store no longer lists and queues the new
        /// ones first. Cheap: no photo's fields are read.
        func syncMembership() {
            guard let store else { return }
            var removed: [String: [String]?] = [:]
            for id in index.ids where store.itemsByID[id] == nil { removed[id] = .some(nil) }
            for id in fields.keys where store.itemsByID[id] == nil { removed[id] = .some(nil) }
            if !removed.isEmpty {
                for id in removed.keys {
                    fields[id] = nil
                    unfile(id)
                }
                index.update(removed)
            }
            var added: [String] = []
            for item in store.items where fields[item.id] == nil && !pendingSet.contains(item.id) { added.append(item.id) }
            if !added.isEmpty {
                // Ahead of a full read, so new photos are found soonest.
                for id in added { pendingSet.insert(id) }
                pending.insert(contentsOf: added, at: 0)
            }
        }

        /// Reads queued photos until `budget` seconds have passed, and
        /// updates their entries.
        func readPending(budget: CFTimeInterval) {
            guard !pending.isEmpty, let store else { return }
            let started: CFTimeInterval = CACurrentMediaTime()
            var changes: [String: [String]?] = [:]
            var taken = 0
            for id in pending {
                taken += 1
                pendingSet.remove(id)
                guard let item = store.itemsByID[id] else {
                    fields[id] = nil
                    unfile(id)
                    changes[id] = .some(nil)
                    continue
                }
                fields[id] = LibrarySearchIndex.fields(of: item, calendar: calendar)
                photosRead += 1
                changes[id] = entry(for: id)
                // Checked every few photos; reading one is microseconds.
                if taken % 32 == 0 && CACurrentMediaTime() - started >= budget * 0.6 { break }
            }
            pending.removeFirst(taken)
            entriesChanged += index.update(changes)
            if pending.isEmpty {
                // A full read waits `fullReadInterval` after any read ends.
                fullReadInProgress = false
                lastFullReadEnded = CACurrentMediaTime()
            }
            longestSlice = max(longestSlice, CACurrentMediaTime() - started)
        }

        /// Writes the entries of `ids` again from what is known now.
        func refresh(_ ids: Set<String>) {
            guard !ids.isEmpty else { return }
            var changes: [String: [String]?] = [:]
            for id in ids where fields[id] != nil { changes[id] = entry(for: id) }
            entriesChanged += index.update(changes)
        }

        /// A photo's entry, and where it is filed. Its fields are read.
        private func entry(for id: String) -> [String] {
            guard let own = fields[id] else { return [] }
            var chapters: [String] = own.tripIDs
            chapters += memberships[id] ?? []
            let photo = WrittenTextIndex.Photo(id: id, dayKey: own.dayKey, chapterKeys: chapters, placeNames: own.placeNames)
            file(id, Filed(
                dayKey: own.dayKey,
                chapterKeys: Set(chapters),
                placeKeys: Set(own.placeNames.map(WrittenTextIndex.placeKey(for:)).filter { !$0.isEmpty })
            ))
            var texts: [String] = own.texts
            texts += tags[id] ?? []
            texts += names[id] ?? []
            texts += book.lookup.texts(for: photo)
            return texts
        }

        private func file(_ id: String, _ new: Filed) {
            if let old = filed[id] {
                if old == new { return }
                unfile(id)
            }
            filed[id] = new
            if let day = new.dayKey { photosByDay[day, default: []].insert(id) }
            for key in new.chapterKeys { photosByChapter[key, default: []].insert(id) }
            for key in new.placeKeys { photosByPlace[key, default: []].insert(id) }
        }

        private func unfile(_ id: String) {
            guard let old = filed.removeValue(forKey: id) else { return }
            if let day = old.dayKey { photosByDay[day]?.remove(id) }
            for key in old.chapterKeys { photosByChapter[key]?.remove(id) }
            for key in old.placeKeys { photosByPlace[key]?.remove(id) }
        }

        /// The photos a change of the written texts reaches.
        func photos(reachedBy changes: WrittenTextIndex.Lookup.Changes) -> Set<String> {
            var ids: Set<String> = changes.photoIDs
            for key in changes.dayKeys { ids.formUnion(photosByDay[key] ?? []) }
            for key in changes.chapterKeys { ids.formUnion(photosByChapter[key] ?? []) }
            for key in changes.placeKeys { ids.formUnion(photosByPlace[key] ?? []) }
            return ids
        }
    }

    // MARK: Keeping up with saves

    /// The state for this store, brought up to date with what was saved
    /// since: only the kinds of record that changed are read again.
    private static func prepare(
        store: LibraryStore,
        people: [Person],
        personIndex: [String: Set<String>],
        context: ModelContext,
        calendar: Calendar
    ) -> State {
        let state: State
        if let current = Self.state, current.belongs(to: store, calendar: calendar) {
            state = current
        } else {
            Self.state?.sliceTask?.cancel()
            state = State(store: store, calendar: calendar)
            Self.state = state
        }
        var touched = Set<String>()

        // Photos and places.
        var placeHasher = Hasher()
        placeHasher.combine(store.placeRevision)
        placeHasher.combine(store.searchSourceRevision(of: placeOverrideEntity))
        let placeKey: Int = placeHasher.finalize()
        if state.photoRevision == nil {
            state.syncMembership()
        } else if state.placeKey != placeKey {
            // A place's name feeds every photo there: read them all again.
            state.syncMembership()
            state.fullReadRequested = true
        } else if let from = state.photoRevision, from != store.photoFaceRevision {
            if let ids = store.changedPhotoIDs(sincePhotoFaceRevision: from) {
                state.enqueue(ids)
            } else {
                // Photos added or removed, faces moved: those are cheap to
                // tell; anything else waits for a full read.
                state.syncMembership()
                state.fullReadRequested = true
            }
        }
        state.photoRevision = store.photoFaceRevision
        state.placeKey = placeKey

        // Tags.
        let tagKey: Int = revision(of: tagEntities, in: store)
        if state.sourceRevisions["tags"] != tagKey {
            state.sourceRevisions["tags"] = tagKey
            let tags: [String: [String]] = tagsByPhoto(context: context)
            touched.formUnion(differing(tags, state.tags))
            state.tags = tags
        }

        // Chapters and who is in them.
        let chapterKey: Int = revision(of: chapterEntities, in: store)
        if state.sourceRevisions["chapters"] != chapterKey {
            state.sourceRevisions["chapters"] = chapterKey
            let memberships: [String: [String]] = chapterKeysByPhoto(context: context)
            touched.formUnion(differing(memberships, state.memberships))
            state.memberships = memberships
        }

        // What people wrote: only the rows saved since, when the store can
        // say which; otherwise every row of the kinds that changed.
        let mark: LibraryStore.SearchSourceMark = store.searchSourceMark
        if state.writtenMark != mark {
            var records: [String: WrittenTextIndex.Book.Record?] = [:]
            if let from = state.writtenMark, let rows = store.searchSourceChanges(of: writtenEntitySet, since: from) {
                for row in rows.deleted { forget(row, in: state, into: &records) }
                var savedByEntity: [String: [PersistentIdentifier]] = [:]
                for row in rows.saved { savedByEntity[row.entityName, default: []].append(row) }
                for (entity, rows) in savedByEntity {
                    readRows(entity, rows, state: state, context: context, into: &records)
                }
                for entity in writtenEntities { state.sourceRevisions[entity] = store.searchSourceRevision(of: entity) }
            } else {
                for entity in writtenEntities {
                    let key: Int = store.searchSourceRevision(of: entity)
                    guard state.sourceRevisions[entity] != key else { continue }
                    state.sourceRevisions[entity] = key
                    readAll(entity, state: state, context: context, into: &records)
                }
            }
            state.writtenMark = mark
            let changes: WrittenTextIndex.Lookup.Changes = state.book.set(records)
            if !changes.isEmpty { touched.formUnion(state.photos(reachedBy: changes)) }
        }

        // People's names; hidden people are not searched.
        var namesHasher = Hasher()
        namesHasher.combine(store.photoFaceRevision)
        namesHasher.combine(personIndex.count)
        for person in people {
            namesHasher.combine(person.id)
            namesHasher.combine(person.name)
            namesHasher.combine(person.hidden)
        }
        let namesKey: Int = namesHasher.finalize()
        if state.namesKey != namesKey {
            state.namesKey = namesKey
            var nameByPerson: [String: String] = [:]
            for person in people where !person.hidden {
                let name: String = person.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !name.isEmpty { nameByPerson[person.id] = name }
            }
            var names: [String: [String]] = [:]
            if !nameByPerson.isEmpty {
                for (mediaID, personIDs) in personIndex {
                    let found: [String] = personIDs.compactMap { nameByPerson[$0] }.sorted()
                    if !found.isEmpty { names[mediaID] = found }
                }
            }
            touched.formUnion(differing(names, state.names))
            state.names = names
        }

        state.refresh(touched)
        return state
    }

    /// Reads the slices in the background of the main thread: one slice,
    /// then a pause so input and drawing go first.
    private static func scheduleSlices(_ state: State) {
        guard state.sliceTask == nil, state.hasWork else { return }
        state.sliceTask = Task { @MainActor [weak state] in
            while !Task.isCancelled {
                guard let current = state, current.hasWork else { break }
                if current.pending.isEmpty && current.fullReadRequested {
                    let wait: CFTimeInterval = current.lastFullReadEnded + fullReadInterval - CACurrentMediaTime()
                    if wait > 0 {
                        try? await Task.sleep(for: .seconds(min(wait, 1)))
                        continue
                    }
                    current.queueFullRead()
                }
                current.readPending(budget: sliceBudget)
                try? await Task.sleep(for: .milliseconds(25))
            }
            state?.sliceTask = nil
        }
    }

    // MARK: Reading records

    private static func calendarKey(_ calendar: Calendar) -> Int {
        var hasher = Hasher()
        hasher.combine(calendar.identifier)
        hasher.combine(calendar.timeZone.identifier)
        hasher.combine(calendar.locale?.identifier)
        return hasher.finalize()
    }

    private static func revision(of entities: [String], in store: LibraryStore) -> Int {
        var hasher = Hasher()
        for entity in entities { hasher.combine(store.searchSourceRevision(of: entity)) }
        return hasher.finalize()
    }

    /// The keys whose values differ between two maps.
    private static func differing(_ new: [String: [String]], _ old: [String: [String]]) -> Set<String> {
        var keys = Set<String>()
        for (key, value) in new where old[key] != value { keys.insert(key) }
        for key in old.keys where new[key] == nil { keys.insert(key) }
        return keys
    }

    /// A photo's own fields: where it was taken and when.
    private static func fields(of item: MediaItem, calendar: Calendar) -> Fields {
        var texts: [String] = [item.effectivePlaceName, item.displayPlaceName].compactMap { $0 }
        texts += LibraryFilterEngine.dateWords(of: item, calendar: calendar)
        var tripIDs: [String] = []
        if let tripID = item.tripID { tripIDs.append(tripID) }
        if let tripID = item.trip?.id, tripID != item.tripID { tripIDs.append(tripID) }
        return Fields(
            texts: texts,
            dayKey: PhotoNoteDay.key(for: item),
            tripIDs: tripIDs,
            placeNames: [item.namedPlace, item.effectivePlaceName, item.displayPlaceName].compactMap { $0 }
        )
    }

    /// The records one row gives, by key: a memory, note, day or trip
    /// memory, comment or trip name gives one; a place note two when its
    /// stored key no longer matches its name.
    private static func records(of model: any PersistentModel) -> (id: String, records: [(String, WrittenTextIndex.Book.Record)])? {
        switch model {
        case let memory as Memory:
            // Both people's memories, also one whose photo link is not set yet.
            guard let mediaID = memory.mediaID ?? memory.mediaItem?.id else { return (memory.id, []) }
            return (memory.id, [("Memory/\(memory.id)", .photo(id: memory.id, mediaID: mediaID, text: memory.text))])
        case let note as PhotoNote:
            // What was typed before the AI organized it.
            return (note.id, [("PhotoNote/\(note.id)", .photo(id: nil, mediaID: note.mediaID, text: note.text))])
        case let memory as CollectionMemory:
            let record: WrittenTextIndex.Book.Record
            switch memory.scope {
            case .day: record = .collection(id: memory.id, scope: .day, key: memory.scopeKey, text: memory.text)
            case .trip: record = .collection(id: memory.id, scope: .chapter, key: memory.scopeKey, text: memory.text)
            // Not written by the app; a photo's memory is a `Memory`.
            case .photo: record = .photo(id: memory.id, mediaID: memory.scopeKey, text: memory.text)
            }
            return (memory.id, [("CollectionMemory/\(memory.id)", record)])
        case let note as PlaceNote:
            var found: [(String, WrittenTextIndex.Book.Record)] = [("PlaceNote/\(note.id)", .place(placeName: note.placeName, text: note.text))]
            // Keyed by its stored key too, in case the name was corrected since.
            if note.placeKey != WrittenTextIndex.placeKey(for: note.placeName) {
                found.append(("PlaceNote/\(note.id)#key", .place(placeName: note.placeKey, text: note.text)))
            }
            return (note.id, found)
        case let comment as Comment:
            return (comment.id, [("Comment/\(comment.id)", .comment(memoryID: comment.memoryID, text: comment.text))])
        case let trip as Trip:
            return (trip.id, [("Trip/\(trip.id)", .tripName(tripID: trip.id, name: trip.effectiveName))])
        default:
            return nil
        }
    }

    /// Files what one row gives now in place of what it gave before.
    private static func fileRow(_ row: PersistentIdentifier, _ model: any PersistentModel, in state: State, into changes: inout [String: WrittenTextIndex.Book.Record?]) {
        guard let read = records(of: model) else { return }
        state.rowsRead += 1
        let newKeys: [String] = read.records.map(\.0)
        for key in state.recordKeysByRow[row] ?? [] where !newKeys.contains(key) { changes[key] = .some(nil) }
        for (key, record) in read.records { changes[key] = record }
        state.recordKeysByRow[row] = newKeys
        state.rowIDs[row] = read.id
        state.rowsByEntity[row.entityName, default: []].insert(row)
    }

    /// Takes out what a deleted row gave.
    private static func forget(_ row: PersistentIdentifier, in state: State, into changes: inout [String: WrittenTextIndex.Book.Record?]) {
        for key in state.recordKeysByRow.removeValue(forKey: row) ?? [] { changes[key] = .some(nil) }
        state.rowIDs[row] = nil
        state.rowsByEntity[row.entityName]?.remove(row)
    }

    /// Reads every row of one kind of record again.
    private static func readAll(_ entity: String, state: State, context: ModelContext, into changes: inout [String: WrittenTextIndex.Book.Record?]) {
        let models: [any PersistentModel]
        switch entity {
        case String(describing: Memory.self): models = (try? context.fetch(FetchDescriptor<Memory>())) ?? []
        case String(describing: PhotoNote.self): models = (try? context.fetch(FetchDescriptor<PhotoNote>())) ?? []
        case String(describing: CollectionMemory.self): models = (try? context.fetch(FetchDescriptor<CollectionMemory>())) ?? []
        case String(describing: PlaceNote.self): models = (try? context.fetch(FetchDescriptor<PlaceNote>())) ?? []
        case String(describing: Comment.self): models = (try? context.fetch(FetchDescriptor<Comment>())) ?? []
        case String(describing: Trip.self): models = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        default: return
        }
        var gone: Set<PersistentIdentifier> = state.rowsByEntity[entity] ?? []
        for model in models {
            let row: PersistentIdentifier = model.persistentModelID
            gone.remove(row)
            fileRow(row, model, in: state, into: &changes)
        }
        for row in gone { forget(row, in: state, into: &changes) }
    }

    /// Reads the given rows of one kind of record again. A row read before
    /// is fetched by its id, which brings back what another context saved;
    /// a new one is looked up by its identifier.
    private static func readRows(
        _ entity: String,
        _ rows: [PersistentIdentifier],
        state: State,
        context: ModelContext,
        into changes: inout [String: WrittenTextIndex.Book.Record?]
    ) {
        var known: [String: PersistentIdentifier] = [:]
        var found: [PersistentIdentifier: any PersistentModel] = [:]
        for row in rows {
            if let id = state.rowIDs[row] {
                known[id] = row
            } else {
                // Saved, so it is there; deleted rows never come here.
                let model: any PersistentModel = context.model(for: row)
                if !model.isDeleted { found[row] = model }
            }
        }
        let ids: [String] = Array(known.keys)
        let wanted: Set<PersistentIdentifier> = Set(known.values)
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let models: [any PersistentModel]
            switch entity {
            case String(describing: Memory.self): models = (try? context.fetch(FetchDescriptor<Memory>(predicate: #Predicate { chunk.contains($0.id) }))) ?? []
            case String(describing: PhotoNote.self): models = (try? context.fetch(FetchDescriptor<PhotoNote>(predicate: #Predicate { chunk.contains($0.id) }))) ?? []
            case String(describing: CollectionMemory.self): models = (try? context.fetch(FetchDescriptor<CollectionMemory>(predicate: #Predicate { chunk.contains($0.id) }))) ?? []
            case String(describing: PlaceNote.self): models = (try? context.fetch(FetchDescriptor<PlaceNote>(predicate: #Predicate { chunk.contains($0.id) }))) ?? []
            case String(describing: Comment.self): models = (try? context.fetch(FetchDescriptor<Comment>(predicate: #Predicate { chunk.contains($0.id) }))) ?? []
            case String(describing: Trip.self): models = (try? context.fetch(FetchDescriptor<Trip>(predicate: #Predicate { chunk.contains($0.id) }))) ?? []
            default: models = []
            }
            for model in models where wanted.contains(model.persistentModelID) {
                found[model.persistentModelID] = model
            }
        }
        for row in rows {
            if let model = found[row] {
                fileRow(row, model, in: state, into: &changes)
            } else {
                // Saved, then gone before this read.
                forget(row, in: state, into: &changes)
            }
        }
    }

    /// Each photo's tag names.
    private static func tagsByPhoto(context: ModelContext) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for mediaTag in (try? context.fetch(FetchDescriptor<MediaTag>())) ?? [] {
            guard let mediaID = mediaTag.mediaID ?? mediaTag.mediaItem?.id, let name = mediaTag.tag?.displayName else { continue }
            result[mediaID, default: []].append(name)
        }
        for key in result.keys { result[key]?.sort() }
        return result
    }

    /// The chapters (that are not trips) each photo is in, by the id a
    /// chapter's memories are written under.
    private static func chapterKeysByPhoto(context: ModelContext) -> [String: [String]] {
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
        for key in result.keys { result[key]?.sort() }
        return result
    }
}

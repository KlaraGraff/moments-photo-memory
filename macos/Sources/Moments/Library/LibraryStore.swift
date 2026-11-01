import Foundation
import Observation
import SwiftData

/// What one save changed, read from the `ModelContext.didSave` notification.
/// Small and `Sendable`, so it can leave the saving thread before the main
/// actor applies it.
struct SavedChanges: Sendable {
    var inserted: [PersistentIdentifier] = []
    var updated: [PersistentIdentifier] = []
    var deleted: [PersistentIdentifier] = []
    /// False when the notification did not list identifiers; then the store
    /// fetches everything again, as before.
    var isKnown = false
    /// True when the save touched something the sidebar's group counts read,
    /// even if the `trackedEntityNames` filter then drops that identifier.
    var touchesGroupSources = false

    var isEmpty: Bool { inserted.isEmpty && updated.isEmpty && deleted.isEmpty }
    var identifierCount: Int { inserted.count + updated.count + deleted.count }

    /// One save's changes added to another's. A merged batch is only known
    /// when every save in it was.
    mutating func merge(_ other: SavedChanges) {
        inserted += other.inserted
        updated += other.updated
        deleted += other.deleted
        isKnown = isKnown && other.isKnown
        touchesGroupSources = touchesGroupSources || other.touchesGroupSources
    }
}

/// The entities this store lists. A save of anything else changes nothing
/// here, so its notification is dropped.
private let trackedEntityNames: Set<String> = [
    String(describing: MediaItem.self),
    String(describing: Favorite.self),
    String(describing: PlaceOverride.self),
    String(describing: FaceObservation.self),
    String(describing: Place.self)
]

/// The entities the sidebar's group counts read besides the photos and faces
/// above: the groups and their memberships, memories, media tags, the tags
/// those media tags name and place overrides. A save of any of these can
/// change a count, so it moves `groupSourcesRevision` even though the store
/// itself lists none of them. Tags belong here because a smart group's tag
/// rule matches a photo's tags by id, `normalizedName` or `displayName`, so
/// renaming a tag can change a count without touching a photo or membership.
private let groupSourceEntityNames: Set<String> = [
    String(describing: UserGroup.self),
    String(describing: UserGroupItem.self),
    String(describing: Memory.self),
    String(describing: MediaTag.self),
    String(describing: Tag.self),
    String(describing: PlaceOverride.self)
]

/// The library's photos, faces and places, fetched once for every page
/// instead of once per page. Pages read these lists and use `revision` in
/// their rebuild keys, so switching pages fetches nothing and hashes nothing.
/// SwiftData stays the source of truth; cells keep reading their models, so
/// an edit shows in its cell at once.
///
/// After the first fetch a save no longer fetches the whole library. The
/// `didSave` notification names what changed; the store reads those few
/// models, fixes their per-object hash and rebuilds a public list only when
/// its members or their order changed. That is what keeps an import or a
/// face scan from re-reading 20,000 photos on the main thread every few
/// hundred milliseconds.
@MainActor
@Observable
final class LibraryStore {
    /// Live photos (not in Recently Deleted), by capture date.
    private(set) var items: [MediaItem] = []
    private(set) var regularItems: [MediaItem] = []
    private(set) var screenshotItems: [MediaItem] = []
    private(set) var itemsByID: [String: MediaItem] = [:]
    /// Photos in Recently Deleted, most recently deleted first.
    private(set) var deletedItems: [MediaItem] = []
    /// Every face, by id.
    private(set) var faces: [FaceObservation] = []
    /// Every place, by id.
    private(set) var places: [Place] = []
    /// Changes when something a page groups or filters by has changed:
    /// photos added, removed or moved in time or place, faces assigned,
    /// places renamed. Not bumped by saves that change none of that.
    private(set) var revision = 0
    /// Moves when a favorite is set or cleared. `revision` does not move for a
    /// save that changed nothing but favorites.
    private(set) var favoriteRevision = 0
    /// Moves with `revision` when photos or faces moved. A save that changed
    /// only places (a name resolved in the background) leaves it alone.
    private(set) var photoFaceRevision = 0
    /// Moves with `revision` when places moved (added, removed or renamed).
    private(set) var placeRevision = 0
    /// Moves when a save touched groups, memberships, memories, media tags or
    /// place overrides, or could not say what it touched. The sidebar's group
    /// counts follow it instead of querying those five entities themselves.
    private(set) var groupSourcesRevision = 0
    /// How many batches were applied and how many full fetches ran; for tests
    /// and the page probe. A batch applied from its own changes counts here
    /// but not in `fullFetchCount`.
    private(set) var refreshCount = 0
    /// How many times the whole library was fetched again from scratch. Only
    /// `refreshNow()` bumps it, so a test can tell an applied batch from a
    /// full fetch.
    private(set) var fullFetchCount = 0
    /// How many place-only saves refreshed just their changed places instead
    /// of fetching the whole place list; for tests and the page probe.
    private(set) var placeQuickRefreshCount = 0
    /// How many times the whole place list was fetched again (an insert or
    /// delete, a full fetch, or a save that named no place); for tests and the
    /// page probe.
    private(set) var placeListFetchCount = 0

    @ObservationIgnored private var context: ModelContext?
    /// Held here, not read from `context` on every save: a context does not
    /// keep its container alive.
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    /// Applies one big known batch's slices, with the main thread free
    /// between them. Nil when no slicing runs.
    @ObservationIgnored private var sliceTask: Task<Void, Never>?
    /// What the slices applied so far touched. The lists and `revision` are
    /// rebuilt once, after the last slice.
    @ObservationIgnored private var sliceTouched: Touched?
    /// Saves not applied yet, merged into one batch.
    @ObservationIgnored private var pendingChanges: SavedChanges?
    @ObservationIgnored private var firstPendingSave: Date?
    /// True while `pendingTask` will apply on the next main-actor turn because
    /// a person made the edit.
    @ObservationIgnored private var pendingImmediately = false

    /// Every photo the store knows: live and in Recently Deleted.
    @ObservationIgnored private var itemByPID: [PersistentIdentifier: MediaItem] = [:]
    /// Per-photo hash of everything pages group by, so one changed photo
    /// fixes the total without walking the library.
    @ObservationIgnored private var itemHash: [PersistentIdentifier: Int] = [:]
    @ObservationIgnored private var itemSum = 0
    /// The same per-photo hash without `updatedAt`: what a page actually
    /// groups by. A save that moved only `updatedAt` (a favorite, a rename)
    /// leaves this sum alone, which is how such a save skips the full bump.
    @ObservationIgnored private var layoutHash: [PersistentIdentifier: Int] = [:]
    @ObservationIgnored private var layoutSum = 0
    /// Sort keys kept beside each photo, so rebuilding a list never reads a
    /// SwiftData property inside a comparator.
    @ObservationIgnored private var itemKeys: [PersistentIdentifier: PhotoKeys] = [:]

    @ObservationIgnored private var faceByPID: [PersistentIdentifier: FaceObservation] = [:]
    @ObservationIgnored private var faceHash: [PersistentIdentifier: Int] = [:]
    @ObservationIgnored private var faceSum = 0
    /// Face string ids, so the list sorts by `id` without reading a model.
    @ObservationIgnored private var faceIDs: [PersistentIdentifier: String] = [:]

    @ObservationIgnored private var placeSum = 0
    /// Per-place hash, like `itemHash`: a place that changes fixes the total
    /// without every place being hashed again.
    @ObservationIgnored private var placeHash: [PersistentIdentifier: Int] = [:]
    /// The places of `places` by persistent id, kept in step with it, so a
    /// save can look up the few places it changed instead of the whole list.
    @ObservationIgnored private var placeByPID: [PersistentIdentifier: Place] = [:]
    /// What the last applied batch (or the last fetch) looked like;
    /// `revision` moves when one of these values differs.
    @ObservationIgnored private var applied: Measures?
    /// `layoutSum` at the moment `applied` was recorded. A save that changed
    /// nothing but `updatedAt` moves the full item sum and leaves this alone,
    /// which is what lets a favorite save skip the bump.
    @ObservationIgnored private var appliedLayoutSum = 0

    /// Quiet time after the last save before applying what changed.
    static let settleSeconds: TimeInterval = 0.25
    static let settleDelay: Duration = .milliseconds(250)
    /// While saves keep coming (an import), apply at least this often.
    static let maximumDelay: TimeInterval = 1
    /// A batch larger than this is applied with a full fetch instead, unless
    /// its identifiers are known: then it is applied in slices.
    static let maximumBatchSize = 5_000
    /// How many inserted and updated rows one slice applies.
    static let sliceSize = 1_000

    /// Call once with the main context, from the app's init.
    func start(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        self.container = context.container
        refreshNow()
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] notification in
            // Read what changed before leaving the notification's own thread.
            let changes = LibraryStore.changes(in: notification.userInfo)
            let savedContext = notification.object as? ModelContext
            MainActor.assumeIsolated {
                guard let self else { return }
                self.received(changes, from: savedContext)
            }
        }
    }

    /// Every context in the process posts `didSave`, including contexts of
    /// other containers (each test builds its own). Their identifiers name
    /// rows this store's context cannot read, and reading one is a crash,
    /// so only saves to this store's own container count.
    private func received(_ changes: SavedChanges, from savedContext: ModelContext?) {
        guard let context, let container else { return }
        // The sidebar reads groups, memberships, memories, tags and overrides
        // it is not told about by its own revisions, so any save that touched
        // one of them (or could not say what it touched) moves theirs.
        if changes.touchesGroupSources || !changes.isKnown {
            if savedContext == nil || savedContext?.container === container {
                groupSourcesRevision &+= 1
            }
        }
        // Autosave fires often with nothing this store lists.
        if changes.isKnown && changes.isEmpty { return }
        guard let savedContext else {
            // No context to check: fetch again from this store's own context.
            scheduleRefresh()
            return
        }
        guard savedContext.container === container else { return }
        saved(changes, fromOwnContext: savedContext === context)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        pendingTask?.cancel()
        sliceTask?.cancel()
    }

    /// Saves from any context (import, face scan, place names, bursts, edits)
    /// used to arrive here. Kept for callers that only know "something
    /// saved": that means a full fetch, coalesced as before.
    func scheduleRefresh() {
        mergePending(SavedChanges())
        scheduleSettledApply(own: false)
    }

    /// Fetches everything again and refills every map, hash and sum from
    /// scratch. Called at start and when a save could not say what changed.
    func refreshNow() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingImmediately = false
        pendingChanges = nil
        firstPendingSave = nil
        // A full fetch covers everything the slices would have applied.
        sliceTask?.cancel()
        sliceTask = nil
        sliceTouched = nil
        guard let context else { return }

        // A typed descriptor and a typed result per fetch: the CI compilers
        // time out on a long one-line `fetch(FetchDescriptor(…))`.
        let liveDescriptor = FetchDescriptor<MediaItem>(
            predicate: #Predicate<MediaItem> { $0.deletedAt == nil }
        )
        let live: [MediaItem] = (try? context.fetch(liveDescriptor)) ?? []
        let deletedDescriptor = FetchDescriptor<MediaItem>(
            predicate: #Predicate<MediaItem> { $0.deletedAt != nil }
        )
        let deleted: [MediaItem] = (try? context.fetch(deletedDescriptor)) ?? []
        let facesDescriptor = FetchDescriptor<FaceObservation>()
        let allFaces: [FaceObservation] = (try? context.fetch(facesDescriptor)) ?? []

        itemByPID = [:]
        itemHash = [:]
        layoutHash = [:]
        itemKeys = [:]
        itemSum = 0
        layoutSum = 0
        for item in live + deleted {
            let id = item.persistentModelID
            let hash = Self.hash(of: item)
            let layout = Self.layoutHash(of: item)
            itemByPID[id] = item
            itemHash[id] = hash
            layoutHash[id] = layout
            itemKeys[id] = PhotoKeys(item: item)
            itemSum &+= hash
            layoutSum &+= layout
        }

        faceByPID = [:]
        faceHash = [:]
        faceIDs = [:]
        faceSum = 0
        for face in allFaces {
            let id = face.persistentModelID
            let hash = Self.hash(of: face)
            faceByPID[id] = face
            faceIDs[id] = face.id
            faceHash[id] = hash
            faceSum &+= hash
        }

        rebuildPhotos()
        rebuildFaces()
        refetchPlaces()
        refreshCount += 1
        fullFetchCount += 1
        // A full fetch reads every favorite too, so pages that filter by
        // favorites are told to look again, whatever `revision` did.
        favoriteRevision &+= 1
        bumpRevisionIfNeeded()
    }

    // MARK: - Reading a save

    /// The identifiers one `didSave` notification lists. Keys are
    /// `ModelContext.NotificationKey` values; their names say whether the
    /// identifiers were inserted, updated or deleted.
    nonisolated static func changes(in userInfo: [AnyHashable: Any]?) -> SavedChanges {
        var changes = SavedChanges()
        var invalidatedAll = false
        for (key, value) in userInfo ?? [:] {
            let name = String(describing: key).lowercased()
            if name.contains("invalidat") { invalidatedAll = true; continue }
            guard name.contains("insert") || name.contains("delete") || name.contains("update") else { continue }
            let ids: [PersistentIdentifier]
            if let array = value as? [PersistentIdentifier] { ids = array }
            else if let set = value as? Set<PersistentIdentifier> { ids = Array(set) }
            else { continue }
            // Before the filter: a membership, memory, tag, override or group
            // is not listed by the store, yet the sidebar counts it.
            if ids.contains(where: { groupSourceEntityNames.contains($0.entityName) }) {
                changes.touchesGroupSources = true
            }
            let tracked = ids.filter { trackedEntityNames.contains($0.entityName) }
            if name.contains("insert") { changes.inserted += tracked; changes.isKnown = true }
            else if name.contains("delete") { changes.deleted += tracked; changes.isKnown = true }
            else { changes.updated += tracked; changes.isKnown = true }
        }
        // "Every identifier changed" cannot be applied as a list of changes.
        if invalidatedAll { changes.isKnown = false }
        return changes
    }

    private func saved(_ changes: SavedChanges, fromOwnContext own: Bool) {
        // A save of something the store does not list changes nothing here.
        // (Autosave fires often with nothing changed.)
        if changes.isKnown && changes.isEmpty { return }
        mergePending(changes)
        scheduleSettledApply(own: own)
    }

    private func mergePending(_ changes: SavedChanges) {
        if var pending = pendingChanges {
            pending.merge(changes)
            pendingChanges = pending
        } else {
            pendingChanges = changes
        }
    }

    /// A person's edit (`own`) is applied on the next main-actor turn, so a
    /// run of saves in one turn still becomes one batch. Another context's
    /// saves wait for the quiet time, but never longer than `maximumDelay`.
    private func scheduleSettledApply(own: Bool) {
        // An immediate apply already waiting does this work sooner, so a
        // background save arriving right after an edit joins it.
        if !own && pendingImmediately && pendingTask != nil { return }
        let now = Date()
        if firstPendingSave == nil { firstPendingSave = now }
        let deadline = (firstPendingSave ?? now).addingTimeInterval(Self.maximumDelay)
        pendingTask?.cancel()
        pendingImmediately = own
        pendingTask = Task { [weak self] in
            if own {
                await Task.yield()
            } else {
                let wait = min(Self.settleSeconds, max(0, deadline.timeIntervalSince(now)))
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            }
            guard !Task.isCancelled else { return }
            self?.applyPending()
        }
    }

    private func applyPending() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingImmediately = false
        firstPendingSave = nil
        // A running slice task applies its own batch. Saves that arrived
        // meanwhile stay pending and are applied right after the last slice.
        if sliceTask != nil { return }
        guard let changes = pendingChanges else { return }
        pendingChanges = nil
        guard changes.isKnown else {
            // The notification could not say what changed: fetch everything.
            refreshNow()
            return
        }
        if changes.identifierCount > Self.maximumBatchSize {
            applyInSlices(changes)
            return
        }
        apply(changes)
    }

    /// A known batch too big for one apply becomes slices: the first holds
    /// every deletion, the rest at most `sliceSize` inserted and updated rows
    /// each. The main thread is free between slices, so a first import draws
    /// frames instead of freezing for seconds; the lists and `revision` are
    /// rebuilt once, after the last slice.
    private func applyInSlices(_ changes: SavedChanges) {
        var removed = Set<PersistentIdentifier>()
        removed.reserveCapacity(changes.deleted.count)
        var deleted: [PersistentIdentifier] = []
        deleted.reserveCapacity(changes.deleted.count)
        for id in changes.deleted where removed.insert(id).inserted {
            deleted.append(id)
        }

        var slices: [SavedChanges] = []
        if !deleted.isEmpty {
            var slice = SavedChanges()
            slice.deleted = deleted
            slice.isKnown = true
            slices.append(slice)
        }
        // A row deleted in this same batch is never read, so it is left out
        // of the slices that carry inserted and updated rows.
        let inserted: [PersistentIdentifier] = changes.inserted.filter { !removed.contains($0) }
        let updated: [PersistentIdentifier] = changes.updated.filter { !removed.contains($0) }
        let insertedChunks: [[PersistentIdentifier]] = inserted.chunked(every: Self.sliceSize)
        let updatedChunks: [[PersistentIdentifier]] = updated.chunked(every: Self.sliceSize)
        slices.reserveCapacity(slices.count + insertedChunks.count + updatedChunks.count)
        for chunk in insertedChunks {
            var slice = SavedChanges()
            slice.inserted = chunk
            slice.isKnown = true
            slices.append(slice)
        }
        for chunk in updatedChunks {
            var slice = SavedChanges()
            slice.updated = chunk
            slice.isKnown = true
            slices.append(slice)
        }
        guard !slices.isEmpty else { return }

        sliceTask = Task { [weak self] in
            guard let self else { return }
            for (index, slice) in slices.enumerated() {
                if Task.isCancelled { return }
                let isLastSlice: Bool = index == slices.count - 1
                let current: SavedChanges = self.sliceAfterRemovals(slice)
                self.apply(current, finish: isLastSlice)
                guard !isLastSlice else { break }
                // Let the run loop draw a frame between slices.
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard !Task.isCancelled else { return }
            self.sliceTask = nil
            if self.pendingChanges != nil { self.applyPending() }
        }
    }

    /// The slice without any id another save deleted meanwhile: a row that is
    /// gone from the store must never be read.
    private func sliceAfterRemovals(_ slice: SavedChanges) -> SavedChanges {
        guard let deleted = pendingChanges?.deleted, !deleted.isEmpty else { return slice }
        let gone = Set(deleted)
        var result = slice
        result.inserted = slice.inserted.filter { !gone.contains($0) }
        result.updated = slice.updated.filter { !gone.contains($0) }
        result.isKnown = true
        return result
    }

    // MARK: - Applying a batch

    /// Which public list or signature a batch touched.
    private struct Touched {
        var photoLists = false
        var faces = false
        var places = false
        /// Every place has to be hashed again: a deleted override cannot say
        /// which place it was on.
        var allPlaces = false
        /// A place was inserted or deleted, so the list itself has to be
        /// fetched again. A place that was only renamed keeps the list.
        var placeListChanged = false
        /// The places that changed themselves (inserted or updated).
        var changedPlacePIDs: Set<PersistentIdentifier> = []
        /// The places named by a changed place-wide override, by string id.
        var changedPlaceIDs: Set<String> = []
        /// A `Favorite` row was among the batch's rows. Carried across the
        /// slices of one batch: only the last slice reaches the revision rule,
        /// and a big batch's favorite row may sit in an earlier slice.
        var hadFavoriteRow = false
        /// A row of any other listed entity (faces, places, overrides) was
        /// among them. Also carried across slices, for the same reason.
        var hadOtherEntityRow = false

        /// Everything one slice touched added to everything the slices
        /// before it did. Flags are OR'd, sets are unioned.
        mutating func merge(_ other: Touched) {
            photoLists = photoLists || other.photoLists
            faces = faces || other.faces
            places = places || other.places
            allPlaces = allPlaces || other.allPlaces
            placeListChanged = placeListChanged || other.placeListChanged
            changedPlacePIDs.formUnion(other.changedPlacePIDs)
            changedPlaceIDs.formUnion(other.changedPlaceIDs)
            hadFavoriteRow = hadFavoriteRow || other.hadFavoriteRow
            hadOtherEntityRow = hadOtherEntityRow || other.hadOtherEntityRow
        }
    }

    /// Applies one batch's changes. With `finish` false (one slice of a big
    /// batch) what it touched is kept in `sliceTouched` and the public lists,
    /// `refreshCount` and `revision` wait for the last slice.
    private func apply(_ changes: SavedChanges, finish: Bool = true) {
        guard let context else { return }
        var touched = Touched()
        // What earlier slices of this batch touched joins this slice's; the
        // last slice rebuilds the lists and bumps `revision` once for all.
        if let earlier = sliceTouched {
            touched.merge(earlier)
            sliceTouched = nil
        }

        // A favorite alone changes what the Favorites filter and the sidebar
        // smart groups show, not how a page groups its photos; the batch's
        // own contents decide whether `revision` has to move at all. The flags
        // are set on `touched`, which already carries the earlier slices', so
        // the last slice judges the whole batch.
        let mediaEntityName = String(describing: MediaItem.self)
        let favoriteEntityName = String(describing: Favorite.self)
        for id in changes.inserted + changes.updated + changes.deleted {
            if id.entityName == favoriteEntityName {
                touched.hadFavoriteRow = true
            } else if id.entityName != mediaEntityName {
                touched.hadOtherEntityRow = true
            }
        }

        // Removals first: a model that is gone from the store must never be
        // read (SwiftData traps on the invalidated instance), and a save
        // lists a removed row as deleted, not as updated.
        var removed = Set<PersistentIdentifier>()
        removed.reserveCapacity(changes.deleted.count)
        for id in changes.deleted where removed.insert(id).inserted {
            switch id.entityName {
            case String(describing: MediaItem.self):
                removePhoto(id, touched: &touched)
            case String(describing: FaceObservation.self):
                removeFace(id, touched: &touched)
            case String(describing: Place.self):
                // A removed place leaves the list; the refetch below drops its
                // hash and sum.
                touched.places = true
                touched.placeListChanged = true
            case String(describing: PlaceOverride.self):
                // A removed override may have been a place-wide rename, and it
                // no longer says which place that was: hash every place.
                touched.places = true
                touched.allPlaces = true
            default:
                break
            }
        }

        // Only ids whose row still exists may be refreshed. A deleted id is
        // never handed to `model(for:)` and never read, so a photo that another
        // context removed in this same batch cannot come back.
        var updatedIDs: [PersistentIdentifier] = []
        updatedIDs.reserveCapacity(changes.inserted.count + changes.updated.count)
        for id in changes.inserted + changes.updated where !removed.contains(id) {
            updatedIDs.append(id)
        }

        // A place this batch inserted gains the list a row, so the list itself
        // has to be fetched again. Inserted and updated ids share the loop
        // below, so the inserted place ids are collected first.
        let placeEntityName = String(describing: Place.self)
        var insertedPlaces = Set<PersistentIdentifier>()
        insertedPlaces.reserveCapacity(changes.inserted.count)
        for id in changes.inserted where id.entityName == placeEntityName {
            insertedPlaces.insert(id)
        }

        // `model(for:)` hands back a model this context already holds, with the
        // values it read before another context saved. A small fetch by
        // identifier both refreshes those values and leaves the same object
        // in place, so the lists can keep their elements.
        let photos = refreshedPhotoModels(for: updatedIDs, in: context)
        // Favorites and overrides name their photo by string id; most of
        // those photos are in this batch (setFavorite and a rename touch the
        // photo too), so they are found here instead of by one fetch each.
        var photosByID: [String: MediaItem] = [:]
        photosByID.reserveCapacity(photos.count)
        for model in photos.values { photosByID[model.id] = model }
        let faces = refreshedFaceModels(for: updatedIDs, in: context)
        let favorites = favoriteModels(for: updatedIDs, in: context)
        let overrides = placeOverrideModels(for: updatedIDs, in: context)

        var seen = Set<PersistentIdentifier>()
        seen.reserveCapacity(updatedIDs.count)
        for id in updatedIDs {
            guard !removed.contains(id), seen.insert(id).inserted else { continue }
            switch id.entityName {
            case String(describing: MediaItem.self):
                guard let model = photos[id] else { removePhoto(id, touched: &touched); continue }
                upsertPhoto(id, model: model, touched: &touched)
            case String(describing: FaceObservation.self):
                guard let model = faces[id] else { removeFace(id, touched: &touched); continue }
                upsertFace(id, model: model, touched: &touched)
            case String(describing: Favorite.self):
                applyFavoriteChange(
                    id,
                    favorite: favorites[id],
                    photos: photos,
                    photosByID: photosByID,
                    removed: removed,
                    context: context,
                    touched: &touched
                )
            case String(describing: PlaceOverride.self):
                applyPlaceOverrideChange(
                    id,
                    override: overrides[id],
                    photos: photos,
                    photosByID: photosByID,
                    removed: removed,
                    context: context,
                    touched: &touched
                )
            case String(describing: Place.self):
                touched.places = true
                touched.changedPlacePIDs.insert(id)
                if insertedPlaces.contains(id) { touched.placeListChanged = true }
            default:
                break
            }
        }

        // A slice keeps what it touched for the last slice, which rebuilds
        // the lists and bumps `revision` once, for every slice together.
        guard finish else {
            sliceTouched = touched
            return
        }

        // The place list is a few thousand rows and must stay right, so any
        // place change refetches it; only the places a batch can have changed
        // are hashed again.
        if touched.places { refetchPlaces(rehash: touched) }
        if touched.photoLists { rebuildPhotos() }
        if touched.faces { rebuildFaces() }
        refreshCount += 1
        appliedRevisionRule(
            hadFavoriteRow: touched.hadFavoriteRow,
            hadOnlyPhotosAndFavorites: !touched.hadOtherEntityRow
        )
    }

    /// What one applied batch does to `revision` and `favoriteRevision`.
    ///
    /// A favorite is not something a page groups its photos by; only the
    /// Favorites filter and the sidebar smart groups read it. So a batch of
    /// favorites and their photos, whose layout did not move, must not make
    /// every page rebuild its groups. It still records the new measures, so
    /// the next batch compares against them.
    ///
    /// Only a batch that carries a `Favorite` row may take that path; every
    /// other save keeps the old rule, even one that moved only `updatedAt`.
    private func appliedRevisionRule(hadFavoriteRow: Bool, hadOnlyPhotosAndFavorites: Bool) {
        if hadFavoriteRow { favoriteRevision &+= 1 }
        guard hadFavoriteRow, hadOnlyPhotosAndFavorites, let previous = applied else {
            bumpRevisionIfNeeded()
            return
        }
        let next = measures
        let sameCounts = next.itemCount == previous.itemCount
            && next.faceCount == previous.faceCount
            && next.placeCount == previous.placeCount
        let sameFacesAndPlaces = next.faceSum == previous.faceSum
            && next.placeSum == previous.placeSum
        let sameLayout = layoutSum == appliedLayoutSum
        guard sameCounts, sameFacesAndPlaces, sameLayout else {
            bumpRevisionIfNeeded()
            return
        }
        // Only `updatedAt` (the full item sum) moved: nothing pages group or
        // filter their photos by changed, so `revision` stays. The batch's
        // new measures are recorded, so the next batch compares against them.
        applied = next
        appliedLayoutSum = layoutSum
    }

    private func upsertPhoto(_ id: PersistentIdentifier, model: MediaItem, touched: inout Touched) {
        if let old = itemHash[id] { itemSum &-= old }
        if let old = layoutHash[id] { layoutSum &-= old }
        let hash = Self.hash(of: model)
        let layout = Self.layoutHash(of: model)
        itemHash[id] = hash
        layoutHash[id] = layout
        itemSum &+= hash
        layoutSum &+= layout

        let existed = itemByPID[id] != nil
        itemByPID[id] = model
        let keys = PhotoKeys(item: model)
        if itemKeys[id] != keys {
            itemKeys[id] = keys
            // New photo, restored or trashed, screenshot flag or date moved.
            touched.photoLists = true
        }
        if !existed { touched.photoLists = true }
    }

    private func removePhoto(_ id: PersistentIdentifier, touched: inout Touched) {
        if let old = itemHash.removeValue(forKey: id) { itemSum &-= old }
        if let old = layoutHash.removeValue(forKey: id) { layoutSum &-= old }
        itemKeys[id] = nil
        if itemByPID.removeValue(forKey: id) != nil { touched.photoLists = true }
    }

    private func upsertFace(_ id: PersistentIdentifier, model: FaceObservation, touched: inout Touched) {
        if let old = faceHash[id] { faceSum &-= old }
        let hash = Self.hash(of: model)
        faceHash[id] = hash
        faceSum &+= hash
        let existed = faceByPID[id] != nil
        faceByPID[id] = model
        faceIDs[id] = model.id
        if !existed { touched.faces = true }
    }

    private func removeFace(_ id: PersistentIdentifier, touched: inout Touched) {
        if let old = faceHash.removeValue(forKey: id) { faceSum &-= old }
        faceIDs[id] = nil
        if faceByPID.removeValue(forKey: id) != nil { touched.faces = true }
    }

    private func applyFavoriteChange(
        _ id: PersistentIdentifier,
        favorite: Favorite?,
        photos: [PersistentIdentifier: MediaItem],
        photosByID: [String: MediaItem],
        removed: Set<PersistentIdentifier>,
        context: ModelContext,
        touched: inout Touched
    ) {
        // A removed favorite needs nothing: `setFavorite` also changes the
        // photo's `updatedAt`, so the photo is in the same save.
        guard let favorite else { return }
        // The stored string id first: the relationship may point at a photo
        // this same save removed, and reading that is what brings a deleted
        // photo back (or traps).
        let mediaID = favorite.mediaID
        let linked = mediaID == nil ? favorite.mediaItem : nil
        if let linked, removed.contains(linked.persistentModelID) { return }
        guard let photo = photoModel(for: linked, mediaID: mediaID, photos: photos, photosByID: photosByID, context: context) else { return }
        guard !removed.contains(photo.persistentModelID) else { return }
        upsertPhoto(photo.persistentModelID, model: photo, touched: &touched)
    }

    private func applyPlaceOverrideChange(
        _ id: PersistentIdentifier,
        override: PlaceOverride?,
        photos: [PersistentIdentifier: MediaItem],
        photosByID: [String: MediaItem],
        removed: Set<PersistentIdentifier>,
        context: ModelContext,
        touched: inout Touched
    ) {
        guard let override else {
            // Its removal may have dropped a place-wide rename, and nothing
            // says which place it was on.
            touched.places = true
            touched.allPlaces = true
            return
        }
        // The stored ids first; a relationship may point at a photo this save
        // removed, and reading that is what brings a deleted photo back.
        let mediaID = override.mediaID
        let linked = mediaID == nil ? override.mediaItem : nil
        if let linked, removed.contains(linked.persistentModelID) { return }
        if mediaID != nil || linked != nil {
            // A photo's own place name: only that photo is affected.
            guard let photo = photoModel(for: linked, mediaID: mediaID, photos: photos, photosByID: photosByID, context: context) else { return }
            guard !removed.contains(photo.persistentModelID) else { return }
            upsertPhoto(photo.persistentModelID, model: photo, touched: &touched)
        } else {
            // A place-wide rename changes `Place.correctedName` of one place:
            // `override.place`, or the place whose `id` is `override.placeID`.
            touched.places = true
            if let pid = override.place?.persistentModelID {
                touched.changedPlacePIDs.insert(pid)
            } else if let placeID = override.placeID {
                touched.changedPlaceIDs.insert(placeID)
            } else {
                // Nothing says which place it was on.
                touched.allPlaces = true
            }
        }
    }

    /// The refreshed photo an override or favorite points at. The batch's own
    /// fetch is used first, so its values are the ones just saved.
    ///
    /// A fetch by string id that finds no row returns nil: the photo was
    /// removed, and a removed row must never be read or put back into
    /// `itemByPID`. Falling back to the model the store still holds would do
    /// exactly that.
    private func photoModel(
        for item: MediaItem?,
        mediaID: String?,
        photos: [PersistentIdentifier: MediaItem],
        photosByID: [String: MediaItem],
        context: ModelContext
    ) -> MediaItem? {
        if let item, let fresh = photos[item.persistentModelID] { return fresh }
        // A linked photo's id comes from what the store recorded, not from the
        // model: one removed in an earlier batch must not be read.
        let linkedID: String? = item.flatMap { itemKeys[$0.persistentModelID]?.id }
        guard let id = mediaID ?? linkedID else { return nil }
        if let fresh = photosByID[id] { return fresh }
        let descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate<MediaItem> { $0.id == id })
        let found: [MediaItem] = (try? context.fetch(descriptor)) ?? []
        return found.first
    }

    // MARK: - Reading the changed models

    /// How many ids one fetch asks for; a query with a few hundred string
    /// parameters stays well under a millisecond.
    private static let fetchChunkSize = 200

    /// Fetches just the photos a batch named, so their values are the ones
    /// the other context saved. `model(for:)` alone would hand back a model
    /// this context already holds with the values it read earlier.
    ///
    /// A photo this store has never seen is new: `model(for:)` has nothing
    /// stale to return for it and is used directly.
    ///
    /// `MediaItem.id` is not unique in the schema, so one string id can name
    /// several rows. The fetch asks once per distinct string id and then
    /// keeps each model under its own persistent id, so two photos that share
    /// an id keep their own models instead of one taking the other's.
    private func refreshedPhotoModels(for ids: [PersistentIdentifier], in context: ModelContext) -> [PersistentIdentifier: MediaItem] {
        var result: [PersistentIdentifier: MediaItem] = [:]
        var wantedIDs = Set<String>()
        var wantedPIDs = Set<PersistentIdentifier>()
        for id in ids where id.entityName == String(describing: MediaItem.self) {
            if let known = itemKeys[id]?.id ?? itemByPID[id]?.id {
                wantedIDs.insert(known)
                wantedPIDs.insert(id)
            } else if let model = context.model(for: id) as? MediaItem {
                result[id] = model
            }
        }
        guard !wantedIDs.isEmpty else { return result }
        result.reserveCapacity(result.count + wantedPIDs.count)
        for chunk in Array(wantedIDs).chunked(every: Self.fetchChunkSize) {
            let descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate<MediaItem> { chunk.contains($0.id) })
            let found: [MediaItem] = (try? context.fetch(descriptor)) ?? []
            for model in found where wantedPIDs.contains(model.persistentModelID) {
                result[model.persistentModelID] = model
            }
        }
        return result
    }

    private func refreshedFaceModels(for ids: [PersistentIdentifier], in context: ModelContext) -> [PersistentIdentifier: FaceObservation] {
        var result: [PersistentIdentifier: FaceObservation] = [:]
        var wantedIDs = Set<String>()
        var wantedPIDs = Set<PersistentIdentifier>()
        for id in ids where id.entityName == String(describing: FaceObservation.self) {
            if let known = faceIDs[id] {
                wantedIDs.insert(known)
                wantedPIDs.insert(id)
            } else if let model = context.model(for: id) as? FaceObservation {
                result[id] = model
            }
        }
        guard !wantedIDs.isEmpty else { return result }
        result.reserveCapacity(result.count + wantedPIDs.count)
        for chunk in Array(wantedIDs).chunked(every: Self.fetchChunkSize) {
            let descriptor = FetchDescriptor<FaceObservation>(predicate: #Predicate<FaceObservation> { chunk.contains($0.id) })
            let found: [FaceObservation] = (try? context.fetch(descriptor)) ?? []
            for model in found where wantedPIDs.contains(model.persistentModelID) {
                result[model.persistentModelID] = model
            }
        }
        return result
    }

    /// The store never keeps favorites or overrides, so nothing stale is
    /// held here for them; deleted ids were skipped before this point, so no
    /// invalidated object is read either.
    private func favoriteModels(for ids: [PersistentIdentifier], in context: ModelContext) -> [PersistentIdentifier: Favorite] {
        var result: [PersistentIdentifier: Favorite] = [:]
        for id in ids where id.entityName == String(describing: Favorite.self) {
            if let model = context.model(for: id) as? Favorite { result[id] = model }
        }
        return result
    }

    private func placeOverrideModels(for ids: [PersistentIdentifier], in context: ModelContext) -> [PersistentIdentifier: PlaceOverride] {
        var result: [PersistentIdentifier: PlaceOverride] = [:]
        for id in ids where id.entityName == String(describing: PlaceOverride.self) {
            if let model = context.model(for: id) as? PlaceOverride { result[id] = model }
        }
        return result
    }

    // MARK: - Rebuilding the public lists

    private struct PhotoKeys: Equatable {
        let id: String
        let captureDate: Date?
        let deletedAt: Date?
        let isScreenshot: Bool

        init(item: MediaItem) {
            id = item.id
            captureDate = item.captureDate
            deletedAt = item.deletedAt
            isScreenshot = item.isScreenshot
        }
    }

    private func rebuildPhotos() {
        var live: [(keys: PhotoKeys, item: MediaItem)] = []
        var gone: [(keys: PhotoKeys, item: MediaItem)] = []
        live.reserveCapacity(itemByPID.count)
        for (id, item) in itemByPID {
            guard let keys = itemKeys[id] else { continue }
            if keys.deletedAt == nil { live.append((keys, item)) } else { gone.append((keys, item)) }
        }
        // A nil capture date sorts first, as SwiftData sorts it today; the
        // string id breaks ties so the order never depends on storage order.
        live.sort { lhs, rhs in
            let left = lhs.keys.captureDate ?? .distantPast
            let right = rhs.keys.captureDate ?? .distantPast
            if left != right { return left < right }
            return lhs.keys.id < rhs.keys.id
        }
        gone.sort { lhs, rhs in
            let left = lhs.keys.deletedAt ?? .distantPast
            let right = rhs.keys.deletedAt ?? .distantPast
            if left != right { return left > right }
            return lhs.keys.id < rhs.keys.id
        }

        let liveItems = live.map(\.item)
        let regular = live.filter { !$0.keys.isScreenshot }.map(\.item)
        let screenshots = live.filter { $0.keys.isScreenshot }.map(\.item)
        let goneItems = gone.map(\.item)
        let byID = Dictionary(live.map { ($0.keys.id, $0.item) }, uniquingKeysWith: { first, _ in first })

        // Assign only when a list really differs, so an unchanged list never
        // notifies the views that read it.
        if !items.elementsEqual(liveItems, by: { $0 === $1 }) { items = liveItems }
        if !regularItems.elementsEqual(regular, by: { $0 === $1 }) { regularItems = regular }
        if !screenshotItems.elementsEqual(screenshots, by: { $0 === $1 }) { screenshotItems = screenshots }
        if !deletedItems.elementsEqual(goneItems, by: { $0 === $1 }) { deletedItems = goneItems }
        if byID.count != itemsByID.count || byID.contains(where: { itemsByID[$0.key] !== $0.value }) {
            itemsByID = byID
        }
    }

    /// Sorts by face string id, then persistent id. The keys are read into one
    /// array first; read from a comparator they would be looked up again on
    /// every comparison.
    private func rebuildFaces() {
        var keyed: [(id: String, pid: PersistentIdentifier, face: FaceObservation)] = []
        keyed.reserveCapacity(faceByPID.count)
        for (pid, face) in faceByPID {
            keyed.append((id: faceIDs[pid] ?? "", pid: pid, face: face))
        }
        keyed.sort { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            return lhs.pid < rhs.pid
        }
        let sorted = keyed.map(\.face)
        if !faces.elementsEqual(sorted, by: { $0 === $1 }) { faces = sorted }
    }

    /// Refetches the place list itself (a few thousand rows, sorted by id) and
    /// keeps `placeHash`/`placeSum` incremental. With `rehash` given, only the
    /// places the applied batch can have changed are hashed again; without it
    /// (a full refresh) every place is.
    ///
    /// A save that only renamed places the store already lists takes the quick
    /// path: no place was inserted or deleted, so the list itself cannot have
    /// changed, and only the changed places are fetched by id and hashed again.
    private func refetchPlaces(rehash touched: Touched? = nil) {
        guard let context else { return }
        if let touched, canRefreshOnlyChangedPlaces(touched) {
            refreshOnlyChangedPlaces(touched, in: context)
            return
        }
        let descriptor = FetchDescriptor<Place>(sortBy: [SortDescriptor(\Place.id)])
        let next: [Place] = (try? context.fetch(descriptor)) ?? []
        placeListFetchCount += 1
        if !places.elementsEqual(next, by: { $0 === $1 }) { places = next }
        var byPID: [PersistentIdentifier: Place] = [:]
        byPID.reserveCapacity(next.count)
        for place in next { byPID[place.persistentModelID] = place }
        placeByPID = byPID

        var known = Set<PersistentIdentifier>()
        known.reserveCapacity(next.count)
        for place in next { known.insert(place.persistentModelID) }
        // A place that left the list leaves the hash and the sum, so a removed
        // place still moves the signature.
        for pid in placeHash.keys where !known.contains(pid) {
            if let old = placeHash.removeValue(forKey: pid) { placeSum &-= old }
        }

        if let touched {
            guard touched.places else { return }
            // A deleted place is already gone from `next` above; with no
            // place named and no override removed there is nothing to rehash.
            let rehashAll = touched.allPlaces
            for place in next {
                let pid = place.persistentModelID
                if !rehashAll,
                   !touched.changedPlacePIDs.contains(pid),
                   !touched.changedPlaceIDs.contains(place.id) { continue }
                if let old = placeHash[pid] { placeSum &-= old }
                let hash = Self.hash(of: place)
                placeHash[pid] = hash
                placeSum &+= hash
            }
        } else {
            placeHash = [:]
            placeSum = 0
            for place in next {
                let hash = Self.hash(of: place)
                placeHash[place.persistentModelID] = hash
                placeSum &+= hash
            }
        }
    }

    /// True when a batch changed only places the store already lists: no place
    /// was inserted or deleted (so the list itself cannot have changed), no
    /// place has to be hashed again because an override went away, and every
    /// changed place is in `placeByPID`.
    private func canRefreshOnlyChangedPlaces(_ touched: Touched) -> Bool {
        guard touched.places, !touched.placeListChanged, !touched.allPlaces else { return false }
        for pid in touched.changedPlacePIDs where placeByPID[pid] == nil { return false }
        return true
    }

    /// The quick path: fetches just the changed places themselves and the
    /// places a changed place-wide override named, by string id, in chunks of
    /// `fetchChunkSize`. The fetch refreshes
    /// the values of the objects the store already holds, so `places` is not
    /// reassigned and only those places are hashed again. A named place that
    /// is not found is skipped, as the full path also only rehashes places it
    /// has.
    private func refreshOnlyChangedPlaces(_ touched: Touched, in context: ModelContext) {
        placeQuickRefreshCount += 1
        let changedIDs: [String] = touched.changedPlacePIDs.compactMap { (pid: PersistentIdentifier) -> String? in
            placeByPID[pid]?.id
        }
        var wantedIDs = Set(changedIDs)
        wantedIDs.formUnion(touched.changedPlaceIDs)
        guard !wantedIDs.isEmpty else { return }
        for chunk in Array(wantedIDs).chunked(every: Self.fetchChunkSize) {
            let descriptor = FetchDescriptor<Place>(predicate: #Predicate<Place> { chunk.contains($0.id) })
            let found: [Place] = (try? context.fetch(descriptor)) ?? []
            for place in found {
                let pid = place.persistentModelID
                guard placeHash[pid] != nil || placeByPID[pid] != nil else { continue }
                if let old = placeHash[pid] { placeSum &-= old }
                let hash = Self.hash(of: place)
                placeHash[pid] = hash
                placeSum &+= hash
                // The list holds this same object, so its values are the ones
                // just fetched; keeping the map in step costs nothing.
                placeByPID[pid] = place
            }
        }
    }

    // MARK: - Revision

    /// The per-list sums and counts `revision` is computed from. Not private:
    /// tests compare two stores' signatures, because `revision` values cannot
    /// be compared across stores (each counts its own bumps).
    struct Measures: Equatable {
        var itemSum = 0
        var itemCount = 0
        var faceSum = 0
        var faceCount = 0
        var placeSum = 0
        var placeCount = 0
    }

    /// The signature the store reports right now. The only reader outside the
    /// store is the test suite.
    var measures: Measures {
        Measures(
            itemSum: itemSum,
            itemCount: itemByPID.count,
            faceSum: faceSum,
            faceCount: faceByPID.count,
            placeSum: placeSum,
            placeCount: places.count
        )
    }

    private func bumpRevisionIfNeeded() {
        let next = measures
        let layout = layoutSum
        if next != applied {
            #if DEBUG
            let parts: [String] = Self.revisionParts(
                next: next,
                applied: applied,
                layout: layout,
                appliedLayout: appliedLayoutSum
            )
            PageProbe.tally("store revision: " + parts.joined(separator: " + "))
            #endif
            let previous: Measures? = applied
            let photosMoved: Bool = next.itemSum != previous?.itemSum || next.itemCount != previous?.itemCount
            let facesMoved: Bool = next.faceSum != previous?.faceSum || next.faceCount != previous?.faceCount
            let placesMoved: Bool = next.placeSum != previous?.placeSum || next.placeCount != previous?.placeCount
            if previous == nil || photosMoved || facesMoved { photoFaceRevision &+= 1 }
            if previous == nil || placesMoved { placeRevision &+= 1 }
            applied = next
            revision &+= 1
        }
        // Kept beside `applied`: a batch that only moved `updatedAt` records
        // its measures without a bump, and the next batch must compare
        // against that same layout sum.
        appliedLayoutSum = layout
    }

    #if DEBUG
    /// Debug-only: which inputs of the store's signature moved compared with
    /// the last applied one, for the page probe's tally.
    private static func revisionParts(
        next: Measures,
        applied: Measures?,
        layout: Int,
        appliedLayout: Int
    ) -> [String] {
        guard let applied else { return ["first"] }
        var parts: [String] = []
        let photoLayoutMoved: Bool = layout != appliedLayout
        let photoFieldsMoved: Bool = next.itemSum != applied.itemSum
        let photoCountMoved: Bool = next.itemCount != applied.itemCount
        let facesMoved: Bool = next.faceSum != applied.faceSum || next.faceCount != applied.faceCount
        let placesMoved: Bool = next.placeSum != applied.placeSum || next.placeCount != applied.placeCount
        if photoLayoutMoved { parts.append("photo layout") }
        if photoFieldsMoved && !photoLayoutMoved { parts.append("photo other fields") }
        if photoCountMoved { parts.append("photo count") }
        if facesMoved { parts.append("faces") }
        if placesMoved { parts.append("places") }
        return parts
    }

    #endif
    // MARK: - Per-object hashes

    /// Everything pages group or filter by for one photo. `isFavorite` is
    /// left out on purpose: it walks a relation for every photo, and
    /// `setFavorite` already changes `updatedAt`.
    private static func hash(of item: MediaItem) -> Int {
        var hasher = Hasher()
        hasher.combine(item.id)
        hasher.combine(item.effectiveCaptureDate)
        hasher.combine(item.localDayKey)
        hasher.combine(item.latitude)
        hasher.combine(item.longitude)
        hasher.combine(item.tripID)
        hasher.combine(item.place?.id)
        hasher.combine(item.kindRaw)
        hasher.combine(item.isScreenshot)
        hasher.combine(item.updatedAt)
        hasher.combine(item.deletedAt)
        return hasher.finalize()
    }

    /// The same fields as `hash(of:)` without `updatedAt`: the layout a page
    /// groups by, and nothing that a favorite or a rename moves.
    private static func layoutHash(of item: MediaItem) -> Int {
        var hasher = Hasher()
        hasher.combine(item.id)
        hasher.combine(item.effectiveCaptureDate)
        hasher.combine(item.localDayKey)
        hasher.combine(item.latitude)
        hasher.combine(item.longitude)
        hasher.combine(item.tripID)
        hasher.combine(item.place?.id)
        hasher.combine(item.kindRaw)
        hasher.combine(item.isScreenshot)
        hasher.combine(item.deletedAt)
        return hasher.finalize()
    }

    private static func hash(of face: FaceObservation) -> Int {
        var hasher = Hasher()
        hasher.combine(face.id)
        hasher.combine(face.mediaID)
        hasher.combine(face.personID)
        hasher.combine(face.clusterID)
        hasher.combine(face.confirmed)
        hasher.combine(face.assignmentSource)
        return hasher.finalize()
    }

    private static func hash(of place: Place) -> Int {
        var hasher = Hasher()
        hasher.combine(place.id)
        hasher.combine(place.name)
        hasher.combine(place.correctedName)
        hasher.combine(place.latitude)
        hasher.combine(place.longitude)
        hasher.combine(place.parent?.id)
        hasher.combine(place.updatedAt)
        return hasher.finalize()
    }
}

private extension Array {
    func chunked(every size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [self] }
        var chunks: [[Element]] = []
        chunks.reserveCapacity((count + size - 1) / size)
        var start = 0
        while start < count {
            chunks.append(Array(self[start..<Swift.min(start + size, count)]))
            start += size
        }
        return chunks
    }
}

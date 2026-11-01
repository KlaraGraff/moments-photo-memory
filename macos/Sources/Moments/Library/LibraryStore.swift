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

    var isEmpty: Bool { inserted.isEmpty && updated.isEmpty && deleted.isEmpty }
    var identifierCount: Int { inserted.count + updated.count + deleted.count }

    /// One save's changes added to another's. A merged batch is only known
    /// when every save in it was.
    mutating func merge(_ other: SavedChanges) {
        inserted += other.inserted
        updated += other.updated
        deleted += other.deleted
        isKnown = isKnown && other.isKnown
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
    /// How many batches were applied and how many full fetches ran; for tests
    /// and the page probe.
    private(set) var refreshCount = 0

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
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
    /// Sort keys kept beside each photo, so rebuilding a list never reads a
    /// SwiftData property inside a comparator.
    @ObservationIgnored private var itemKeys: [PersistentIdentifier: PhotoKeys] = [:]

    @ObservationIgnored private var faceByPID: [PersistentIdentifier: FaceObservation] = [:]
    @ObservationIgnored private var faceHash: [PersistentIdentifier: Int] = [:]
    @ObservationIgnored private var faceSum = 0
    /// Face string ids, so the list sorts by `id` without reading a model.
    @ObservationIgnored private var faceIDs: [PersistentIdentifier: String] = [:]

    @ObservationIgnored private var placeSum = 0
    /// What the last applied batch (or the last fetch) looked like;
    /// `revision` moves when one of these values differs.
    @ObservationIgnored private var applied: Measures?

    /// Quiet time after the last save before applying what changed.
    static let settleSeconds: TimeInterval = 0.25
    static let settleDelay: Duration = .milliseconds(250)
    /// While saves keep coming (an import), apply at least this often.
    static let maximumDelay: TimeInterval = 1
    /// A batch larger than this is applied with a full fetch instead.
    static let maximumBatchSize = 5_000

    /// Call once with the main context, from the app's init.
    func start(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
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
        guard let context else { return }
        guard let savedContext else {
            // No context to check: fetch again from this store's own context.
            scheduleRefresh()
            return
        }
        guard savedContext.container === context.container else { return }
        saved(changes, fromOwnContext: savedContext === context)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        pendingTask?.cancel()
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
        guard let context else { return }

        let live = (try? context.fetch(FetchDescriptor<MediaItem>(
            predicate: #Predicate { $0.deletedAt == nil }
        ))) ?? []
        let deleted = (try? context.fetch(FetchDescriptor<MediaItem>(
            predicate: #Predicate { $0.deletedAt != nil }
        ))) ?? []
        let allFaces = (try? context.fetch(FetchDescriptor<FaceObservation>())) ?? []

        itemByPID = [:]
        itemHash = [:]
        itemKeys = [:]
        itemSum = 0
        for item in live + deleted {
            let id = item.persistentModelID
            let hash = Self.hash(of: item)
            itemByPID[id] = item
            itemHash[id] = hash
            itemKeys[id] = PhotoKeys(item: item)
            itemSum &+= hash
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
        guard let changes = pendingChanges else { return }
        pendingChanges = nil
        guard changes.isKnown, changes.identifierCount <= Self.maximumBatchSize else {
            // The notification could not say what changed, or too much did.
            refreshNow()
            return
        }
        apply(changes)
    }

    // MARK: - Applying a batch

    /// Which public list or signature a batch touched.
    private struct Touched {
        var photoLists = false
        var faces = false
        var places = false
    }

    private func apply(_ changes: SavedChanges) {
        guard let context else { return }
        var touched = Touched()

        // `model(for:)` hands back a model this context already holds, with the
        // values it read before another context saved. A small fetch by
        // identifier both refreshes those values and leaves the same object
        // in place, so the lists can keep their elements.
        let updatedIDs = changes.inserted + changes.updated
        let photos = refreshedPhotoModels(for: updatedIDs, in: context)
        let faces = refreshedFaceModels(for: updatedIDs, in: context)
        let favorites = favoriteModels(for: updatedIDs, in: context)
        let overrides = placeOverrideModels(for: updatedIDs, in: context)

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
            case String(describing: Place.self), String(describing: PlaceOverride.self):
                // A removed place override changes what a place is called.
                touched.places = true
            default:
                break
            }
        }

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
                applyFavoriteChange(id, favorite: favorites[id], photos: photos, context: context, touched: &touched)
            case String(describing: PlaceOverride.self):
                applyPlaceOverrideChange(id, override: overrides[id], photos: photos, context: context, touched: &touched)
            case String(describing: Place.self):
                touched.places = true
            default:
                break
            }
        }

        // Places are few and change rarely, so they stay a full fetch.
        if touched.places { refetchPlaces() }
        if touched.photoLists { rebuildPhotos() }
        if touched.faces { rebuildFaces() }
        refreshCount += 1
        bumpRevisionIfNeeded()
    }

    private func upsertPhoto(_ id: PersistentIdentifier, model: MediaItem, touched: inout Touched) {
        if let old = itemHash[id] { itemSum &-= old }
        let hash = Self.hash(of: model)
        itemHash[id] = hash
        itemSum &+= hash

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
        context: ModelContext,
        touched: inout Touched
    ) {
        // A removed favorite needs nothing: `setFavorite` also changes the
        // photo's `updatedAt`, so the photo is in the same save.
        guard let favorite else { return }
        guard let photo = photoModel(for: favorite.mediaItem, mediaID: favorite.mediaID, photos: photos, context: context) else { return }
        upsertPhoto(photo.persistentModelID, model: photo, touched: &touched)
    }

    private func applyPlaceOverrideChange(
        _ id: PersistentIdentifier,
        override: PlaceOverride?,
        photos: [PersistentIdentifier: MediaItem],
        context: ModelContext,
        touched: inout Touched
    ) {
        guard let override else {
            // Its removal may have dropped a place-wide rename.
            touched.places = true
            return
        }
        if override.mediaItem != nil || override.mediaID != nil {
            // A photo's own place name: only that photo is affected.
            guard let photo = photoModel(for: override.mediaItem, mediaID: override.mediaID, photos: photos, context: context) else { return }
            upsertPhoto(photo.persistentModelID, model: photo, touched: &touched)
        } else {
            // A place-wide rename changes `Place.correctedName`.
            touched.places = true
        }
    }

    /// The refreshed photo an override or favorite points at. The batch's own
    /// fetch is used first, so its values are the ones just saved.
    private func photoModel(
        for item: MediaItem?,
        mediaID: String?,
        photos: [PersistentIdentifier: MediaItem],
        context: ModelContext
    ) -> MediaItem? {
        if let item, let fresh = photos[item.persistentModelID] { return fresh }
        guard let id = mediaID ?? item?.id else { return nil }
        // The photo is not part of this batch's fetch: fetch it once so its
        // values are the ones just saved, and fall back to what the store
        // already holds only when the row is gone.
        if let found = try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.id == id })).first {
            return found
        }
        if let known = mediaItem(withID: id) { return photos[known.persistentModelID] ?? known }
        return nil
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
    private func refreshedPhotoModels(for ids: [PersistentIdentifier], in context: ModelContext) -> [PersistentIdentifier: MediaItem] {
        var result: [PersistentIdentifier: MediaItem] = [:]
        var wanted: [String] = []
        var byID: [String: PersistentIdentifier] = [:]
        for id in ids where id.entityName == String(describing: MediaItem.self) {
            if let known = itemKeys[id]?.id ?? itemByPID[id]?.id {
                wanted.append(known)
                byID[known] = id
            } else if let model = context.model(for: id) as? MediaItem {
                result[id] = model
            }
        }
        guard !wanted.isEmpty else { return result }
        result.reserveCapacity(result.count + wanted.count)
        for chunk in wanted.chunked(every: Self.fetchChunkSize) {
            let found = (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { chunk.contains($0.id) }))) ?? []
            for model in found {
                if let pid = byID[model.id] { result[pid] = model }
            }
        }
        return result
    }

    private func refreshedFaceModels(for ids: [PersistentIdentifier], in context: ModelContext) -> [PersistentIdentifier: FaceObservation] {
        var result: [PersistentIdentifier: FaceObservation] = [:]
        var wanted: [String] = []
        var byID: [String: PersistentIdentifier] = [:]
        for id in ids where id.entityName == String(describing: FaceObservation.self) {
            if let known = faceIDs[id] {
                wanted.append(known)
                byID[known] = id
            } else if let model = context.model(for: id) as? FaceObservation {
                result[id] = model
            }
        }
        guard !wanted.isEmpty else { return result }
        result.reserveCapacity(result.count + wanted.count)
        for chunk in wanted.chunked(every: Self.fetchChunkSize) {
            let found = (try? context.fetch(FetchDescriptor<FaceObservation>(predicate: #Predicate { chunk.contains($0.id) }))) ?? []
            for model in found {
                if let pid = byID[model.id] { result[pid] = model }
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

    private func mediaItem(withID mediaID: String) -> MediaItem? {
        if let item = itemsByID[mediaID] { return item }
        return itemByPID.values.first { $0.id == mediaID }
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

    private func rebuildFaces() {
        let sorted = faceByPID.sorted { lhs, rhs in
            let left = faceIDs[lhs.key] ?? ""
            let right = faceIDs[rhs.key] ?? ""
            if left != right { return left < right }
            return lhs.key < rhs.key
        }.map(\.value)
        if !faces.elementsEqual(sorted, by: { $0 === $1 }) { faces = sorted }
    }

    private func refetchPlaces() {
        guard let context else { return }
        let next = (try? context.fetch(FetchDescriptor<Place>(sortBy: [SortDescriptor(\.id)]))) ?? []
        if !places.elementsEqual(next, by: { $0 === $1 }) { places = next }
        var sum = 0
        for place in next { sum &+= Self.hash(of: place) }
        placeSum = sum
    }

    // MARK: - Revision

    private struct Measures: Equatable {
        var itemSum = 0
        var itemCount = 0
        var faceSum = 0
        var faceCount = 0
        var placeSum = 0
        var placeCount = 0
    }

    private func bumpRevisionIfNeeded() {
        let next = Measures(
            itemSum: itemSum,
            itemCount: itemByPID.count,
            faceSum: faceSum,
            faceCount: faceByPID.count,
            placeSum: placeSum,
            placeCount: places.count
        )
        guard next != applied else { return }
        applied = next
        revision &+= 1
    }

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

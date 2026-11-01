import Foundation
import Observation
import SwiftData

/// The library's photos, faces and places, fetched once for every page
/// instead of once per page. Pages read these lists and use `revision` in
/// their rebuild keys, so switching pages fetches nothing and hashes nothing.
/// SwiftData stays the source of truth; cells keep reading their models, so
/// an edit shows in its cell at once.
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
    private(set) var faces: [FaceObservation] = []
    /// Every place, by id.
    private(set) var places: [Place] = []
    /// Changes when something a page groups or filters by has changed:
    /// photos added, removed or moved in time or place, faces assigned,
    /// places renamed. Not bumped by saves that change none of that.
    private(set) var revision = 0
    /// How many refreshes ran; for tests and the page probe.
    private(set) var refreshCount = 0

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var firstPendingSave: Date?
    @ObservationIgnored private var signature: Int?

    /// Quiet time after the last save before refreshing.
    static let settleDelay: Duration = .milliseconds(250)
    /// While saves keep coming (an import), refresh at least this often.
    static let maximumDelay: TimeInterval = 1

    /// Call once with the main context, from the window's onAppear.
    func start(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        refreshNow()
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        pending?.cancel()
    }

    /// Saves from any context (import, face scan, place names, bursts, edits)
    /// arrive here; many in a row become one refresh.
    func scheduleRefresh() {
        let now = Date()
        if firstPendingSave == nil { firstPendingSave = now }
        let waitedTooLong = now.timeIntervalSince(firstPendingSave ?? now) >= Self.maximumDelay
        pending?.cancel()
        if waitedTooLong {
            refreshNow()
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    /// Fetches everything again and bumps `revision` if anything pages use changed.
    func refreshNow() {
        pending?.cancel()
        pending = nil
        firstPendingSave = nil
        guard let context else { return }
        let live = (try? context.fetch(FetchDescriptor<MediaItem>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.captureDate)]
        ))) ?? []
        let deleted = (try? context.fetch(FetchDescriptor<MediaItem>(
            predicate: #Predicate { $0.deletedAt != nil },
            sortBy: [SortDescriptor(\.deletedAt, order: .reverse)]
        ))) ?? []
        let allFaces = (try? context.fetch(FetchDescriptor<FaceObservation>())) ?? []
        let allPlaces = (try? context.fetch(FetchDescriptor<Place>(sortBy: [SortDescriptor(\.id)]))) ?? []

        items = live
        regularItems = live.filter { !$0.isScreenshot }
        screenshotItems = live.filter { $0.isScreenshot }
        itemsByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        deletedItems = deleted
        faces = allFaces
        places = allPlaces
        refreshCount += 1

        let next = Self.signature(items: live, deleted: deleted, faces: allFaces, places: allPlaces)
        if next != signature {
            signature = next
            revision &+= 1
        }
    }

    private static func signature(items: [MediaItem], deleted: [MediaItem], faces: [FaceObservation], places: [Place]) -> Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.effectiveCaptureDate)
            hasher.combine(item.localDayKey)
            hasher.combine(item.latitude)
            hasher.combine(item.longitude)
            hasher.combine(item.tripID)
            hasher.combine(item.place?.id)
            hasher.combine(item.kindRaw)
            hasher.combine(item.isScreenshot)
            hasher.combine(item.isFavorite)
            hasher.combine(item.updatedAt)
        }
        hasher.combine(deleted.count)
        for item in deleted { hasher.combine(item.id) }
        hasher.combine(faces.count)
        for face in faces {
            hasher.combine(face.id)
            hasher.combine(face.mediaID)
            hasher.combine(face.personID)
            hasher.combine(face.clusterID)
            hasher.combine(face.confirmed)
            hasher.combine(face.assignmentSource)
        }
        hasher.combine(places.count)
        for place in places {
            hasher.combine(place.id)
            hasher.combine(place.name)
            hasher.combine(place.correctedName)
            hasher.combine(place.parent?.id)
        }
        return hasher.finalize()
    }
}

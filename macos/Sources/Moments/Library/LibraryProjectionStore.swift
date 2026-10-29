import Foundation
import Observation
import SwiftData
import MomentsCore

/// Builds one immutable, background-owned read model for every large-library
/// screen. SwiftData remains the source of truth; this store is disposable
/// derived state and can always be rebuilt after a change or launch.
@MainActor
@Observable
final class LibraryProjectionStore {
    private(set) var projection = LibraryProjection.empty
    private(set) var isBuilding = false
    /// Changes whenever a complete snapshot becomes visible to the screens.
    /// Views include this value in their build keys so a publish also rebuilds
    /// pages that read the snapshot only inside an async task.
    private(set) var revision = 0
    /// Monotonic source generation used to reject results from obsolete builds.
    private(set) var sourceGeneration = 0

    private var generation = 0
    private var task: Task<Void, Never>?
    private var scheduledRefresh: Task<Void, Never>?

    /// Coalesce the many saves made by an import or an editor into one rebuild.
    func scheduleRefresh(container: ModelContainer) {
        // Advance immediately so page consumers can cancel work before the
        // debounced rebuild starts.
        generation &+= 1
        sourceGeneration &+= 1
        scheduledRefresh?.cancel()
        scheduledRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.refresh(container: container, token: self.generation)
        }
    }

    func refresh(container: ModelContainer) {
        generation &+= 1
        sourceGeneration &+= 1
        refresh(container: container, token: generation)
    }

    private func refresh(container: ModelContainer, token: Int) {
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        task?.cancel()
        isBuilding = true
        task = Task { @MainActor [weak self] in
            let descriptors = await Task.detached(priority: .utility) {
                Self.readDescriptors(container: container)
            }.value
            guard !Task.isCancelled, let self, self.generation == token else { return }
            let next = await Task.detached(priority: .utility) {
                LibraryProjection(photos: descriptors.photos, places: descriptors.places)
            }.value
            guard !Task.isCancelled, self.generation == token else { return }
            self.projection = next
            // Even an empty first snapshot publishes a revision; views that
            // mounted before the initial build must rebuild once.
            self.revision &+= 1
            self.isBuilding = false
            self.task = nil
        }
    }

    func cancel() {
        generation &+= 1
        sourceGeneration &+= 1
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        task?.cancel()
        task = nil
        isBuilding = false
    }

    nonisolated private static func readDescriptors(
        container: ModelContainer
    ) -> (photos: [LibraryPhotoDescriptor], places: [LibraryPlaceDescriptor]) {
        let context = ModelContext(container)
        let items = (try? context.fetch(FetchDescriptor<MediaItem>(
            predicate: #Predicate { $0.deletedAt == nil }
        ))) ?? []
        let places = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        let placeDescriptors = places.map {
            LibraryPlaceDescriptor(
                id: $0.id,
                name: PlaceDisplayName.resolvedName(of: $0),
                latitude: $0.latitude,
                longitude: $0.longitude
            )
        }
        let photos = items.map { item in
            let dayKey = item.localDayKey
            let kind: LibraryPhotoDescriptor.Kind = switch item.kind {
            case .video: .video
            case .live: .live
            default: .photo
            }
            return LibraryPhotoDescriptor(
                id: item.id,
                captureDate: item.effectiveCaptureDate,
                dayKey: dayKey,
                monthKey: dayKey.map { String($0.prefix(7)) },
                latitude: item.effectiveCoordinate?.latitude,
                longitude: item.effectiveCoordinate?.longitude,
                placeID: item.place?.id,
                placeName: item.displayPlaceName,
                tripID: item.tripID,
                kind: kind,
                isScreenshot: item.isScreenshot,
                isFavorite: item.isFavorite,
                hasMemory: !item.memories.isEmpty,
                title: item.title
            )
        }
        return (photos, placeDescriptors)
    }
}
import Foundation

/// UI-only phase for progressive page loading. It contains no SwiftData models.
enum PageLoadPhase: Equatable, Sendable {
    case idle
    case loading(generation: Int)
    case partial(loaded: Int, total: Int?, generation: Int)
    case ready(total: Int, generation: Int)
    case empty(generation: Int)
    case failed(messageKey: String, generation: Int)

    var generation: Int {
        switch self {
        case .idle: return 0
        case .loading(let generation), .partial(_, _, let generation),
             .ready(_, let generation), .empty(let generation), .failed(_, let generation):
            return generation
        }
    }

    var isTerminal: Bool {
        switch self {
        case .ready, .empty, .failed: return true
        case .idle, .loading, .partial: return false
        }
    }
}

/// A request token shared by page batches. A result may be published only when
/// its generation still matches the active token.
struct PageRequestToken: Equatable, Sendable {
    let generation: Int
    let projectionRevision: Int

    /// A result is publishable only when it belongs to the current request and
    /// the immutable projection that request observed. Checking both values is
    /// important: a filter/scroll request can be replaced without rebuilding
    /// the projection, and a projection refresh can invalidate every request.
    func accepts(generation: Int, projectionRevision: Int) -> Bool {
        self.generation == generation && self.projectionRevision == projectionRevision
    }

    /// Compatibility shorthand for callers that only need to guard a
    /// projection refresh. New page loaders should use the two-value check.
    func accepts(projectionRevision: Int) -> Bool {
        self.projectionRevision == projectionRevision
    }
}

/// Small LRU cache for immutable page snapshots. The cache is intentionally
/// bounded so a warm navigation cannot retain every library page forever.
@MainActor
final class PageSnapshotCache<Key: Hashable, Value> {
    private let capacity: Int
    private var values: [Key: Value] = [:]
    private var recency: [Key] = []

    init(capacity: Int = 2) {
        self.capacity = max(1, capacity)
    }

    var count: Int { values.count }

    func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    func insert(_ value: Value, for key: Key) {
        values[key] = value
        touch(key)
        while recency.count > capacity {
            let evicted = recency.removeFirst()
            values.removeValue(forKey: evicted)
        }
    }

    func removeValue(for key: Key) {
        values.removeValue(forKey: key)
        recency.removeAll { $0 == key }
    }

    func removeAll() {
        values.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

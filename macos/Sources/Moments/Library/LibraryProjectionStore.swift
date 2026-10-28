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

    private var generation = 0
    private var task: Task<Void, Never>?
    private var scheduledRefresh: Task<Void, Never>?

    /// Coalesce the many saves made by an import or an editor into one rebuild.
    func scheduleRefresh(container: ModelContainer) {
        scheduledRefresh?.cancel()
        scheduledRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.refresh(container: container)
        }
    }

    func refresh(container: ModelContainer) {
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        generation += 1
        let token = generation
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
            self.revision &+= 1
            self.isBuilding = false
            self.task = nil
        }
    }

    func cancel() {
        generation += 1
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

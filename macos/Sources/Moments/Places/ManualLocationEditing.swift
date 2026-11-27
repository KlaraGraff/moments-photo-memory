import Foundation
import MomentsCore
import SwiftData

// "Set Location…": a hand-set coordinate for photos the camera gave none (or
// a wrong one). No new field: the coordinate goes in this person's
// `PlaceOverride` for the photo (`latitude`/`longitude`, which sync already
// carries, per account), and the photo's shared `place` moves to a spot near
// it, so grouping and naming by place work as for a camera location. The
// camera's own coordinate stays in `MediaItem.latitude`/`longitude`.

extension MediaItem {
    /// The hand-set coordinate this photo shows: the newest one, whoever set
    /// it. Reads the photo's overrides, so the map uses
    /// `ManualLocationIndex` instead for many photos at once.
    var manualLocation: ManualLocation.OverrideCoordinate? {
        ManualLocation.resolved(placeOverrides.compactMap(ManualLocationIndex.coordinate(of:)))
    }

    /// Where the camera said the photo was taken.
    var cameraLocation: GeoPoint? {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    /// Where the photo stands on a map: by hand first, then the camera's.
    var mapLocation: GeoPoint? { manualLocation?.point ?? cameraLocation }
}

enum ManualLocationIndex {
    static func coordinate(of override: PlaceOverride) -> ManualLocation.OverrideCoordinate? {
        guard override.mediaID != nil || override.mediaItem != nil,
              let latitude = override.latitude, let longitude = override.longitude,
              latitude.isFinite, longitude.isFinite else { return nil }
        return ManualLocation.OverrideCoordinate(
            accountID: override.accountID,
            point: GeoPoint(latitude: latitude, longitude: longitude),
            updatedAt: override.updatedAt
        )
    }

    /// Every photo's hand-set coordinate, from one fetch of the overrides
    /// that carry one (a few rows, however large the library).
    @MainActor
    static func coordinates(in context: ModelContext) -> [String: GeoPoint] {
        let descriptor = FetchDescriptor<PlaceOverride>(
            predicate: #Predicate { $0.mediaID != nil && $0.latitude != nil && $0.longitude != nil }
        )
        let rows: [ManualLocation.OverrideRow] = ((try? context.fetch(descriptor)) ?? []).compactMap { override in
            guard let mediaID = override.mediaID, let coordinate = coordinate(of: override) else { return nil }
            return ManualLocation.OverrideRow(mediaID: mediaID, coordinate: coordinate)
        }
        return ManualLocation.index(rows)
    }
}

@MainActor
enum ManualLocationEditing {
    /// What a photo looked like before an edit, so Undo can put it back.
    private struct ItemState {
        let id: String
        let placeID: String?
        let override: OverrideState?
        let updatedAt: Date
        let updatedBy: String?
    }

    /// A place this feature made that an edit removed once nothing used it.
    private struct PlaceState {
        let id: String
        let name: String
        let kind: PlaceKind
        let latitude: Double?
        let longitude: Double?
        let parentID: String?
        let updatedAt: Date
        let updatedBy: String?
    }

    /// Places made here start with this, so Change and Clear can remove the
    /// ones left empty, and never a place the import made.
    nonisolated static let placeIDPrefix = "manual-"

    /// Photos by id, a few hundred ids to a fetch, so a large selection
    /// stays under the store's limit on values in one query.
    static func items(withIDs ids: [String], context: ModelContext) -> [MediaItem] {
        var found: [MediaItem] = []
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 400, ids.count)])
            let descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { chunk.contains($0.id) })
            found += (try? context.fetch(descriptor)) ?? []
            start += 400
        }
        return found
    }

    private struct OverrideState {
        let nameOverride: String?
        let mapLinkOverride: String?
        let latitude: Double?
        let longitude: Double?
        let updatedAt: Date
        let updatedBy: String?
    }

    /// Puts the photos at `point`. `name` is the searched place's name; a
    /// spot made here takes it, and a photo's own name (typed by hand) is
    /// never touched. Returns the undo for the bar and ⌘Z, or nil when
    /// nothing changed.
    @discardableResult
    static func setLocation(
        _ point: GeoPoint,
        name: String?,
        on items: [MediaItem],
        context: ModelContext,
        now: Date = .now
    ) -> CorrectionUndo? {
        guard !items.isEmpty else { return nil }
        let before = items.map(state(of:))
        let previous = items.compactMap(\.place)
        var created: [String] = []
        var finder = PlaceFinder(context: context)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let place = finder.place(for: point, name: trimmedName, created: &created)
        for item in items {
            let override = localOverride(of: item, context: context, now: now)
            override.latitude = point.latitude
            override.longitude = point.longitude
            override.updatedAt = now
            override.updatedBy = MomentsAccount.localID
            item.place = place
            touch(item, now: now)
        }
        let removed = pruneEmptyPlaces(previous, keeping: [place], movedItemIDs: Set(items.map(\.id)), context: context)
        try? context.save()
        if created.contains(where: { id in
            guard let kind = fetchPlace(id, context: context)?.kind else { return false }
            return kind != .spot
        }) {
            startNameBackfill(context: context)
        }
        let message = items.count == 1
            ? String(localized: "Location set")
            : String(localized: "Location set for \(items.count) photos")
        return undo(message: message, before: before, created: created, removed: removed)
    }

    /// Takes this person's hand-set location off the photos. A name they
    /// typed for the photo stays. The photo goes to the partner's hand-set
    /// location if there is one, else the camera's (Use Camera Location),
    /// else it has none again.
    @discardableResult
    static func clearLocation(on items: [MediaItem], context: ModelContext, now: Date = .now) -> CorrectionUndo? {
        let changed = items.filter { $0.localPlaceOverride?.latitude != nil || $0.localPlaceOverride?.longitude != nil }
        guard !changed.isEmpty else { return nil }
        let before = changed.map(state(of:))
        let previous = changed.compactMap(\.place)
        var created: [String] = []
        var finder = PlaceFinder(context: context)
        var targets: [Place] = []
        for item in changed {
            if let override = item.localPlaceOverride {
                let typedName = override.nameOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if typedName.isEmpty, override.mapLinkOverride == nil {
                    context.delete(override)
                } else {
                    override.latitude = nil
                    override.longitude = nil
                    override.updatedAt = now
                    override.updatedBy = MomentsAccount.localID
                }
            }
            // The partner's hand-set location, read without this person's
            // override, which may only be marked deleted until the save.
            let partner = ManualLocation.resolved(
                item.placeOverrides
                    .filter { $0.accountID != MomentsAccount.localID }
                    .compactMap(ManualLocationIndex.coordinate(of:))
            )
            if let point = partner?.point ?? item.cameraLocation {
                let place = finder.place(for: point, name: "", created: &created)
                item.place = place
                targets.append(place)
            } else {
                item.place = nil
            }
            touch(item, now: now)
        }
        let removed = pruneEmptyPlaces(previous, keeping: targets, movedItemIDs: Set(changed.map(\.id)), context: context)
        try? context.save()
        if created.contains(where: { id in
            guard let kind = fetchPlace(id, context: context)?.kind else { return false }
            return kind != .spot
        }) {
            startNameBackfill(context: context)
        }
        return undo(message: String(localized: "Location cleared"), before: before, created: created, removed: removed)
    }

    // MARK: Places

    /// Finds the spot a coordinate joins. Reads the places with a
    /// coordinate once per edit, however many photos it moves, and counts
    /// the places it makes, so a batch shares them.
    private struct PlaceFinder {
        let context: ModelContext
        private var places: [Place]

        init(context: ModelContext) {
            self.context = context
            let descriptor = FetchDescriptor<Place>(predicate: #Predicate { place in
                place.latitude != nil && place.longitude != nil
            })
            places = (try? context.fetch(descriptor)) ?? []
        }

        /// One within the clusterer's spot radius, else a new spot under the
        /// nearest area or city
        /// (new ones too when none is near). A new spot takes `name`; the
        /// place-name backfill names a new city and area.
        mutating func place(for point: GeoPoint, name: String, created: inout [String]) -> Place {
            // About 30 km of latitude either side: past the city radius.
            let low = point.latitude - 0.3
            let high = point.latitude + 0.3
            let nearby = places.filter { place in
                guard let latitude = place.latitude else { return false }
                return latitude > low && latitude < high
            }
            let existing: [ManualLocation.ExistingPlace] = nearby.compactMap { place in
                guard let latitude = place.latitude, let longitude = place.longitude else { return nil }
                let level: ManualLocation.Level
                switch place.kind {
                case .spot: level = .spot
                case .area: level = .area
                case .city: level = .city
                }
                return ManualLocation.ExistingPlace(id: place.id, level: level, point: GeoPoint(latitude: latitude, longitude: longitude))
            }
            let byID = Dictionary(nearby.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let clusterer = PlaceClusterer()
            let placement = ManualLocation.placement(
                for: point,
                among: existing,
                spotRadiusMeters: clusterer.spotRadiusMeters,
                areaRadiusMeters: clusterer.areaRadiusMeters,
                cityRadiusMeters: clusterer.cityRadiusMeters
            )
            let context = context
            func newPlace(_ kind: PlaceKind, parent: Place?) -> Place {
                let place = Place(
                    id: ManualLocationEditing.placeIDPrefix + UUID().uuidString,
                    name: kind == .spot ? name : "",
                    kind: kind,
                    latitude: point.latitude,
                    longitude: point.longitude,
                    parent: parent,
                    updatedBy: MomentsAccount.localID
                )
                context.insert(place)
                created.append(place.id)
                return place
            }
            let spot: Place
            switch placement {
            case .spot(let id):
                if let found = byID[id] { return found }
                spot = newPlace(.spot, parent: nil)
            case .newSpot(let areaID):
                spot = newPlace(.spot, parent: byID[areaID])
            case .newArea(let cityID):
                let area = newPlace(.area, parent: byID[cityID])
                places.append(area)
                spot = newPlace(.spot, parent: area)
            case .newCity:
                let city = newPlace(.city, parent: nil)
                let area = newPlace(.area, parent: city)
                places.append(city)
                places.append(area)
                spot = newPlace(.spot, parent: area)
            }
            places.append(spot)
            return spot
        }
    }

    /// Removes the places this feature made that the photos just left, when
    /// nothing else uses them, from the spot up. Returns them for Undo.
    /// `keeping` are the places the photos just joined: they and their
    /// parents stay, because a child made in this edit is not in its
    /// parent's list until the save. A place someone renamed stays too.
    private static func pruneEmptyPlaces(
        _ previous: [Place],
        keeping: [Place],
        movedItemIDs: Set<String>,
        context: ModelContext
    ) -> [PlaceState] {
        var kept: Set<String> = []
        for target in keeping {
            var current: Place? = target
            var depth = 0
            while let place = current, depth < 4 {
                kept.insert(place.id)
                current = place.parent
                depth += 1
            }
        }
        var removed: [PlaceState] = []
        var removedIDs: Set<String> = []
        var seen: Set<String> = []
        for start in previous where seen.insert(start.id).inserted {
            var current: Place? = start
            while let place = current, place.id.hasPrefix(placeIDPrefix), !removedIDs.contains(place.id), !kept.contains(place.id) {
                let placeID = place.id
                // The inverse lists still hold the photos that just moved.
                let unused = place.items.allSatisfy { movedItemIDs.contains($0.id) && $0.place?.id != placeID }
                    && place.children.allSatisfy { removedIDs.contains($0.id) }
                    && place.overrides.isEmpty
                guard unused else { break }
                removed.append(PlaceState(
                    id: placeID,
                    name: place.name,
                    kind: place.kind,
                    latitude: place.latitude,
                    longitude: place.longitude,
                    parentID: place.parent?.id,
                    updatedAt: place.updatedAt,
                    updatedBy: place.updatedBy
                ))
                removedIDs.insert(placeID)
                current = place.parent
                context.delete(place)
            }
        }
        return removed
    }

    private static func fetchPlace(_ id: String, context: ModelContext) -> Place? {
        var descriptor = FetchDescriptor<Place>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func startNameBackfill(context: ModelContext) {
        #if DEBUG
        // UI tests run offline and must never reach the geocoder.
        if ProcessInfo.processInfo.arguments.contains("-MomentsUITesting") { return }
        #endif
        PlaceNameBackfillScheduler.shared.start(container: context.container)
    }

    // MARK: Undo

    private static func state(of item: MediaItem) -> ItemState {
        ItemState(
            id: item.id,
            placeID: item.place?.id,
            override: item.localPlaceOverride.map { override in
                OverrideState(
                    nameOverride: override.nameOverride,
                    mapLinkOverride: override.mapLinkOverride,
                    latitude: override.latitude,
                    longitude: override.longitude,
                    updatedAt: override.updatedAt,
                    updatedBy: override.updatedBy
                )
            },
            updatedAt: item.updatedAt,
            updatedBy: item.updatedBy
        )
    }

    private static func undo(message: String, before: [ItemState], created: [String], removed: [PlaceState]) -> CorrectionUndo {
        CorrectionUndo(message: message, actionName: String(localized: "Set Location")) { context in
            // Places the edit removed come back first, parents before
            // children, with their ids, so the photos can rejoin them.
            var restored: [String: Place] = [:]
            for saved in removed.reversed() where fetchPlace(saved.id, context: context) == nil {
                let parent = saved.parentID.flatMap { restored[$0] ?? fetchPlace($0, context: context) }
                let place = Place(
                    id: saved.id,
                    name: saved.name,
                    kind: saved.kind,
                    latitude: saved.latitude,
                    longitude: saved.longitude,
                    parent: parent,
                    updatedAt: saved.updatedAt,
                    updatedBy: saved.updatedBy
                )
                context.insert(place)
                restored[saved.id] = place
            }
            let ids = before.map(\.id)
            let idSet = Set(ids)
            let items = Self.items(withIDs: ids, context: context)
            let itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for state in before {
                guard let item = itemsByID[state.id] else { continue }
                item.place = state.placeID.flatMap { restored[$0] ?? fetchPlace($0, context: context) }
                let current = item.localPlaceOverride
                if let saved = state.override {
                    let override = current ?? {
                        let inserted = PlaceOverride(mediaID: item.id, mediaItem: item)
                        context.insert(inserted)
                        return inserted
                    }()
                    override.nameOverride = saved.nameOverride
                    override.mapLinkOverride = saved.mapLinkOverride
                    override.latitude = saved.latitude
                    override.longitude = saved.longitude
                    override.updatedAt = saved.updatedAt
                    override.updatedBy = saved.updatedBy
                } else if let current {
                    context.delete(current)
                }
                // Back to the old values, but later than the edit, so sync
                // and the Library both see the photo change again.
                item.updatedAt = .now
                item.updatedBy = MomentsAccount.localID
            }
            // The places this edit made, newest (the spot) first, while
            // nothing else uses them. A deleted child still shows in its
            // parent's list until the save, so those are counted as gone.
            var deleted: Set<String> = []
            for id in created.reversed() {
                guard let place = fetchPlace(id, context: context),
                      place.items.allSatisfy({ idSet.contains($0.id) && $0.place?.id != id }),
                      place.children.allSatisfy({ deleted.contains($0.id) }),
                      place.overrides.isEmpty else { continue }
                context.delete(place)
                deleted.insert(id)
            }
        }
    }

    // MARK: Helpers

    private static func localOverride(of item: MediaItem, context: ModelContext, now: Date) -> PlaceOverride {
        if let existing = item.localPlaceOverride { return existing }
        let inserted = PlaceOverride(mediaID: item.id, updatedAt: now, updatedBy: MomentsAccount.localID, mediaItem: item)
        context.insert(inserted)
        return inserted
    }

    private static func touch(_ item: MediaItem, now: Date) {
        item.updatedAt = now
        item.updatedBy = MomentsAccount.localID
    }
}

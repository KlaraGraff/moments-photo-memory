import CoreGraphics
import Foundation
import MomentsCore
import SwiftData

public enum PhotosImportError: LocalizedError, Equatable {
    case permissionDenied(PhotosAuthorizationStatus)
    case noAssets

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let status):
            switch status {
            case .limited: return String(localized: "Apple Photos access is limited. Select more photos in System Settings or continue with the selected photos.")
            case .restricted: return String(localized: "Apple Photos access is restricted by macOS.")
            default: return String(localized: "Apple Photos access is denied. Allow photo access in System Settings to import.")
            }
        case .noAssets:
            return String(localized: "No photos or videos matched the Apple Photos selection.")
        }
    }
}

public struct PhotosImportPreview: Equatable, Sendable {
    public let selection: PhotosImportSelection
    public let count: Int

    public init(selection: PhotosImportSelection, count: Int) {
        self.selection = selection
        self.count = count
    }
}

public struct PhotosImportDuplicateDetector: Sendable {
    public var coordinateToleranceMeters: Double

    public init(coordinateToleranceMeters: Double = 10) {
        self.coordinateToleranceMeters = max(0, coordinateToleranceMeters)
    }

    public func matchingPhotoIdentifiers(
        _ mappedAssets: [PhotosMappedAsset],
        against existingItems: [MediaItem]
    ) -> Set<String> {
        let folderItems = existingItems.filter { $0.source == .file }
        return mappedAssets.reduce(into: Set<String>()) { matches, mapped in
            guard let date = mapped.asset.creationDate else { return }
            let hasCoordinate = mapped.asset.location != nil
            guard folderItems.contains(where: { existing in
                guard let existingDate = existing.captureDate,
                      abs(existingDate.timeIntervalSince(date)) <= 1,
                      existing.width == mapped.asset.pixelWidth,
                      existing.height == mapped.asset.pixelHeight else { return false }
                guard hasCoordinate,
                      let lhs = mapped.asset.location,
                      let rhs = existing.latitude.flatMap({ latitude in existing.longitude.map { GeoPoint(latitude: latitude, longitude: $0) } }) else {
                    return false
                }
                return lhs.distance(to: rhs) <= coordinateToleranceMeters
            }) else { return }
            matches.insert(mapped.asset.localIdentifier)
        }
    }
}

public struct PhotosImporter {
    public let source: any PhotosAssetSource
    public let configuration: ImportConfiguration
    public let geocoder: any ImportGeocoder
    public let geocodeCache: ImportGeocodeCache
    public let mapper: PhotosMetadataMapper

    public init(
        source: any PhotosAssetSource,
        configuration: ImportConfiguration = ImportConfiguration(),
        geocoder: (any ImportGeocoder)? = nil,
        geocodeCache: ImportGeocodeCache? = nil,
        mapper: PhotosMetadataMapper = PhotosMetadataMapper()
    ) {
        self.source = source
        self.configuration = configuration
        self.geocoder = geocoder ?? CoreLocationImportGeocoder()
        self.geocodeCache = geocodeCache ?? ImportGeocodeCache(
            fileURL: URL.applicationSupportDirectory
                .appending(path: "Moments", directoryHint: .isDirectory)
                .appending(path: "import-geocoding.json")
        )
        self.mapper = mapper
    }

    public func requestAccess() async -> PhotosAuthorizationStatus {
        let status = source.authorizationStatus
        return status == .notDetermined ? await source.requestAuthorization() : status
    }

    public func preview(selection: PhotosImportSelection) async throws -> PhotosImportPreview {
        let status = await requestAccess()
        guard status.canRead else { throw PhotosImportError.permissionDenied(status) }
        let assets = try await source.fetchAssets(selection: selection)
        return PhotosImportPreview(selection: selection, count: assets.count)
    }

    public func importPhotos(
        selection: PhotosImportSelection,
        container: ModelContainer,
        progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }
    ) async throws -> ImportSummary {
        let status = await requestAccess()
        guard status.canRead else { throw PhotosImportError.permissionDenied(status) }
        let assets = try await source.fetchAssets(selection: selection)
        guard !assets.isEmpty else { throw PhotosImportError.noAssets }
        progress(ImportProgress(phase: .scanning, completed: assets.count, total: assets.count, message: String(localized: "Found Apple Photos assets")))

        let context = ModelContext(container)
        let existing = try context.fetch(FetchDescriptor<MediaItem>())
        let existingByPhotosID = Dictionary(existing.compactMap { item in
            item.photosLocalIdentifier.map { ($0, item) }
        }, uniquingKeysWith: { first, _ in first })
        let isIncrementalRefresh: Bool = {
            if case .identifiers = selection { return true }
            return false
        }()
        let existingPhotos = Set(existingByPhotosID.keys)
        let freshAssets = assets.filter { isIncrementalRefresh || !existingPhotos.contains($0.localIdentifier) }
        let skippedCount = assets.count - freshAssets.count
        guard !freshAssets.isEmpty else {
            progress(ImportProgress(phase: .finished, completed: 0, total: 0, message: String(localized: "Apple Photos import is already up to date")))
            return ImportSummary(importedCount: 0, skippedCount: skippedCount, tripCount: 0, placeCount: 0, collectionCount: 0, routeCount: 0, trips: [], flags: [], conflicts: [])
        }

        let hashIdentifiers = Set(freshAssets.compactMap { asset -> String? in
            guard asset.mediaType == .image else { return nil }
            if !isIncrementalRefresh { return asset.localIdentifier }
            return existingByPhotosID[asset.localIdentifier]?.perceptualHash == nil ? asset.localIdentifier : nil
        })
        var mapped: [PhotosMappedAsset] = []
        mapped.reserveCapacity(freshAssets.count)
        for (index, asset) in freshAssets.enumerated() {
            try Task.checkCancellation()
            let mappedAsset = mapper.map(asset)
            let perceptualHash: String?
            if hashIdentifiers.contains(asset.localIdentifier),
               let thumbnail = await source.thumbnailImage(
                   forLocalIdentifier: asset.localIdentifier,
                   targetSize: CGSize(width: 64, height: 64),
                   networkAccessAllowed: false
               ) {
                perceptualHash = PerceptualHash.dHash(thumbnail)
            } else {
                perceptualHash = nil
            }
            mapped.append(PhotosMappedAsset(
                asset: mappedAsset.asset,
                metadata: mappedAsset.metadata,
                isScreenshot: mappedAsset.isScreenshot,
                isFavorite: mappedAsset.isFavorite,
                perceptualHash: perceptualHash
            ))
            progress(ImportProgress(phase: .readingMetadata, completed: index + 1, total: freshAssets.count, message: String(localized: "Reading Apple Photos metadata")))
        }
        let fresh = mapped

        let duplicateDetector = PhotosImportDuplicateDetector()
        let duplicateLocalIDs = duplicateDetector.matchingPhotoIdentifiers(fresh, against: existing)
        let metadata = fresh.map(\.metadata)
        let organizer = ImportOrganizer(
            configuration: configuration,
            geocoder: BestEffortPhotosGeocoder(base: geocoder),
            geocodeCache: geocodeCache
        )
        let plan = try await organizer.organize(metadata)
        progress(ImportProgress(phase: .organizing, completed: metadata.count, total: metadata.count, message: String(localized: "Organizing Apple Photos")))

        let mappedByMetadataID = Dictionary(uniqueKeysWithValues: fresh.map { ($0.metadata.id, $0) })
        let duplicateReasons = Set([ImportReviewReason.nearDuplicate])
        let duplicateFlags = fresh.filter { duplicateLocalIDs.contains($0.asset.localIdentifier) }.map { mapped in
            ImportReviewFlag(
                id: mapped.metadata.id,
                fileName: mapped.metadata.fileName,
                reasons: Array(duplicateReasons),
                detail: String(localized: "This Apple Photos asset may also be present in a folder import."),
                decision: .pending
            )
        }
        let mergedFlags = mergeFlags(plan.flags, duplicateFlags)
        // Incremental refreshes still organize existing assets to refresh derived metadata,
        // but only new assets may create persisted trip/place suggestions below.
        let existingTrips = try context.fetch(FetchDescriptor<Trip>())
        let existingPlaces = try context.fetch(FetchDescriptor<Place>())
        let newMetadataIDs = Set(
            fresh
                .filter { !existingPhotos.contains($0.asset.localIdentifier) }
                .map(\.metadata.id)
        )
        let saveResult = try await save(
            plan: plan,
            mappedByMetadataID: mappedByMetadataID,
            existingByPhotosID: existingByPhotosID,
            existingTripsByID: Dictionary(existingTrips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            existingPlacesByID: Dictionary(existingPlaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            newMetadataIDs: newMetadataIDs,
            reuseExistingClusters: isIncrementalRefresh,
            duplicateLocalIDs: duplicateLocalIDs,
            context: context,
            progress: progress
        )
        progress(ImportProgress(phase: .finished, completed: fresh.count, total: fresh.count, message: String(localized: "Apple Photos import complete")))

        let summaries = plan.trips.filter { saveResult.insertedTripIDs.contains($0.id) }.map { trip in
            ImportTripSummary(id: trip.id, name: trip.name, itemCount: trip.itemIDs.count, startDate: trip.startDate, endDate: trip.endDate, isSuggestion: true)
        }
        return ImportSummary(
            importedCount: fresh.count,
            skippedCount: skippedCount,
            tripCount: summaries.count,
            placeCount: saveResult.insertedPlaceIDs.count,
            collectionCount: plan.collectionCount,
            routeCount: plan.routeCount,
            trips: summaries,
            flags: mergedFlags,
            conflicts: plan.conflicts
        )
    }

    @discardableResult
    public func markMissing(localIdentifiers: [String], in container: ModelContainer) throws -> Int {
        guard !localIdentifiers.isEmpty else { return 0 }
        let context = ModelContext(container)
        let ids = Set(localIdentifiers)
        let items = try context.fetch(FetchDescriptor<MediaItem>())
        var count = 0
        for item in items where item.source == .photos && item.photosLocalIdentifier.map(ids.contains) == true {
            item.photosAssetMissing = true
            item.updatedAt = .now
            count += 1
        }
        if count > 0 { try context.save() }
        return count
    }

    private struct SaveResult {
        let insertedTripIDs: Set<String>
        let insertedPlaceIDs: Set<String>
    }

    private func save(
        plan: OrganizedImportPlan,
        mappedByMetadataID: [String: PhotosMappedAsset],
        existingByPhotosID: [String: MediaItem],
        existingTripsByID: [String: Trip],
        existingPlacesByID: [String: Place],
        newMetadataIDs: Set<String>,
        reuseExistingClusters: Bool,
        duplicateLocalIDs: Set<String>,
        context: ModelContext,
        progress: @escaping @Sendable (ImportProgress) -> Void
    ) async throws -> SaveResult {
        var tripModels: [String: Trip] = [:]
        var insertedTripIDs = Set<String>()
        let newTripIDs = Set(plan.media.compactMap { media in
            newMetadataIDs.contains(media.metadata.id) ? media.tripID : nil
        })
        let newMediaByTripID = Dictionary(grouping: plan.media.filter { newMetadataIDs.contains($0.metadata.id) }, by: \.tripID)
        for trip in plan.trips {
            let newMedia = newMediaByTripID[trip.id] ?? []
            if newTripIDs.contains(trip.id) {
                if let existing = existingTripsByID[trip.id] {
                    tripModels[trip.id] = existing
                } else if reuseExistingClusters,
                          let existing = (existingTripsByID.values
                            .filter {
                                canReuseExistingTrip(
                                    $0,
                                    trip: trip,
                                    newMedia: newMedia
                                )
                            }
                            .min { lhs, rhs in
                                tripTimeDistance(lhs, trip: trip) == tripTimeDistance(rhs, trip: trip)
                                    ? (lhs.startDate ?? .distantFuture, lhs.id) < (rhs.startDate ?? .distantFuture, rhs.id)
                                    : tripTimeDistance(lhs, trip: trip) < tripTimeDistance(rhs, trip: trip)
                            }) {
                    tripModels[trip.id] = existing
                } else {
                    let model = Trip(id: trip.id, name: trip.name, startDate: trip.startDate, endDate: trip.endDate, suggestionStatusRaw: "suggestion")
                    context.insert(model)
                    tripModels[trip.id] = model
                    insertedTripIDs.insert(trip.id)
                }
            } else if let existing = existingTripsByID[trip.id] {
                tripModels[trip.id] = existing
            }
            if let existing = tripModels[trip.id], !insertedTripIDs.contains(trip.id) {
                widenTripDates(existing, to: newMedia)
            }
        }
        var placeModels: [String: Place] = [:]
        var insertedPlaceIDs = Set<String>()
        let newPlaceIDs = placeIDsToPersist(in: plan, newMetadataIDs: newMetadataIDs)
        let clusterer = PlaceClusterer(maximumTimeGap: configuration.maximumTimeGap)
        for place in plan.places {
            if newPlaceIDs.contains(place.id) {
                if let existing = existingPlacesByID[place.id] {
                    placeModels[place.id] = existing
                } else if reuseExistingClusters,
                          let existing = existingPlacesByID.values.first(where: {
                              matchingPlace($0, organized: place, clusterer: clusterer)
                          }) {
                    placeModels[place.id] = existing
                } else {
                    let model = Place(id: place.id, name: place.name, kind: place.kind, latitude: place.latitude, longitude: place.longitude)
                    context.insert(model)
                    placeModels[place.id] = model
                    insertedPlaceIDs.insert(place.id)
                }
            } else if let existing = existingPlacesByID[place.id] {
                placeModels[place.id] = existing
            }
        }
        for place in plan.places {
            if let parentID = place.parentID { placeModels[place.id]?.parent = placeModels[parentID] }
        }
        for (index, organized) in plan.media.enumerated() {
            try Task.checkCancellation()
            guard let mapped = mappedByMetadataID[organized.metadata.id] else { continue }
            let asset = mapped.asset
            var reasons = organized.reasons
            if duplicateLocalIDs.contains(asset.localIdentifier) && !reasons.contains(.nearDuplicate) { reasons.append(.nearDuplicate) }
            if let existing = existingByPhotosID[asset.localIdentifier] {
                if existing.userCorrectedCaptureDateUTC == nil,
                   let exactCaptureDate = organized.metadata.exactCaptureDate {
                    existing.captureDate = exactCaptureDate
                }
                existing.latitude = organized.metadata.latitude
                existing.longitude = organized.metadata.longitude
                existing.kind = organized.metadata.kind
                existing.width = organized.metadata.width
                existing.height = organized.metadata.height
                existing.isScreenshot = mapped.isScreenshot
                existing.duration = organized.metadata.duration
                if existing.userCorrectedCaptureDateUTC == nil {
                    existing.localDayKey = organized.localDayKey
                    existing.timeZoneIdentifier = organized.timeZoneIdentifier
                }
                if existing.userCorrectedCaptureDateUTC == nil {
                    existing.timeConfidenceRaw = organized.metadata.timeConfidence.rawValue
                }
                let existingReasons = Set((existing.importReviewReasonsRaw ?? "").split(separator: ",").map { String($0) })
                let incomingReasons = Set(reasons.map(\.rawValue))
                let addedReasons = incomingReasons.subtracting(existingReasons)
                if !addedReasons.isEmpty {
                    existing.importReviewReasonsRaw = existingReasons.union(incomingReasons).sorted().joined(separator: ",")
                }
                if existing.trip == nil, let trip = tripModels[organized.tripID] {
                    existing.trip = trip
                    existing.tripID = trip.id
                }
                if existing.place == nil,
                   let placeID = organized.placeID,
                   let place = placeModels[placeID] {
                    existing.place = place
                }
                existing.photosCloudIdentifier = asset.cloudIdentifier
                existing.photosAlbumIdentifiersRaw = encodeAlbumIDs(asset.albumIdentifiers)
                existing.photosMediaSubtypesRaw = asset.mediaSubtypes.rawValue
                existing.photosAssetMissing = false
                if existing.perceptualHash == nil, let perceptualHash = mapped.perceptualHash {
                    existing.perceptualHash = perceptualHash
                }
                existing.updatedAt = .now
                progress(ImportProgress(phase: .saving, completed: index + 1, total: plan.media.count, message: String(localized: "Updating Apple Photos import")))
                continue
            }
            let model = MediaItem(
                id: organized.metadata.id,
                captureDate: organized.metadata.exactCaptureDate,
                latitude: organized.metadata.latitude,
                longitude: organized.metadata.longitude,
                kind: organized.metadata.kind,
                width: organized.metadata.width,
                height: organized.metadata.height,
                isScreenshot: mapped.isScreenshot,
                source: .photos,
                title: organized.metadata.fileName,
                tripID: organized.tripID,
                trip: tripModels[organized.tripID],
                originalBookmarkData: nil,
                originalFileName: nil,
                originalContentHash: nil,
                captureDateSourceRaw: organized.metadata.captureDateSource.rawValue,
                localTimeZoneOffsetMinutes: organized.metadata.timeZoneOffsetMinutes,
                localDayKey: organized.localDayKey,
                duration: organized.metadata.duration,
                importReviewReasonsRaw: reasons.map(\.rawValue).sorted().joined(separator: ","),
                importedAt: .now,
                originalCaptureDateUTC: organized.metadata.exactCaptureDate,
                captureDateHintUTC: organized.metadata.dateHintUTC,
                timeZoneIdentifier: organized.timeZoneIdentifier,
                timeConfidenceRaw: organized.metadata.timeConfidence.rawValue,
                sourceReferencesRaw: nil,
                photosLocalIdentifier: asset.localIdentifier,
                photosCloudIdentifier: asset.cloudIdentifier,
                photosAlbumIdentifiersRaw: encodeAlbumIDs(asset.albumIdentifiers),
                photosMediaSubtypesRaw: asset.mediaSubtypes.rawValue,
                photosAssetMissing: false,
                perceptualHash: mapped.perceptualHash,
                reviewDecisionRaw: reasons.isEmpty ? ImportReviewDecision.accepted.rawValue : ImportReviewDecision.pending.rawValue
            )
            model.place = organized.placeID.flatMap { placeModels[$0] }
            context.insert(model)
            if mapped.isFavorite { model.setFavorite(true, context: context) }
            progress(ImportProgress(phase: .saving, completed: index + 1, total: plan.media.count, message: String(localized: "Saving Apple Photos import")))
        }
        try context.save()
        return SaveResult(insertedTripIDs: insertedTripIDs, insertedPlaceIDs: insertedPlaceIDs)
    }

    private func canReuseExistingTrip(_ existing: Trip, trip: OrganizedTrip, newMedia: [OrganizedMedia]) -> Bool {
        guard tripOverlapsOrIsWithinGap(existing, trip: trip) else { return false }

        let existingLocations = existing.items.compactMap { item -> (date: Date, id: String, coordinate: GeoPoint)? in
            guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
            return (item.captureDate ?? .distantPast, item.id, GeoPoint(latitude: latitude, longitude: longitude))
        }
        for media in newMedia {
            guard let latitude = media.metadata.latitude,
                  let longitude = media.metadata.longitude else {
                guard existing.isSuggestion else { return false }
                continue
            }
            guard let nearest = existingLocations.min(by: { lhs, rhs in
                let lhsDistance = lhs.coordinate.distance(to: GeoPoint(latitude: latitude, longitude: longitude))
                let rhsDistance = rhs.coordinate.distance(to: GeoPoint(latitude: latitude, longitude: longitude))
                return lhsDistance == rhsDistance
                    ? (lhs.date, lhs.id) < (rhs.date, rhs.id)
                    : lhsDistance < rhsDistance
            }) else {
                guard existing.isSuggestion else { return false }
                continue
            }
            guard ImportOrganizer.tripCoordinatesCanJoin(
                nearest.coordinate,
                GeoPoint(latitude: latitude, longitude: longitude),
                configuration: configuration
            ) else { return false }
        }
        return true
    }

    private func tripTimeDistance(_ existing: Trip, trip: OrganizedTrip) -> TimeInterval {
        guard let candidateStart = trip.startDate ?? trip.endDate,
              let candidateEnd = trip.endDate ?? trip.startDate,
              let existingStart = existing.startDate ?? existing.endDate,
              let existingEnd = existing.endDate ?? existing.startDate else { return .infinity }
        let start = min(candidateStart, candidateEnd)
        let end = max(candidateStart, candidateEnd)
        let oldStart = min(existingStart, existingEnd)
        let oldEnd = max(existingStart, existingEnd)
        return max(0, max(start.timeIntervalSince(oldEnd), oldStart.timeIntervalSince(end)))
    }

    private func tripOverlapsOrIsWithinGap(_ existing: Trip, trip: OrganizedTrip) -> Bool {
        tripTimeDistance(existing, trip: trip) <= configuration.maximumTimeGap
    }

    private func widenTripDates(_ existing: Trip, to media: [OrganizedMedia]) {
        let dates = media.compactMap(\.metadata.exactCaptureDate)
        guard let start = dates.min(), let end = dates.max() else { return }
        existing.startDate = min(existing.startDate ?? start, start)
        existing.endDate = max(existing.endDate ?? end, end)
    }

    private func matchingPlace(_ existing: Place, organized: OrganizedPlace, clusterer: PlaceClusterer) -> Bool {
        guard existing.kind == organized.kind,
              let existingLatitude = existing.latitude,
              let existingLongitude = existing.longitude,
              let latitude = organized.latitude,
              let longitude = organized.longitude else { return false }
        let existingName = normalizedPlaceName(existing.name)
        let organizedName = normalizedPlaceName(organized.name)
        let generatedSpotPrefix = normalizedPlaceName(String(localized: "Spot")) + " "
        let namesMatch = existingName == organizedName
        let generatedSpotLabelsMatch = organized.kind == .spot
            && existingName.hasPrefix(generatedSpotPrefix)
            && organizedName.hasPrefix(generatedSpotPrefix)
        guard namesMatch || generatedSpotLabelsMatch else { return false }
        let radius: Double
        switch organized.kind {
        case .spot: radius = 1_000
        case .area: radius = clusterer.areaRadiusMeters
        case .city: radius = clusterer.cityRadiusMeters
        }
        return GeoPoint(latitude: existingLatitude, longitude: existingLongitude)
            .distance(to: GeoPoint(latitude: latitude, longitude: longitude)) <= radius
    }

    private func normalizedPlaceName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func mergeFlags(_ first: [ImportReviewFlag], _ second: [ImportReviewFlag]) -> [ImportReviewFlag] {
        var values = Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0) })
        for flag in second {
            if let old = values[flag.id] {
                let reasons = Array(Set(old.reasons + flag.reasons)).sorted { $0.rawValue < $1.rawValue }
                values[flag.id] = ImportReviewFlag(id: old.id, fileName: old.fileName, reasons: reasons, detail: old.detail ?? flag.detail, suggestedDayKey: old.suggestedDayKey ?? flag.suggestedDayKey, suggestedPlaceName: old.suggestedPlaceName ?? flag.suggestedPlaceName, decision: old.decision)
            } else {
                values[flag.id] = flag
            }
        }
        return values.values.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    private func placeIDsToPersist(in plan: OrganizedImportPlan, newMetadataIDs: Set<String>) -> Set<String> {
        var placeIDs = Set(plan.media.compactMap { media in
            newMetadataIDs.contains(media.metadata.id) ? media.placeID : nil
        })
        var addedPlaceID = true
        while addedPlaceID {
            addedPlaceID = false
            for place in plan.places where placeIDs.contains(place.id) {
                if let parentID = place.parentID, placeIDs.insert(parentID).inserted {
                    addedPlaceID = true
                }
            }
        }
        return placeIDs
    }

    private func encodeAlbumIDs(_ ids: [String]) -> String? {
        guard !ids.isEmpty, let data = try? JSONEncoder().encode(ids) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private struct BestEffortPhotosGeocoder: ImportGeocoder {
    let base: any ImportGeocoder

    func reverseGeocode(coordinate: MomentsCore.GeoPoint) async throws -> ImportGeocodeResult {
        do { return try await base.reverseGeocode(coordinate: coordinate) }
        catch { return ImportGeocodeResult() }
    }
}

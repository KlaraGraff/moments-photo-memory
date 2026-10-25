import CoreLocation
import Foundation
import MomentsCore
import SwiftData

struct CoreLocationImportGeocoder: ImportGeocoder {
    func reverseGeocode(coordinate: GeoPoint) async throws -> ImportGeocodeResult {
        let placemarks = try await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        )
        guard let placemark = placemarks.first else { return ImportGeocodeResult() }
        return ImportGeocodeResult(
            city: placemark.locality ?? placemark.subAdministrativeArea,
            area: placemark.administrativeArea,
            spot: placemark.name,
            timeZoneIdentifier: placemark.timeZone?.identifier
        )
    }
}

enum FolderImportError: LocalizedError {
    case notDirectory(URL)
    case noSupportedMedia

    var errorDescription: String? {
        switch self {
        case .notDirectory(let url): return String(localized: "The selected item is not a folder.") + " " + url.lastPathComponent
        case .noSupportedMedia: return String(localized: "No supported photos or videos were found in the folder.")
        }
    }
}

struct FolderImporter {
    let metadataReader = MediaMetadataReader()
    let configuration: ImportConfiguration
    let geocoder: any ImportGeocoder
    let geocodeCache: ImportGeocodeCache
    let geocodeDelay: @Sendable () async -> Void

    init(
        configuration: ImportConfiguration = ImportConfiguration(),
        geocoder: any ImportGeocoder = CoreLocationImportGeocoder(),
        geocodeCache: ImportGeocodeCache? = nil,
        geocodeDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    ) {
        self.configuration = configuration
        self.geocoder = geocoder
        self.geocodeCache = geocodeCache ?? ImportGeocodeCache(
            fileURL: URL.applicationSupportDirectory
                .appending(path: "Moments", directoryHint: .isDirectory)
                .appending(path: "import-geocoding.json")
        )
        self.geocodeDelay = geocodeDelay
    }

    func importFolder(
        _ folderURL: URL,
        container: ModelContainer,
        progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }
    ) async throws -> ImportSummary {
        let directoryValues = try folderURL.resourceValues(forKeys: [.isDirectoryKey])
        guard directoryValues.isDirectory == true else {
            throw FolderImportError.notDirectory(folderURL)
        }
        let hasScopedAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess { folderURL.stopAccessingSecurityScopedResource() }
        }
        let urls = scan(folderURL)
        guard !urls.isEmpty else { throw FolderImportError.noSupportedMedia }
        progress(ImportProgress(phase: .scanning, completed: urls.count, total: urls.count, message: String(localized: "Found media files")))

        var metadata: [ImportedMediaMetadata] = []
        metadata.reserveCapacity(urls.count)
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            do {
                metadata.append(try await metadataReader.read(url: url))
            } catch {
                // A single malformed file should not discard an otherwise valid folder.
            }
            progress(ImportProgress(phase: .readingMetadata, completed: index + 1, total: urls.count, message: String(localized: "Reading metadata")))
        }
        guard !metadata.isEmpty else { throw FolderImportError.noSupportedMedia }
        let organizer = ImportOrganizer(
            configuration: configuration,
            geocoder: geocoder,
            geocodeCache: geocodeCache,
            geocodeDelay: geocodeDelay
        )
        let resolvedMetadata = try await organizer.resolveCaptureDates(metadata)
        let organizedMetadata = coalesceDuplicatesAndLivePairs(resolvedMetadata)
        let sourceFileCount = organizedMetadata.reduce(into: 0) { $0 += $1.sourceReferences.count }

        let context = ModelContext(container)
        let existing = try context.fetch(FetchDescriptor<MediaItem>())
        let existingHashes = Set(existing.compactMap(\.originalContentHash))
        let existingIDs = Set(existing.map(\.id))
        let existingByHash = Dictionary(existing.compactMap { item in
            item.originalContentHash.map { ($0, item) }
        }, uniquingKeysWith: { first, _ in first })
        var didUpdateSourceMappings = false
        for item in organizedMetadata where existingHashes.contains(item.contentHash) || existingIDs.contains(item.id) {
            guard let existingItem = existingByHash[item.contentHash] ?? existing.first(where: { $0.id == item.id }) else { continue }
            let oldReferences = sourceReferencesFromJSON(existingItem.sourceReferencesRaw)
            let merged = Array(Set(oldReferences + item.sourceReferences)).sorted { $0.fileName < $1.fileName }
            if merged.count > oldReferences.count {
                existingItem.sourceReferencesRaw = sourceReferencesJSON(merged)
                didUpdateSourceMappings = true
            }
        }
        let fresh = organizedMetadata.filter { !existingHashes.contains($0.contentHash) && !existingIDs.contains($0.id) }
        let freshSourceCount = fresh.reduce(into: 0) { $0 += $1.sourceReferences.count }
        let skippedCount = sourceFileCount - freshSourceCount
        if fresh.isEmpty {
            if didUpdateSourceMappings { try context.save() }
            return ImportSummary(importedCount: 0, skippedCount: skippedCount, tripCount: 0, placeCount: 0, collectionCount: 0, routeCount: 0, trips: [], flags: [])
        }

        progress(ImportProgress(phase: .organizing, completed: 0, total: fresh.count, message: String(localized: "Organizing trips and places")))
        let plan = try await organizer.organize(fresh)
        try Task.checkCancellation()

        progress(ImportProgress(phase: .saving, completed: 0, total: fresh.count, message: String(localized: "Saving import")))
        var tripModels: [String: Trip] = [:]
        for trip in plan.trips {
            let model = Trip(
                id: trip.id,
                name: trip.name,
                startDate: trip.startDate,
                endDate: trip.endDate,
                suggestionStatusRaw: "suggestion"
            )
            context.insert(model)
            tripModels[trip.id] = model
        }
        var placeModels: [String: Place] = [:]
        for place in plan.places {
            let model = Place(
                id: place.id,
                name: place.name,
                kind: place.kind,
                latitude: place.latitude,
                longitude: place.longitude
            )
            context.insert(model)
            placeModels[place.id] = model
        }
        for place in plan.places {
            if let parentID = place.parentID {
                placeModels[place.id]?.parent = placeModels[parentID]
            }
        }
        for (index, organized) in plan.media.enumerated() {
            try Task.checkCancellation()
            let metadata = organized.metadata
            let model = MediaItem(
                id: metadata.id,
                captureDate: metadata.exactCaptureDate,
                latitude: metadata.latitude,
                longitude: metadata.longitude,
                kind: metadata.kind,
                width: metadata.width,
                height: metadata.height,
                source: .file,
                title: metadata.fileName,
                tripID: organized.tripID,
                trip: tripModels[organized.tripID],
                originalBookmarkData: metadata.bookmarkData,
                originalFileName: metadata.fileName,
                originalContentHash: metadata.contentHash,
                captureDateSourceRaw: metadata.captureDateSource.rawValue,
                localTimeZoneOffsetMinutes: metadata.timeZoneOffsetMinutes,
                localDayKey: organized.localDayKey,
                duration: metadata.duration,
                importReviewReasonsRaw: organized.reasons.map(\.rawValue).joined(separator: ","),
                importedAt: .now,
                originalCaptureDateUTC: metadata.exactCaptureDate,
                captureDateHintUTC: metadata.dateHintUTC,
                timeZoneIdentifier: organized.timeZoneIdentifier,
                timeConfidenceRaw: metadata.timeConfidence.rawValue,
                sourceReferencesRaw: sourceReferencesJSON(metadata.sourceReferences),
                pairedVideoContentHash: metadata.pairedVideoContentHash,
                pairedVideoBookmarkData: metadata.pairedVideoBookmarkData,
                perceptualHash: metadata.perceptualHash,
                reviewDecisionRaw: organized.reasons.isEmpty ? ImportReviewDecision.accepted.rawValue : ImportReviewDecision.pending.rawValue
            )
            model.place = organized.placeID.flatMap { placeModels[$0] }
            context.insert(model)
            progress(ImportProgress(phase: .saving, completed: index + 1, total: fresh.count, message: String(localized: "Saving import")))
        }
        try context.save()
        progress(ImportProgress(phase: .finished, completed: fresh.count, total: fresh.count, message: String(localized: "Import complete")))

        let summaries = plan.trips.map { trip in
            ImportTripSummary(id: trip.id, name: trip.name, itemCount: trip.itemIDs.count, startDate: trip.startDate, endDate: trip.endDate, isSuggestion: true)
        }
        return ImportSummary(
            importedCount: fresh.count,
            skippedCount: skippedCount,
            tripCount: plan.trips.count,
            placeCount: plan.places.count,
            collectionCount: plan.collectionCount,
            routeCount: plan.routeCount,
            trips: summaries,
            flags: plan.flags,
            conflicts: plan.conflicts
        )
    }

    private func scan(_ folderURL: URL) -> [URL] {
        let supportedExtensions: Set<String> = ["jpg", "jpeg", "heic", "png", "mov", "mp4"]
        // Extension filtering avoids a LaunchServices content-type lookup,
        // which is unavailable for synthetic files in a test host.
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            if supportedExtensions.contains(url.pathExtension.lowercased()) { urls.append(url) }
        }
        return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func coalesceDuplicatesAndLivePairs(_ metadata: [ImportedMediaMetadata]) -> [ImportedMediaMetadata] {
        var byHash: [String: ImportedMediaMetadata] = [:]
        var order: [String] = []
        for item in metadata {
            if let existing = byHash[item.contentHash] {
                let references = existing.sourceReferences + item.sourceReferences
                byHash[item.contentHash] = existing.replacing(sourceReferences: references)
            } else {
                byHash[item.contentHash] = item
                order.append(item.contentHash)
            }
        }
        let unique = order.compactMap { byHash[$0] }
        var liveByPhotoID: [String: ImportedMediaMetadata] = [:]
        var consumedVideoIDs = Set<String>()
        var consumedPhotoIDs = Set<String>()
        for video in unique where video.kind == .video {
            let candidates = unique.filter { photo in
                guard (photo.kind == .photo || photo.kind == .live),
                      !consumedPhotoIDs.contains(photo.id),
                      photo.baseName.caseInsensitiveCompare(video.baseName) == .orderedSame,
                      photo.parentDirectoryKey == video.parentDirectoryKey else { return false }
                guard abs(photo.captureDate.timeIntervalSince(video.captureDate)) <= 3 else { return false }
                if let photoIdentifier = photo.appleContentIdentifier,
                   let videoIdentifier = video.appleContentIdentifier {
                    return photoIdentifier == videoIdentifier
                }
                return true
            }
            guard let photo = candidates.min(by: { lhs, rhs in
                let leftGap = abs(lhs.captureDate.timeIntervalSince(video.captureDate))
                let rightGap = abs(rhs.captureDate.timeIntervalSince(video.captureDate))
                return leftGap == rightGap ? lhs.id < rhs.id : leftGap < rightGap
            }) else { continue }
            consumedVideoIDs.insert(video.id)
            consumedPhotoIDs.insert(photo.id)
            liveByPhotoID[photo.id] = photo.replacing(
                kind: .live,
                duration: video.duration,
                sourceReferences: photo.sourceReferences + video.sourceReferences,
                pairedVideoContentHash: video.contentHash,
                pairedVideoBookmarkData: video.bookmarkData
            )
        }
        return unique.compactMap { item in
            if consumedVideoIDs.contains(item.id) { return nil }
            return liveByPhotoID[item.id] ?? item
        }
    }

    private func sourceReferencesJSON(_ references: [ImportedSourceReference]) -> String? {
        guard let data = try? JSONEncoder().encode(references) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func sourceReferencesFromJSON(_ value: String?) -> [ImportedSourceReference] {
        guard let value, let data = value.data(using: .utf8),
              let references = try? JSONDecoder().decode([ImportedSourceReference].self, from: data) else { return [] }
        return references
    }
}

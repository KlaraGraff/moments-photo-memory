import CoreLocation
import Foundation
import MomentsCore
import SwiftData

struct CoreLocationImportGeocoder: ImportGeocoder {
    func reverseGeocode(coordinate: GeoPoint) async throws -> ImportGeocodeResult {
        // Keep the geocoder so a cancelled or timed-out lookup really stops:
        // the async CLGeocoder API ignores task cancellation.
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // A cancellation that lands before the request goes out can't cancel it.
        try Task.checkCancellation()
        let placemarks: [CLPlacemark]
        do {
            placemarks = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CLPlacemark], Error>) in
                    geocoder.reverseGeocodeLocation(location) { placemarks, error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: placemarks ?? []) }
                    }
                }
            } onCancel: {
                geocoder.cancelGeocode()
            }
        } catch CLError.geocodeFoundNoResult {
            // Open sea or remote land: a lasting answer, not a failure to retry.
            placemarks = []
        }
        guard let placemark = placemarks.first else { return ImportGeocodeResult() }
        return ImportGeocodeResult(
            city: placemark.locality ?? placemark.subAdministrativeArea,
            area: placemark.administrativeArea,
            spot: placemark.name,
            timeZoneIdentifier: placemark.timeZone?.identifier,
            country: placemark.country
        )
    }
}

enum FolderImportError: LocalizedError {
    case notDirectory(URL)
    case noSupportedMedia
    case noSupportedFiles

    var errorDescription: String? {
        switch self {
        case .noSupportedFiles: return String(localized: "None of these files are photos or videos Moments can import.")
        case .notDirectory(let url): return String(localized: "The selected item is not a folder.") + " " + url.lastPathComponent
        case .noSupportedMedia: return String(localized: "No supported photos or videos were found in the folder.")
        }
    }
}

struct FolderImporter {
    /// Reads one file's metadata and content hash: the slow part of an import.
    let readMetadata: @Sendable (URL) async throws -> ImportedMediaMetadata
    let configuration: ImportConfiguration
    let geocoder: any ImportGeocoder
    let geocodeCache: ImportGeocodeCache
    /// true: look up now; false: leave the place to the background backfill.
    let geocodeDelay: @Sendable () async -> Bool
    /// Waits until one time-zone lookup may start. Time-zone cells are few
    /// (half-degree cells) and a wrong zone moves the capture date, so the
    /// import waits for them. Place names can come later.
    let timeZoneDelay: @Sendable () async -> Void
    /// What this folder's earlier, unfinished imports already read.
    let resumeStore: ImportResumeStore
    /// Files read between two checkpoint writes.
    let resumeBatchSize: Int

    init(
        configuration: ImportConfiguration = ImportConfiguration(),
        geocoder: any ImportGeocoder = CoreLocationImportGeocoder(),
        geocodeCache: ImportGeocodeCache? = nil,
        geocodeDelay: @escaping @Sendable () async -> Bool = {
            await ImportGeocodePacer.shared.startIfRoom()
        },
        timeZoneDelay: @escaping @Sendable () async -> Void = {
            await ImportGeocodePacer.shared.wait()
        },
        resumeStore: ImportResumeStore = .shared,
        resumeBatchSize: Int = 200,
        readMetadata: @escaping @Sendable (URL) async throws -> ImportedMediaMetadata = { url in
            try await MediaMetadataReader().read(url: url)
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
        self.timeZoneDelay = timeZoneDelay
        self.resumeStore = resumeStore
        self.resumeBatchSize = max(1, resumeBatchSize)
        self.readMetadata = readMetadata
    }

    /// Imports every photo and video in a folder and its subfolders.
    /// `relocatingSourceID` names an imported folder that moved: this folder
    /// is its new place, so the source and its photos' bookmarks point here
    /// from now on.
    func importFolder(
        _ folderURL: URL,
        relocatingSourceID: String? = nil,
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
        return try await importMedia(scan(folderURL), from: folderURL, relocatingSourceID: relocatingSourceID, container: container, progress: progress)
    }

    /// Imports some files of one folder, as when they are dropped on the
    /// window. The folder is recorded as their source.
    func importFiles(
        _ files: [URL],
        in folderURL: URL,
        container: ModelContainer,
        progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }
    ) async throws -> ImportSummary {
        let urls = SupportedMediaFile.droppingRawCompanions(files.filter { url in
            SupportedMediaFile.isSupported(pathExtension: url.pathExtension)
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        })
        return try await importMedia(urls, from: folderURL, relocatingSourceID: nil, container: container, progress: progress)
    }

    private func importMedia(
        _ urls: [URL],
        from folderURL: URL,
        relocatingSourceID: String?,
        container: ModelContainer,
        progress: @escaping @Sendable (ImportProgress) -> Void
    ) async throws -> ImportSummary {
        guard !urls.isEmpty else { throw FolderImportError.noSupportedMedia }
        progress(ImportProgress(phase: .scanning, completed: urls.count, total: urls.count, message: String(localized: "Found media files")))

        let folderKey = Self.folderKey(folderURL)
        let metadata = try await readAll(urls, folderKey: folderKey, progress: progress)
        guard !metadata.isEmpty else { throw FolderImportError.noSupportedMedia }
        let organizer = ImportOrganizer(
            configuration: configuration,
            geocoder: geocoder,
            geocodeCache: geocodeCache,
            geocodeDelay: geocodeDelay,
            timeZoneDelay: timeZoneDelay,
            geocodeProgress: { done, budget in
                progress(ImportProgress(phase: .organizing, completed: done, total: budget, message: String(localized: "Looking up places")))
            }
        )
        let resolvedMetadata = try await organizer.resolveCaptureDates(metadata)
        let organizedMetadata = coalesceDuplicatesAndLivePairs(resolvedMetadata)
        let sourceFileCount = organizedMetadata.reduce(into: 0) { $0 += $1.sourceReferences.count }

        let context = ModelContext(container)
        let relocated = relocatingSourceID.flatMap { ImportSources.relocate(sourceID: $0, to: folderURL, context: context) }
        let source = relocated ?? ImportSources.folderSource(for: folderURL, context: context)
        let existing = try context.fetch(FetchDescriptor<MediaItem>())
        let existingHashes = Set(existing.compactMap(\.originalContentHash))
        let existingIDs = Set(existing.map(\.id))
        let existingByHash = Dictionary(existing.compactMap { item in
            item.originalContentHash.map { ($0, item) }
        }, uniquingKeysWith: { first, _ in first })
        // The source is new or touched (last import date) on every run.
        var didUpdateSourceMappings = true
        // Importing a folder again brings back its photos that were in
        // Recently Deleted: choosing the folder says "I want these".
        var recovered: [MediaItem] = []
        var recoveredSourceCount = 0
        for item in organizedMetadata where existingHashes.contains(item.contentHash) || existingIDs.contains(item.id) {
            guard let existingItem = existingByHash[item.contentHash] ?? existing.first(where: { $0.id == item.id }) else { continue }
            let oldReferences = sourceReferencesFromJSON(existingItem.sourceReferencesRaw)
            let merged = Array(Set(oldReferences + item.sourceReferences)).sorted { $0.fileName < $1.fileName }
            if merged.count > oldReferences.count {
                existingItem.sourceReferencesRaw = sourceReferencesJSON(merged)
            }
            if relocated != nil, existingItem.importSourceIDs.contains(source.id), existingItem.source == .file {
                // The moved folder's photo: open it from its new place.
                existingItem.originalBookmarkData = item.bookmarkData
                if item.pairedVideoBookmarkData != nil {
                    existingItem.pairedVideoBookmarkData = item.pairedVideoBookmarkData
                }
                existingItem.updatedAt = .now
            }
            existingItem.addImportSource(source.id)
            if existingItem.deletedAt != nil, RecentlyDeleted.canDelete(existingItem), !recovered.contains(where: { $0 === existingItem }) {
                recovered.append(existingItem)
                // This run's files for it, not ones found in other folders.
                recoveredSourceCount += item.sourceReferences.count
            }
        }
        for item in recovered {
            item.deletedAt = nil
            item.deletedBy = nil
            item.updatedAt = .now
        }
        let fresh = organizedMetadata.filter { !existingHashes.contains($0.contentHash) && !existingIDs.contains($0.id) }
        let freshSourceCount = fresh.reduce(into: 0) { $0 += $1.sourceReferences.count }
        let skippedCount = max(0, sourceFileCount - freshSourceCount - recoveredSourceCount)
        if fresh.isEmpty {
            await geocodeCache.persist()
            if didUpdateSourceMappings { try context.save() }
            await resumeStore.remove(forFolder: folderKey)
            return ImportSummary(importedCount: recovered.count, skippedCount: skippedCount, tripCount: 0, placeCount: 0, collectionCount: 0, routeCount: 0, trips: [], flags: [])
        }

        progress(ImportProgress(phase: .organizing, completed: 0, total: fresh.count, message: String(localized: "Organizing trips and places")))
        let plan = try await organizer.organize(
            fresh,
            sourceFolderName: folderURL.lastPathComponent,
            library: ImportOrganizer.libraryStops(existing)
        )
        await geocodeCache.persist()
        try Task.checkCancellation()

        // The same photo may already be in the library from Apple Photos.
        // Such files are flagged for review, never merged (#40).
        let photosDuplicateIDs = CrossSourceDuplicates.matcher.matchingIDs(
            plan.media.compactMap { CrossSourceDuplicates.candidate(for: $0.metadata) },
            against: CrossSourceDuplicates.candidates(in: existing, from: .photos)
        )
        let duplicateFlags = plan.media.filter { photosDuplicateIDs.contains($0.metadata.id) }.map { organized in
            ImportReviewFlag(
                id: organized.metadata.id,
                fileName: organized.metadata.fileName,
                reasons: [.nearDuplicate],
                detail: String(localized: "This file may also be present in an Apple Photos import."),
                decision: .pending
            )
        }

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
            var reasons = organized.reasons
            if photosDuplicateIDs.contains(metadata.id), !reasons.contains(.nearDuplicate) { reasons.append(.nearDuplicate) }
            let model = MediaItem(
                id: metadata.id,
                captureDate: metadata.exactCaptureDate,
                latitude: metadata.latitude,
                longitude: metadata.longitude,
                kind: metadata.kind,
                width: metadata.width,
                height: metadata.height,
                isScreenshot: ScreenshotFileName.looksLikeScreenshot(metadata.fileName),
                source: .file,
                title: metadata.fileName,
                tripID: organized.tripID,
                trip: organized.tripID.flatMap { tripModels[$0] },
                originalBookmarkData: metadata.bookmarkData,
                originalFileName: metadata.fileName,
                originalContentHash: metadata.contentHash,
                captureDateSourceRaw: metadata.captureDateSource.rawValue,
                localTimeZoneOffsetMinutes: metadata.timeZoneOffsetMinutes,
                localDayKey: organized.localDayKey,
                duration: metadata.duration,
                importReviewReasonsRaw: reasons.map(\.rawValue).joined(separator: ","),
                importedAt: .now,
                originalCaptureDateUTC: metadata.exactCaptureDate,
                captureDateHintUTC: metadata.dateHintUTC,
                timeZoneIdentifier: organized.timeZoneIdentifier,
                timeConfidenceRaw: organized.timeConfidence.rawValue,
                sourceReferencesRaw: sourceReferencesJSON(metadata.sourceReferences),
                pairedVideoContentHash: metadata.pairedVideoContentHash,
                pairedVideoBookmarkData: metadata.pairedVideoBookmarkData,
                perceptualHash: metadata.perceptualHash,
                reviewDecisionRaw: reasons.isEmpty ? ImportReviewDecision.accepted.rawValue : ImportReviewDecision.pending.rawValue
            )
            model.place = organized.placeID.flatMap { placeModels[$0] }
            model.importSourceIDsRaw = source.id
            context.insert(model)
            progress(ImportProgress(phase: .saving, completed: index + 1, total: fresh.count, message: String(localized: "Saving import")))
        }
        try context.save()
        // Saved: the next import of this folder starts afresh.
        await resumeStore.remove(forFolder: folderKey)
        progress(ImportProgress(phase: .finished, completed: fresh.count, total: fresh.count, message: String(localized: "Import complete")))

        let summaries = plan.trips.map { trip in
            ImportTripSummary(id: trip.id, name: trip.name, itemCount: trip.itemIDs.count, startDate: trip.startDate, endDate: trip.endDate, isSuggestion: true)
        }
        return ImportSummary(
            importedCount: fresh.count + recovered.count,
            skippedCount: skippedCount,
            tripCount: plan.trips.count,
            placeCount: plan.places.count,
            collectionCount: plan.collectionCount,
            routeCount: plan.routeCount,
            trips: summaries,
            flags: CrossSourceDuplicates.mergeFlags(plan.flags, duplicateFlags),
            conflicts: plan.conflicts
        )
    }

    /// Reads every file, reusing what an earlier unfinished import of this
    /// folder already read for files whose size and modification time have
    /// not changed, so those are not hashed again. New reads are checkpointed
    /// every `resumeBatchSize` files, on cancellation, and once all files are
    /// read, so cancelling later (while organizing or saving) keeps them too.
    private func readAll(
        _ urls: [URL],
        folderKey: String,
        progress: @escaping @Sendable (ImportProgress) -> Void
    ) async throws -> [ImportedMediaMetadata] {
        let saved = await resumeStore.entries(forFolder: folderKey)
        // Reads since the last checkpoint write.
        var pending: [String: ImportResumeEntry] = [:]
        var metadata: [ImportedMediaMetadata] = []
        metadata.reserveCapacity(urls.count)
        do {
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                let fingerprint = ImportFileFingerprint(url: url)
                let key = url.standardizedFileURL.path
                if let fingerprint, let entry = saved[key], entry.fingerprint == fingerprint {
                    metadata.append(entry.metadata)
                } else {
                    do {
                        let read = try await readMetadata(url)
                        metadata.append(read)
                        // A changed file's new entry replaces its old one.
                        if let fingerprint {
                            pending[key] = ImportResumeEntry(fingerprint: fingerprint, metadata: read)
                        }
                    } catch {
                        // A single malformed file should not discard an otherwise valid folder.
                    }
                }
                if pending.count >= resumeBatchSize {
                    await resumeStore.append(pending, forFolder: folderKey)
                    pending.removeAll(keepingCapacity: true)
                }
                progress(ImportProgress(phase: .readingMetadata, completed: index + 1, total: urls.count, message: String(localized: "Reading metadata")))
            }
        } catch {
            // Cancelled: keep this run's reads, so a resume skips them too.
            await resumeStore.append(pending, forFolder: folderKey)
            throw error
        }
        await resumeStore.append(pending, forFolder: folderKey)
        return metadata
    }

    static func folderKey(_ folderURL: URL) -> String {
        folderURL.standardizedFileURL.path
    }

    private func scan(_ folderURL: URL) -> [URL] {
        // Extension filtering avoids a LaunchServices content-type lookup,
        // which is unavailable for synthetic files in a test host.
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            if SupportedMediaFile.isSupported(pathExtension: url.pathExtension) { urls.append(url) }
        }
        return SupportedMediaFile.droppingRawCompanions(urls)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
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

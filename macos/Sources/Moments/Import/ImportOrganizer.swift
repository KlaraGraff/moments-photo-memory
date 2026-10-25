import Foundation
import MomentsCore

public actor ImportGeocodeCache {
    private var values: [String: ImportGeocodeResult]
    private let fileURL: URL?

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: ImportGeocodeResult].self, from: data) {
            values = decoded
        } else {
            values = [:]
        }
    }

    public func result(for coordinate: GeoPoint) -> ImportGeocodeResult? {
        values[key(for: coordinate)]
    }

    public func insert(_ result: ImportGeocodeResult, for coordinate: GeoPoint) {
        values[key(for: coordinate)] = result
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(values) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func key(for coordinate: GeoPoint) -> String {
        String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
    }
}

struct OrganizedPlace: Equatable, Sendable {
    let id: String
    let name: String
    let kind: PlaceKind
    let latitude: Double?
    let longitude: Double?
    let parentID: String?
}

struct OrganizedMedia: Equatable, Sendable {
    let metadata: ImportedMediaMetadata
    let tripID: String
    let placeID: String?
    let suggestedPlaceID: String?
    let suggestedPlaceName: String?
    let localDayKey: String
    let timeZoneIdentifier: String?
    let reasons: [ImportReviewReason]
    let reviewDetail: String?
}

struct OrganizedTrip: Equatable, Sendable {
    let id: String
    let name: String
    let startDate: Date?
    let endDate: Date?
    let itemIDs: [String]
}

struct OrganizedImportPlan: Equatable, Sendable {
    let media: [OrganizedMedia]
    let trips: [OrganizedTrip]
    let places: [OrganizedPlace]
    let collectionCount: Int
    let routeCount: Int
    let flags: [ImportReviewFlag]
    let conflicts: [ImportConflictEvent]
}

struct ImportOrganizer {
    let configuration: ImportConfiguration
    let geocoder: any ImportGeocoder
    let geocodeCache: ImportGeocodeCache

    func organize(_ metadata: [ImportedMediaMetadata]) async throws -> OrganizedImportPlan {
        guard !metadata.isEmpty else {
            return OrganizedImportPlan(media: [], trips: [], places: [], collectionCount: 0, routeCount: 0, flags: [], conflicts: [])
        }

        let ordered = metadata.sorted { lhs, rhs in
            lhs.captureDate == rhs.captureDate ? lhs.id < rhs.id : lhs.captureDate < rhs.captureDate
        }
        let tripGroups = splitTrips(ordered)
        var allMedia: [OrganizedMedia] = []
        var trips: [OrganizedTrip] = []
        var places: [OrganizedPlace] = []
        var allFlags: [ImportReviewFlag] = []
        let conflicts = ImportConflictDetector(configuration: configuration.conflictConfiguration).detect(metadata)
        let conflictsByItemID = conflicts.reduce(into: [String: [ImportConflictEvent]]()) { result, event in
            for itemID in event.itemIDs { result[itemID, default: []].append(event) }
        }
        let nearDuplicateIDs = nearDuplicateIDs(in: ordered)
        var outsideDateIDs = Set<String>()
        for index in 1..<tripGroups.count {
            guard let previous = tripGroups[index - 1].last,
                  let current = tripGroups[index].first else { continue }
            if current.captureDate.timeIntervalSince(previous.captureDate) > configuration.captureDateConflictThreshold {
                outsideDateIDs.insert(current.id)
            }
        }

        for (index, group) in tripGroups.enumerated() {
            try Task.checkCancellation()
            let tripID = stableID(prefix: "trip", ids: group.map(\.id))
            let tripName = Self.defaultTripName(for: group.first?.captureDate, index: index + 1)
            let stops = group.compactMap { item -> PhotoStop? in
                guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
                return PhotoStop(id: item.id, date: item.captureDate, coordinate: GeoPoint(latitude: latitude, longitude: longitude))
            }
            let clusterer = PlaceClusterer(maximumTimeGap: configuration.maximumTimeGap)
            let spotClusters = clusterer.clusters(for: stops, level: .spot)
            let areaClusters = clusterer.clusters(for: stops, level: .area)
            let cityClusters = clusterer.clusters(for: stops, level: .city)
            let cityNames = try await cityNames(for: cityClusters)

            let cityByStop = clusterMap(cityClusters)
            let areaByStop = clusterMap(areaClusters)
            let spotByStop = clusterMap(spotClusters)
            var placeByID: [String: OrganizedPlace] = [:]
            for cluster in cityClusters {
                let name = cityNames[cluster.id]?.city ?? String(localized: "Unknown city")
                placeByID[cluster.id] = OrganizedPlace(
                    id: cluster.id,
                    name: name,
                    kind: .city,
                    latitude: cluster.center?.latitude,
                    longitude: cluster.center?.longitude,
                    parentID: nil
                )
            }
            for cluster in areaClusters {
                let parent = cluster.stopIDs.compactMap { cityByStop[$0]?.id }.first
                placeByID[cluster.id] = OrganizedPlace(
                    id: cluster.id,
                    name: cityNames[parent ?? ""]?.area ?? String(localized: "Unknown area"),
                    kind: .area,
                    latitude: cluster.center?.latitude,
                    longitude: cluster.center?.longitude,
                    parentID: parent
                )
            }
            for cluster in spotClusters {
                let parent = cluster.stopIDs.compactMap { areaByStop[$0]?.id }.first
                placeByID[cluster.id] = OrganizedPlace(
                    id: cluster.id,
                    name: String(localized: "Spot") + " " + String(cluster.id.suffix(6)),
                    kind: .spot,
                    latitude: cluster.center?.latitude,
                    longitude: cluster.center?.longitude,
                    parentID: parent
                )
            }
            places.append(contentsOf: placeByID.values)

            for item in group {
                let coordinate = item.latitude.flatMap { latitude in
                    item.longitude.map { longitude in GeoPoint(latitude: latitude, longitude: longitude) }
                }
                var reasons: [ImportReviewReason] = []
                var detailParts: [String] = []
                if coordinate == nil { reasons.append(.missingLocation) }
                if item.captureDateSource == .fileDateFallback {
                    reasons.append(.fileDateFallback)
                    reasons.append(.needsDate)
                }
                if item.isAirDropLike {
                    reasons.append(.airDropReceived)
                    detailParts.append("The file name suggests a received/shared copy; check its date and place.")
                }
                if isGPSJump(item: item, in: ordered) { reasons.append(.gpsJump) }
                if outsideDateIDs.contains(item.id) || isCaptureDateOutsideTrip(item: item, in: group) {
                    reasons.append(.captureDateOutsideTrip)
                }
                if nearDuplicateIDs.contains(item.id) { reasons.append(.nearDuplicate) }
                for event in conflictsByItemID[item.id] ?? [] {
                    switch event.kind {
                    case .transport:
                        reasons.append(.transportCandidate)
                    case .noPhotosGap:
                        reasons.append(.noPhotosGap)
                    default:
                        reasons.append(.timePlaceConflict)
                    }
                    detailParts.append(event.detail)
                }
                reasons = Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
                let city = cityByStop[item.id].flatMap { cityNames[$0.id] }
                let suggested = nearestPlaceSuggestion(for: item, in: group, spotByStop: spotByStop)
                let suggestedName = suggested.flatMap { placeByID[$0]?.name }
                let timeZoneIdentifier = item.timeZoneIdentifier
                    ?? city?.timeZoneIdentifier
                    ?? nearestTimeZoneIdentifier(for: item, in: group)
                    ?? TimeZone.autoupdatingCurrent.identifier
                let dayKey = localDayKey(for: item, timeZoneIdentifier: timeZoneIdentifier)
                let placeID = item.latitude.flatMap { latitude in
                    item.longitude.flatMap { longitude in
                        spotByStop[item.id]?.id ?? cityByStop[item.id]?.id
                    }
                }
                let reviewDetail = detailParts.isEmpty ? nil : Array(Set(detailParts)).joined(separator: " ")
                allMedia.append(OrganizedMedia(
                    metadata: item,
                    tripID: tripID,
                    placeID: placeID,
                    suggestedPlaceID: placeID == nil ? suggested : nil,
                    suggestedPlaceName: placeID == nil ? suggestedName : nil,
                    localDayKey: dayKey,
                    timeZoneIdentifier: timeZoneIdentifier,
                    reasons: reasons,
                    reviewDetail: reviewDetail
                ))
                if !reasons.isEmpty {
                    allFlags.append(ImportReviewFlag(
                        id: item.id,
                        fileName: item.fileName,
                        reasons: reasons,
                        detail: reviewDetail,
                        suggestedDayKey: dayKey,
                        suggestedPlaceName: suggestedName
                    ))
                }
            }
            trips.append(OrganizedTrip(
                id: tripID,
                name: tripName,
                startDate: group.compactMap(\.exactCaptureDate).min(),
                endDate: group.compactMap(\.exactCaptureDate).max(),
                itemIDs: group.map(\.id)
            ))
        }

        let descriptors = metadata.map {
            MediaDescriptor(id: $0.id, captureDate: $0.captureDate, pixelWidth: $0.width, pixelHeight: $0.height, fileNameHint: $0.fileName)
        }
        let collectionCount = CollectionGrouper().group(descriptors).count
        let routeCount = trips.reduce(into: 0) { result, trip in
            let stops = trip.itemIDs.compactMap { id -> PhotoStop? in
                guard let item = metadata.first(where: { $0.id == id }), let latitude = item.latitude, let longitude = item.longitude else { return nil }
                return PhotoStop(id: id, date: item.captureDate, coordinate: GeoPoint(latitude: latitude, longitude: longitude))
            }
            result += RouteBuilder(
                stops: stops,
                clusterer: PlaceClusterer(maximumTimeGap: configuration.maximumTimeGap)
            ).overview().count
        }
        return OrganizedImportPlan(
            media: allMedia.sorted { $0.metadata.id < $1.metadata.id },
            trips: trips,
            places: places.sorted { $0.id < $1.id },
            collectionCount: collectionCount,
            routeCount: routeCount,
            flags: allFlags.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending },
            conflicts: conflicts
        )
    }

    private func splitTrips(_ ordered: [ImportedMediaMetadata]) -> [[ImportedMediaMetadata]] {
        var groups: [[ImportedMediaMetadata]] = []
        var current: [ImportedMediaMetadata] = []
        for item in ordered {
            if let previous = current.last,
               shouldSplit(previous: previous, current: item) {
                groups.append(current)
                current = []
            }
            current.append(item)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private func shouldSplit(previous: ImportedMediaMetadata, current: ImportedMediaMetadata) -> Bool {
        if current.captureDate.timeIntervalSince(previous.captureDate) > configuration.maximumTimeGap { return true }
        guard let lhs = coordinate(for: previous), let rhs = coordinate(for: current) else { return false }
        if lhs.distance(to: rhs) > configuration.maximumTripDistanceMeters { return true }
        if let home = configuration.homeCoordinate,
           (lhs.distance(to: home) <= configuration.maximumTripDistanceMeters)
                != (rhs.distance(to: home) <= configuration.maximumTripDistanceMeters) {
            return true
        }
        return false
    }

    private func isGPSJump(item: ImportedMediaMetadata, in ordered: [ImportedMediaMetadata]) -> Bool {
        guard let index = ordered.firstIndex(where: { $0.id == item.id }) else { return false }
        guard index > 0, index + 1 < ordered.count else { return false }
        let before = ordered[index - 1]
        let after = ordered[index + 1]
        guard let first = coordinate(for: before), let middle = coordinate(for: item), let last = coordinate(for: after) else { return false }
        let withinHour = abs(item.captureDate.timeIntervalSince(before.captureDate)) <= configuration.gpsJumpMaximumTimeGap
            && abs(after.captureDate.timeIntervalSince(item.captureDate)) <= configuration.gpsJumpMaximumTimeGap
        return withinHour && first.distance(to: middle) > configuration.gpsJumpDistanceMeters
            && middle.distance(to: last) > configuration.gpsJumpDistanceMeters
            && first.distance(to: last) <= configuration.gpsJumpDistanceMeters
    }

    private func isCaptureDateOutsideTrip(item: ImportedMediaMetadata, in group: [ImportedMediaMetadata]) -> Bool {
        guard group.count > 1,
              let index = group.firstIndex(where: { $0.id == item.id }) else { return false }
        let neighbours = [index > 0 ? group[index - 1] : nil, index + 1 < group.count ? group[index + 1] : nil].compactMap { $0 }
        return neighbours.contains { abs(item.captureDate.timeIntervalSince($0.captureDate)) > configuration.captureDateConflictThreshold }
    }

    private func coordinate(for item: ImportedMediaMetadata) -> GeoPoint? {
        guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    private func localDayKey(for item: ImportedMediaMetadata, timeZoneIdentifier: String?) -> String {
        var calendar = Calendar(identifier: .gregorian)
        if let offset = item.timeZoneOffsetMinutes,
           let timeZone = TimeZone(secondsFromGMT: offset * 60) {
            calendar.timeZone = timeZone
        } else if let timeZoneIdentifier,
                  let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            calendar.timeZone = timeZone
        } else {
            calendar.timeZone = .autoupdatingCurrent
        }
        let components = calendar.dateComponents([.year, .month, .day], from: item.captureDate)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func cityNames(for clusters: [PlaceCluster]) async throws -> [String: ImportGeocodeResult] {
        var values: [String: ImportGeocodeResult] = [:]
        for cluster in clusters {
            try Task.checkCancellation()
            guard let center = cluster.center else { continue }
            if let cached = await geocodeCache.result(for: center) {
                values[cluster.id] = cached
                continue
            }
            let result = try await geocoder.reverseGeocode(coordinate: center)
            await geocodeCache.insert(result, for: center)
            values[cluster.id] = result
        }
        return values
    }

    private func clusterMap(_ clusters: [PlaceCluster]) -> [String: PlaceCluster] {
        clusters.reduce(into: [:]) { result, cluster in
            for stopID in cluster.stopIDs { result[stopID] = cluster }
        }
    }

    private func nearDuplicateIDs(in ordered: [ImportedMediaMetadata]) -> Set<String> {
        let groups = Dictionary(grouping: ordered) { item in
            "\(item.captureDate.timeIntervalSinceReferenceDate)|\(item.width)x\(item.height)"
        }
        return groups.values
            .filter { $0.count > 1 }
            .flatMap { $0.map(\.id) }
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    private func nearestPlaceSuggestion(
        for item: ImportedMediaMetadata,
        in group: [ImportedMediaMetadata],
        spotByStop: [String: PlaceCluster]
    ) -> String? {
        guard item.latitude == nil || item.longitude == nil else { return nil }
        return group
            .filter { $0.latitude != nil && $0.longitude != nil }
            .min { abs($0.captureDate.timeIntervalSince(item.captureDate)) < abs($1.captureDate.timeIntervalSince(item.captureDate)) }
            .flatMap { spotByStop[$0.id]?.id }
    }

    private func nearestTimeZoneIdentifier(for item: ImportedMediaMetadata, in group: [ImportedMediaMetadata]) -> String? {
        group
            .filter { $0.timeZoneIdentifier != nil }
            .min { abs($0.captureDate.timeIntervalSince(item.captureDate)) < abs($1.captureDate.timeIntervalSince(item.captureDate)) }?
            .timeZoneIdentifier
    }

    private static func defaultTripName(for date: Date?, index: Int) -> String {
        guard let date else { return String(localized: "Trip") + " " + String(index) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return String(localized: "Trip") + " " + formatter.string(from: date)
    }

    private func stableID(prefix: String, ids: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in (prefix + "\u{0}" + ids.sorted().joined(separator: "\u{0}")).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(prefix)-\(String(hash, radix: 16))"
    }
}

import Foundation

/// The small set of media fields needed by every large-library screen.
/// SwiftData models are deliberately not allowed to cross the projection
/// boundary; these values are safe to build on a background context.
public struct LibraryPhotoDescriptor: Equatable, Hashable, Sendable {
    public enum Kind: String, Equatable, Hashable, Sendable {
        case photo
        case video
        case live
    }

    public let id: String
    public let captureDate: Date?
    public let dayKey: String?
    public let monthKey: String?
    public let latitude: Double?
    public let longitude: Double?
    public let placeID: String?
    public let placeName: String?
    public let tripID: String?
    public let kind: Kind
    public let isScreenshot: Bool
    public let isFavorite: Bool
    public let hasMemory: Bool
    public let title: String

    public init(
        id: String,
        captureDate: Date? = nil,
        dayKey: String? = nil,
        monthKey: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        placeID: String? = nil,
        placeName: String? = nil,
        tripID: String? = nil,
        kind: Kind = .photo,
        isScreenshot: Bool = false,
        isFavorite: Bool = false,
        hasMemory: Bool = false,
        title: String = ""
    ) {
        self.id = id
        self.captureDate = captureDate
        self.dayKey = dayKey
        self.monthKey = monthKey
        self.latitude = latitude
        self.longitude = longitude
        self.placeID = placeID
        self.placeName = placeName
        self.tripID = tripID
        self.kind = kind
        self.isScreenshot = isScreenshot
        self.isFavorite = isFavorite
        self.hasMemory = hasMemory
        self.title = title
    }

    public var stop: PhotoStop? {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite else { return nil }
        return PhotoStop(id: id, date: captureDate ?? .distantPast, coordinate: GeoPoint(latitude: latitude, longitude: longitude))
    }
}

public struct LibraryPlaceDescriptor: Equatable, Hashable, Sendable {
    public let id: String
    public let name: String?
    public let latitude: Double?
    public let longitude: Double?

    public init(id: String, name: String? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    public var point: GeoPoint? {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }
}

public struct LibraryProjectionFilter: Equatable, Sendable {
    public var fromDate: Date?
    public var toDate: Date?
    public var placeID: String?
    public var tripID: String?
    public var kind: LibraryPhotoDescriptor.Kind?
    public var favoritesOnly: Bool
    public var screenshotsOnly: Bool
    public var memoriesOnly: Bool
    public var searchText: String

    public init(
        fromDate: Date? = nil,
        toDate: Date? = nil,
        placeID: String? = nil,
        tripID: String? = nil,
        kind: LibraryPhotoDescriptor.Kind? = nil,
        favoritesOnly: Bool = false,
        screenshotsOnly: Bool = false,
        memoriesOnly: Bool = false,
        searchText: String = ""
    ) {
        self.fromDate = fromDate
        self.toDate = toDate
        self.placeID = placeID
        self.tripID = tripID
        self.kind = kind
        self.favoritesOnly = favoritesOnly
        self.screenshotsOnly = screenshotsOnly
        self.memoriesOnly = memoriesOnly
        self.searchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct LibraryProjection: Equatable, Sendable {
    public let photos: [LibraryPhotoDescriptor]
    public let photoByID: [String: LibraryPhotoDescriptor]
    public let dayPhotoIDs: [String: [String]]
    public let monthPhotoIDs: [String: [String]]
    public let mapStops: [PhotoStop]
    public let places: [LibraryPlaceDescriptor]
    public let placeIndex: LibraryPlaceIndex

    public init(
        photos: [LibraryPhotoDescriptor],
        places: [LibraryPlaceDescriptor] = []
    ) {
        let sorted = photos.sorted {
            let left = $0.captureDate ?? .distantPast
            let right = $1.captureDate ?? .distantPast
            if left != right { return left < right }
            return $0.id < $1.id
        }
        self.photos = sorted
        self.photoByID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
        self.dayPhotoIDs = Self.grouped(sorted, key: \.dayKey)
        self.monthPhotoIDs = Self.grouped(sorted, key: \.monthKey)
        self.mapStops = sorted.compactMap(\.stop)
        self.places = places
        self.placeIndex = LibraryPlaceIndex(places: places)
    }

    public static let empty = LibraryProjection(photos: [])

    public func matchingIDs(_ filter: LibraryProjectionFilter) -> [String] {
        let query = filter.searchText.localizedLowercase
        return photos.compactMap { photo in
            if let fromDate = filter.fromDate, (photo.captureDate ?? .distantPast) < fromDate { return nil }
            if let toDate = filter.toDate, (photo.captureDate ?? .distantPast) > toDate { return nil }
            if let placeID = filter.placeID, photo.placeID != placeID { return nil }
            if let tripID = filter.tripID, photo.tripID != tripID { return nil }
            if let kind = filter.kind, photo.kind != kind { return nil }
            if filter.favoritesOnly && !photo.isFavorite { return nil }
            if filter.screenshotsOnly && !photo.isScreenshot { return nil }
            if filter.memoriesOnly && !photo.hasMemory { return nil }
            if !query.isEmpty {
                let haystack = [photo.title, photo.placeName, photo.tripID].compactMap { $0 }.joined(separator: " ").localizedLowercase
                if !haystack.contains(query) { return nil }
            }
            return photo.id
        }
    }

    private static func grouped(
        _ photos: [LibraryPhotoDescriptor],
        key: KeyPath<LibraryPhotoDescriptor, String?>
    ) -> [String: [String]] {
        var groups: [String: [String]] = [:]
        for photo in photos {
            guard let value = photo[keyPath: key], !value.isEmpty else { continue }
            groups[value, default: []].append(photo.id)
        }
        return groups
    }
}

/// A coarse geographic index used by Timeline and Map fallbacks. Most lookups
/// inspect only a 3×3 cell neighbourhood instead of every stored place.
public struct LibraryPlaceIndex: Equatable, Sendable {
    private struct Cell: Hashable, Sendable {
        let latitude: Int
        let longitude: Int
    }

    private let cellSize = 1.0
    private let cells: [Cell: [LibraryPlaceDescriptor]]

    public init(places: [LibraryPlaceDescriptor]) {
        var cells: [Cell: [LibraryPlaceDescriptor]] = [:]
        for place in places {
            guard let point = place.point else { continue }
            let cell = Cell(latitude: Int(floor(point.latitude)), longitude: Int(floor(point.longitude)))
            cells[cell, default: []].append(place)
        }
        self.cells = cells
    }

    public func nearestName(to point: GeoPoint, within maxDistance: Double = 100_000) -> String? {
        let base = Cell(latitude: Int(floor(point.latitude)), longitude: Int(floor(point.longitude)))
        var nearest: (name: String, distance: Double)?
        for latitude in (base.latitude - 1)...(base.latitude + 1) {
            guard (-90...90).contains(latitude) else { continue }
            for rawLongitude in (base.longitude - 1)...(base.longitude + 1) {
                var longitude = rawLongitude
                if longitude < -180 { longitude += 360 }
                if longitude > 179 { longitude -= 360 }
                for place in cells[Cell(latitude: latitude, longitude: longitude)] ?? [] {
                    guard let name = place.name, !name.isEmpty, let placePoint = place.point else { continue }
                    let distance = point.distance(to: placePoint)
                    guard distance <= maxDistance, nearest == nil || distance < nearest!.distance else { continue }
                    nearest = (name, distance)
                }
            }
        }
        return nearest?.name
    }
}

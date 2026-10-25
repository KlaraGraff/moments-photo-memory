import Foundation
import MomentsCore

/// A value snapshot used by the timeline builder. Keeping SwiftData out of the
/// grouping layer makes the date and place rules deterministic in tests.
struct TimelineItemSnapshot: Identifiable, Equatable {
    let id: String
    let title: String
    let date: Date?
    let latitude: Double?
    let longitude: Double?
    let kindRaw: String
    let tripID: String?
    let placeHint: String?
    let memories: [TimelineMemorySnippet]

    init(
        id: String,
        title: String = "",
        date: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        kindRaw: String = MediaKind.photo.rawValue,
        tripID: String? = nil,
        placeHint: String? = nil,
        memories: [TimelineMemorySnippet] = []
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.latitude = latitude
        self.longitude = longitude
        self.kindRaw = kindRaw
        self.tripID = tripID
        self.placeHint = placeHint
        self.memories = memories
    }

    init(item: MediaItem, placeHint: String? = nil) {
        self.init(
            id: item.id,
            title: item.title,
            date: item.captureDate,
            latitude: item.latitude,
            longitude: item.longitude,
            kindRaw: item.kind.rawValue,
            tripID: item.tripKey,
            placeHint: placeHint,
            memories: item.memories
                .sorted { ($0.createdAt, $0.text) < ($1.createdAt, $1.text) }
                .enumerated()
                .map { index, memory in
                    TimelineMemorySnippet(
                        id: "\(item.id)-memory-\(index)",
                        text: memory.text,
                        authorRaw: memory.authorRaw
                    )
                }
        )
    }

    var coordinate: GeoPoint? {
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    var photoStop: PhotoStop? {
        guard let date else { return nil }
        return PhotoStop(id: id, date: date, coordinate: coordinate)
    }
}

struct TimelineMemorySnippet: Identifiable, Equatable {
    let id: String
    let text: String
    let authorRaw: String
}

struct TimelineSourceTrip: Identifiable, Equatable {
    let id: String
    let name: String
    let itemIDs: [String]
    let startDate: Date?
    let endDate: Date?

    init(
        id: String,
        name: String,
        itemIDs: [String] = [],
        startDate: Date? = nil,
        endDate: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.itemIDs = itemIDs
        self.startDate = startDate
        self.endDate = endDate
    }
}

struct TimelineDocument {
    let trips: [TimelineTrip]

    var isEmpty: Bool { trips.allSatisfy { $0.days.isEmpty } }
}

struct TimelineTrip: Identifiable {
    let id: String
    let name: String
    let days: [TimelineDay]
    let startDate: Date?

    var itemCount: Int {
        days.reduce(into: 0) { result, day in
            result += day.events.reduce(into: 0) { count, event in
                if case let .place(place) = event { count += place.photoCount }
            }
        }
    }
}

struct TimelineDay: Identifiable {
    let id: String
    let date: Date?
    let events: [TimelineEvent]
}

enum TimelineEvent: Identifiable {
    case place(TimelinePlace)
    case travel(TimelineTravel)

    var id: String {
        switch self {
        case let .place(place): return place.id
        case let .travel(travel): return travel.id
        }
    }
}

struct TimelinePlace: Identifiable {
    let id: String
    let date: Date?
    let name: String?
    let cityName: String?
    let items: [TimelineItemSnapshot]

    var itemIDs: [String] { items.map(\.id) }
    var photoCount: Int { items.count }
    var memoryCount: Int { items.reduce(0) { $0 + $1.memories.count } }
}

struct TimelineTravel: Identifiable {
    let id: String
    let date: Date?
    let fromName: String?
    let toName: String?
    let distanceMeters: Double
    let fromStopID: String?
    let toStopID: String?
}

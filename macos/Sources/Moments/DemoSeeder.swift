import Foundation
import SwiftData

struct DemoPayload: Decodable {
    let kind: String
    let assets: [DemoAsset]
}

struct DemoAsset: Decodable {
    let id: String
    let date: String?
    let trip: String
    let place: String
    let scene: String
    let titleLabels: [String: String]
    let tags: [String]
    let width: Int
    let height: Int
    let geo: DemoGeo?
}

struct DemoGeo: Decodable {
    let latitude: Double
    let longitude: Double
}

public enum DemoSeeder {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    public static func seedIfNeeded(context: ModelContext, data: Data) throws {
        let existing = try context.fetch(FetchDescriptor<MediaItem>())
        guard existing.isEmpty else { return }
        let payload = try JSONDecoder().decode(DemoPayload.self, from: data)
        guard payload.kind == "synthetic-demo-only" else { return }
        var places: [String: Place] = [:]
        var trips: [String: Trip] = [:]
        var tags: [String: Tag] = [:]
        var items: [String: MediaItem] = [:]

        for asset in payload.assets {
            let areaName = asset.place
            let place = places[areaName] ?? Place(id: "demo-\(safeID(areaName))", name: areaName, kind: .spot, latitude: asset.geo?.latitude, longitude: asset.geo?.longitude)
            if places[areaName] == nil {
                places[areaName] = place
                context.insert(place)
            }
            let trip = trips[asset.trip] ?? Trip(id: asset.trip, name: asset.trip)
            if trips[asset.trip] == nil {
                trips[asset.trip] = trip
                context.insert(trip)
            }
            let title = asset.titleLabels["en"] ?? asset.scene
            let item = MediaItem(
                id: asset.id,
                captureDate: asset.date.flatMap { dateFormatter.date(from: $0) },
                latitude: asset.geo?.latitude,
                longitude: asset.geo?.longitude,
                kind: .photo,
                width: asset.width,
                height: asset.height,
                source: .demo,
                title: title,
                tripKey: asset.trip,
                trip: trip
            )
            context.insert(item)
            items[asset.id] = item
            item.place = place
            trip.items.append(item)
            for tagName in asset.tags {
                let normalizedName = Tag.normalize(tagName)
                let tag = tags[normalizedName] ?? Tag(displayName: tagName)
                if tags[normalizedName] == nil {
                    tags[normalizedName] = tag
                    context.insert(tag)
                }
                item.addTag(tag, context: context)
            }
        }

        if let first = payload.assets.first,
           let item = items[first.id] {
            let memory = Memory(text: "Synthetic demonstration data", author: .me, mediaItem: item)
            context.insert(memory)
        }
        try context.save()
    }

    #if DEBUG
    /// Inserts a deterministic, local-only stress fixture for scrolling checks.
    /// The generator never reads files or Photos and keeps all coordinates near 0,0.
    @discardableResult
    public static func generateSyntheticLibrary(count: Int = 5_000, context: ModelContext) throws -> Int {
        guard count > 0 else { return 0 }
        let existingItems = try context.fetch(FetchDescriptor<MediaItem>())
        let existingIDs = Set(existingItems.map(\.id))
        let placeID = "stress-demo-place"
        let tripID = "stress-demo-trip"
        let place = try context.fetch(FetchDescriptor<Place>()).first(where: { $0.id == placeID })
            ?? Place(id: placeID, name: "Synthetic stress place", kind: .spot, latitude: 0.01, longitude: 0.01)
        if place.modelContext == nil { context.insert(place) }
        let trip = try context.fetch(FetchDescriptor<Trip>()).first(where: { $0.id == tripID })
            ?? Trip(id: tripID, name: "Synthetic stress trip")
        if trip.modelContext == nil { context.insert(trip) }

        let baseDate = Date(timeIntervalSince1970: 946_684_800)
        var newItems: [MediaItem] = []
        for index in 0..<count {
            let id = String(format: "stress-%05d", index)
            guard !existingIDs.contains(id) else { continue }
            let isPossibleScreenshot = index % 43 == 0
            let item = MediaItem(
                id: id,
                captureDate: baseDate.addingTimeInterval(Double(index) * 120),
                latitude: Double(index % 20) / 1_000,
                longitude: Double((index * 7) % 20) / 1_000,
                kind: index % 19 == 0 ? .video : .photo,
                width: isPossibleScreenshot ? 1_170 : 1_600 + (index % 5) * 100,
                height: isPossibleScreenshot ? 2_532 : 1_000 + (index % 4) * 100,
                isScreenshot: index % 97 == 0,
                source: .demo,
                title: "Synthetic stress item \(index + 1)",
                tripKey: tripID,
                place: place
            )
            context.insert(item)
            newItems.append(item)
        }
        // One relationship update instead of 5,000 (each append re-observes the array).
        trip.items.append(contentsOf: newItems)
        if !newItems.isEmpty { try context.save() }
        return newItems.count
    }
    #endif

    public static func seedIfNeeded(context: ModelContext, bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "sample-data", withExtension: "json") else { return }
        try seedIfNeeded(context: context, data: Data(contentsOf: url))
    }

    private static func safeID(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}

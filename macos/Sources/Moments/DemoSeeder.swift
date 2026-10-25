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
                tripKey: asset.trip
            )
            context.insert(item)
            items[asset.id] = item
            trip.items.append(item)
            for tagName in asset.tags {
                let tag = tags[tagName] ?? Tag(name: tagName)
                if tags[tagName] == nil {
                    tags[tagName] = tag
                    context.insert(tag)
                }
                item.tags.append(tag)
            }
        }

        if let first = payload.assets.first,
           let item = items[first.id] {
            let memory = Memory(text: "Synthetic demonstration data", author: .me, mediaItem: item)
            context.insert(memory)
        }
        try context.save()
    }

    public static func seedIfNeeded(context: ModelContext, bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "sample-data", withExtension: "json") else { return }
        try seedIfNeeded(context: context, data: Data(contentsOf: url))
    }

    private static func safeID(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}

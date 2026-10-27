import AppKit
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
                tripID: asset.trip,
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
                tripID: tripID,
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

    #if DEBUG
    /// UI tests: four shots a second apart that look alike (same difference
    /// hash), right after the newest demo photo, so the Library shows a stack.
    public static func addSyntheticBurst(context: ModelContext) throws {
        let items = try context.fetch(FetchDescriptor<MediaItem>())
        guard !items.contains(where: { $0.id.hasPrefix("demo-burst-") }),
              let newest = items.filter({ $0.captureDate != nil }).max(by: { $0.captureDate! < $1.captureDate! }),
              let start = newest.captureDate?.addingTimeInterval(60) else { return }
        var burst: [MediaItem] = []
        for index in 0..<4 {
            let item = MediaItem(
                id: "demo-burst-\(index + 1)",
                captureDate: start.addingTimeInterval(Double(index)),
                latitude: newest.latitude,
                longitude: newest.longitude,
                kind: .photo,
                width: 1_600,
                height: 1_200,
                source: .demo,
                title: "Synthetic burst \(index + 1)",
                tripID: newest.tripID,
                trip: newest.trip,
                perceptualHash: String(format: "%016llx", UInt64(0x0F0F_0F0F_0F0F_0F00) | UInt64(index))
            )
            item.place = newest.place
            context.insert(item)
            burst.append(item)
        }
        newest.trip?.items.append(contentsOf: burst)
        try context.save()
    }
    #endif

    public static func seedIfNeeded(context: ModelContext, bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "sample-data", withExtension: "json") else { return }
        try seedIfNeeded(context: context, data: Data(contentsOf: url))
    }

    #if DEBUG
    /// UI tests: flags the demo photos that have no date or place, the way an
    /// import would, so the Library's "to confirm" banner has something to show.
    public static func flagUndatedDemoItemsForReview(context: ModelContext) throws {
        for item in try context.fetch(FetchDescriptor<MediaItem>()) where item.source == .demo {
            var reasons: [ImportReviewReason] = []
            if item.captureDate == nil { reasons.append(.needsDate) }
            if item.latitude == nil { reasons.append(.missingLocation) }
            guard !reasons.isEmpty else { continue }
            item.importReviewReasonsRaw = reasons.map(\.rawValue).joined(separator: ",")
        }
        try context.save()
    }

    /// UI tests: two named people with synthetic faces (flat coloured
    /// squares, no real faces) on the first demo photos, so People and the
    /// viewer have someone to correct.
    public static func seedPeopleForUITests(context: ModelContext) throws {
        guard try context.fetch(FetchDescriptor<Person>()).isEmpty else { return }
        let items = try context.fetch(FetchDescriptor<MediaItem>(sortBy: [SortDescriptor(\.id)])).filter { $0.source == .demo }
        guard items.count >= 3 else { return }
        let alex = Person(id: "demo-person-alex", name: "Alex")
        let sam = Person(id: "demo-person-sam", name: "Sam")
        context.insert(alex)
        context.insert(sam)
        let faces: [(item: MediaItem, person: Person, hue: Double)] = [
            (items[0], alex, 0.05), (items[1], alex, 0.08), (items[2], sam, 0.58)
        ]
        for (index, face) in faces.enumerated() {
            context.insert(FaceObservation(
                id: "demo-face-\(index + 1)",
                mediaID: face.item.id,
                rect: (0.35, 0.3, 0.3, 0.3),
                embedding: Data(),
                cropData: syntheticFaceCrop(hue: face.hue),
                quality: 1,
                personID: face.person.id,
                confirmed: true
            ))
            context.insert(FaceScanRecord(id: face.item.id))
        }
        try context.save()
    }

    private static func syntheticFaceCrop(hue: Double) -> Data {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor(calibratedHue: hue, saturation: 0.35, brightness: 0.85, alpha: 1).setFill()
            NSBezierPath(rect: rect).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [:]) else { return Data() }
        return jpeg
    }
    #endif

    #if DEBUG
    /// UI tests: files three demo photos under a synthetic imported folder,
    /// so Settings › Imports has a source to remove.
    public static func addSyntheticImportSource(context: ModelContext) throws {
        guard try context.fetchCount(FetchDescriptor<ImportSource>()) == 0 else { return }
        let source = ImportSource(kind: .folder, name: "Synthetic folder", locationKey: "/synthetic/Synthetic folder")
        context.insert(source)
        let items = try context.fetch(FetchDescriptor<MediaItem>()).filter { $0.source == .demo }.sorted { $0.id < $1.id }
        for item in items.prefix(3) { item.addImportSource(source.id) }
        try context.save()
    }
    #endif

    private static func safeID(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}

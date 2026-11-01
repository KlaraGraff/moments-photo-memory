#if DEBUG
import AppKit
import CoreGraphics
import Foundation
import MomentsCore
import SwiftData

/// UI-test-only, `-MomentsUITestStressLibrary <count>`: a first import of a
/// large library, shaped like a real one: six years of everyday photos around
/// home, trips to many places, bursts, videos and screenshots. It goes through
/// the real Apple Photos import (`PhotosImporter`) with a synthetic source and
/// geocoder, then adds what face scanning and use leave behind (faces, notes,
/// chapters) and starts the same background work a real import starts.
/// Nothing here touches PhotoKit or the network; all data is generated.
@MainActor
enum StressLibrary {
    /// Asset identifiers start with this; PhotoKit is never asked about them.
    nonisolated static let identifierPrefix = "moments-stress/"

    enum Stage { case notRequested, importing, finished }
    private(set) static var stage = Stage.notRequested
    private(set) static var summary = ""

    static var requestedCount: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-MomentsUITestStressLibrary"), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }

    nonisolated static func isSynthetic(_ localIdentifier: String) -> Bool {
        localIdentifier.hasPrefix(identifierPrefix)
    }

    /// Call once, before `ImportController.configure` starts the place-name backfill.
    static func prepareIfRequested() {
        guard requestedCount != nil else { return }
        // Places the import could not name are named later; here by the
        // synthetic geocoder instead of Apple's.
        PlaceNameBackfillScheduler.shared.makeBackfill = {
            PlaceNameBackfill(geocoder: SyntheticGeocoder(), geocodeCache: ImportGeocodeCache(fileURL: nil))
        }
    }

    static func startIfRequested(container: ModelContainer) {
        guard let count = requestedCount, count > 0, stage == .notRequested else { return }
        stage = .importing
        PageProbe.importStarted()
        PlaceNameBackfillScheduler.shared.beginImport()
        Task { @MainActor in
            let started = Date()
            let shape = await Task.detached { SyntheticLibraryShape(count: count).make() }.value
            let importer = PhotosImporter(
                source: SyntheticPhotosSource(assets: shape.assets, lookalikes: shape.lookalikes),
                geocoder: SyntheticGeocoder(),
                geocodeCache: ImportGeocodeCache(fileURL: nil)
            )
            var text: String
            do {
                let result = try await importer.importPhotos(selection: .all, container: container)
                text = String(format: "imported %d (trips %d, places %d) in %.1f s", result.importedCount, result.tripCount, result.placeCount, Date().timeIntervalSince(started))
            } catch {
                text = "import failed: \(error)"
            }
            PlaceNameBackfillScheduler.shared.endImport()
            let extrasStarted = Date()
            let extras = await Task.detached(priority: .utility) {
                (try? Self.addUseTraces(container: container)) ?? "traces failed"
            }.value
            text += String(format: "; %@ in %.1f s", extras, Date().timeIntervalSince(extrasStarted))
            summary = text
            stage = .finished
            PageProbe.importFinished(summary: text)
            // What PhotosImportController does after an import.
            NotificationCenter.default.post(name: .momentsPeopleScanRequested, object: nil)
        }
    }

    /// Faces as a scan leaves them (most waiting to be grouped, some named),
    /// day and photo notes, and a few chapters.
    nonisolated private static func addUseTraces(container: ModelContainer) throws -> String {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var random = SplitMix(seed: 7)
        let items = try context.fetch(FetchDescriptor<MediaItem>(sortBy: [SortDescriptor(\.id)]))
            .filter { $0.photosLocalIdentifier.map(isSynthetic) == true }
        let photos = items.filter { $0.kind != .video && !$0.isScreenshot }

        // About a third of photos have people in them; a few people are in most.
        let peopleCount = 30
        let centroids = (0..<peopleCount).map { _ in unit((0..<128).map { _ in Float(random.normal()) }) }
        let named = (0..<8).map { Person(id: "stress-person-\($0)", name: "Person \($0 + 1)") }
        for person in named { context.insert(person) }
        let crops = (0..<peopleCount).map { faceCrop(hue: Double($0) / Double(peopleCount)) }
        var faceCount = 0
        for item in photos where random.unit() < 0.35 {
            for slot in 0..<(1 + random.below(3)) {
                // Lower-numbered people turn up far more often.
                let person = min(peopleCount - 1, Int(Double(peopleCount) * pow(random.unit(), 2.2)))
                let noise = (0..<128).map { _ in Float(random.normal()) * 0.035 }
                let vector = unit(zip(centroids[person], noise).map(+))
                let confirmed = person < named.count && random.unit() < 0.25
                let face = FaceObservation(
                    mediaID: item.id,
                    rect: (0.1 + 0.28 * Double(slot), 0.3, 0.2, 0.26),
                    embedding: vector.withUnsafeBufferPointer { Data(buffer: $0) },
                    cropData: crops[person],
                    quality: 0.5 + random.unit() * 0.5,
                    personID: confirmed ? named[person].id : nil,
                    confirmed: confirmed,
                    assignmentSource: confirmed ? "user" : "auto"
                )
                if !confirmed { face.clusterID = "pending-\(face.id)" }
                context.insert(face)
                faceCount += 1
            }
        }

        // Notes on some days and some photos.
        var dayNotes = 0
        for day in Set(items.compactMap(\.localDayKey)).sorted() where random.unit() < 0.06 {
            context.insert(CollectionMemory(scope: .day, scopeKey: day, text: "Synthetic note for \(day)"))
            dayNotes += 1
        }
        var photoNotes = 0
        for item in photos where random.unit() < 0.01 {
            context.insert(Memory(text: "Synthetic photo note \(photoNotes + 1)", mediaItem: item))
            photoNotes += 1
        }

        // A few chapters that are not trips: a week-long event, a season.
        let dated = items.compactMap { item in item.captureDate.map { (item, $0) } }.sorted { $0.1 < $1.1 }
        var chapters = 0
        if let first = dated.first?.1, let last = dated.last?.1 {
            let span = last.timeIntervalSince(first)
            for index in 0..<8 {
                let start = first.addingTimeInterval(span * Double(index) / 8 + 86_400 * 20)
                let length: TimeInterval = index % 2 == 0 ? 86_400 * 6 : 86_400 * 75
                let end = start.addingTimeInterval(length)
                let group = UserGroup(name: "Synthetic chapter \(index + 1)", kind: .chapter)
                group.chapterInfo = ChapterInfo(type: index % 2 == 0 ? ChapterType.event.raw : ChapterType.period.raw, startDate: start, endDate: end)
                context.insert(group)
                for (item, date) in dated where date >= start && date <= end {
                    context.insert(UserGroupItem(groupID: group.id, mediaID: item.id))
                }
                chapters += 1
            }
        }
        try context.save()
        return "faces \(faceCount), day notes \(dayNotes), photo notes \(photoNotes), chapters \(chapters)"
    }

    nonisolated private static func unit(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 })
        return norm > 0 ? vector.map { $0 / norm } : vector
    }

    nonisolated private static func faceCrop(hue: Double) -> Data {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        let color = NSColor(calibratedHue: hue, saturation: 0.35, brightness: 0.85, alpha: 1).cgColor
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:]) ?? Data()
    }
}

/// Where and when the synthetic photos were taken. Deterministic: the same
/// count gives the same library on every run.
struct SyntheticLibraryShape {
    let count: Int

    /// Made-up coordinates: a home and places around the world to travel to.
    private static let home = GeoPoint(latitude: 21.31, longitude: 31.73)
    private static let destinations: [GeoPoint] = (0..<36).map { index in
        GeoPoint(latitude: -45 + Double((index * 37) % 90) + 0.37, longitude: -170 + Double((index * 83) % 340) + 0.61)
    }
    private static let days = 6 * 365
    private static let end = Date(timeIntervalSince1970: 1_767_225_600)
    private static let start = end.addingTimeInterval(-Double(days) * 86_400)

    private enum Outing {
        case trip(length: Int, destination: GeoPoint, photos: Int)
        case everyday(photos: Double)
    }

    /// The assets, and for each burst shot the first shot it looks like.
    func make() -> (assets: [PhotosAssetDescriptor], lookalikes: [String: String]) {
        var builder = Builder(count: count)
        let days = Self.days
        // Trips: about seven a year, two to twelve days, 45% of all photos.
        let tripCount = 42
        let tripBudget = Double(count) * 0.45 / Double(tripCount)
        var tripDays = Set<Int>()
        var outings: [(day: Int, outing: Outing)] = []
        for trip in 0..<tripCount {
            let day = Int((Double(trip) + 0.2 + builder.random.unit() * 0.5) * Double(days) / Double(tripCount))
            let length = 2 + builder.random.below(11)
            let photos = Int(tripBudget * (0.4 + builder.random.unit() * 1.2))
            outings.append((day, .trip(length: length, destination: Self.destinations[(trip * 5) % Self.destinations.count], photos: photos)))
            for offset in 0..<length { tripDays.insert(day + offset) }
        }
        // Everyday photos on the days in between.
        let tripPhotos = outings.reduce(0) { total, entry in
            if case let .trip(_, _, photos) = entry.outing { return total + photos }
            return total
        }
        let activeDays = (0..<days).filter { !tripDays.contains($0) && builder.random.unit() < 0.4 }
        let perDay = Double(max(0, count - tripPhotos)) / Double(max(1, activeDays.count))
        outings += activeDays.map { (day: $0, outing: Outing.everyday(photos: perDay)) }
        let homeSpots = (0..<25).map { _ in builder.nudge(Self.home, by: 0.15) }

        for (day, outing) in outings.sorted(by: { $0.day < $1.day }) {
            switch outing {
            case let .trip(length, destination, photos):
                let perTripDay = max(1, photos / length)
                for offset in 0..<length {
                    let dayStart = Self.start.addingTimeInterval(Double(day + offset) * 86_400)
                    let spots = (0..<(2 + builder.random.below(4))).map { _ in builder.nudge(destination, by: 0.3) }
                    for shot in 0..<perTripDay {
                        let time = 8 * 3_600 + Double(shot) * (13 * 3_600 / Double(perTripDay)) + builder.random.unit() * 300
                        let spot = builder.nudge(spots[shot * spots.count / perTripDay], by: 0.002)
                        builder.add(dayStart.addingTimeInterval(time), at: spot)
                    }
                }
            case let .everyday(average):
                // Most days a handful, some days many.
                let shots = max(1, Int(average * 3 * pow(builder.random.unit(), 2)))
                let dayStart = Self.start.addingTimeInterval(Double(day) * 86_400)
                let spot = homeSpots[builder.random.below(homeSpots.count)]
                for shot in 0..<shots {
                    let time = 9 * 3_600 + Double(shot) * (12 * 3_600 / Double(shots)) + builder.random.unit() * 600
                    let place = builder.random.unit() < 0.15 ? nil : builder.nudge(spot, by: 0.003)
                    builder.add(dayStart.addingTimeInterval(time), at: place)
                }
            }
        }
        // Short of the count (rounding): more everyday photos in the last year.
        while builder.assets.count < count {
            let day = days - 1 - builder.random.below(365)
            let place = builder.nudge(Self.home, by: 0.1)
            builder.add(Self.start.addingTimeInterval(Double(day) * 86_400 + 36_000 + builder.random.unit() * 36_000), at: place)
        }
        return (builder.assets, builder.lookalikes)
    }

    private struct Builder {
        let count: Int
        var random = SplitMix(seed: 2026)
        var assets: [PhotosAssetDescriptor] = []
        var lookalikes: [String: String] = [:]

        init(count: Int) {
            self.count = count
            assets.reserveCapacity(count)
        }

        mutating func nudge(_ point: GeoPoint, by degrees: Double) -> GeoPoint {
            GeoPoint(latitude: point.latitude + (random.unit() - 0.5) * 2 * degrees,
                     longitude: point.longitude + (random.unit() - 0.5) * 2 * degrees)
        }

        private func identifier() -> String {
            StressLibrary.identifierPrefix + String(format: "%06d", assets.count)
        }

        mutating func add(_ date: Date, at location: GeoPoint?) {
            guard assets.count < count else { return }
            let id = identifier()
            let roll = random.unit()
            let isVideo = roll < 0.05
            let isScreenshot = !isVideo && roll < 0.08
            var subtypes: PhotosMediaSubtypes = []
            if isScreenshot { subtypes.insert(.screenshot) }
            if !isVideo, !isScreenshot, random.unit() < 0.2 { subtypes.insert(.live) }
            let portrait = random.unit() < 0.4
            assets.append(PhotosAssetDescriptor(
                localIdentifier: id,
                creationDate: date,
                location: isScreenshot ? nil : location,
                mediaType: isVideo ? .video : .image,
                mediaSubtypes: subtypes,
                duration: isVideo ? 3 + random.unit() * 57 : nil,
                pixelWidth: isScreenshot ? 1_170 : (portrait ? 3_024 : 4_032),
                pixelHeight: isScreenshot ? 2_532 : (portrait ? 4_032 : 3_024),
                isFavorite: random.unit() < 0.02
            ))
            // Now and then a burst: a few more shots a fraction of a second apart.
            guard !isVideo, !isScreenshot, random.unit() < 0.03 else { return }
            for shot in 1...(2 + random.below(5)) {
                guard assets.count < count else { break }
                let shotID = identifier()
                assets.append(PhotosAssetDescriptor(
                    localIdentifier: shotID,
                    creationDate: date.addingTimeInterval(0.4 * Double(shot)),
                    location: location,
                    mediaType: .image,
                    pixelWidth: portrait ? 3_024 : 4_032,
                    pixelHeight: portrait ? 4_032 : 3_024
                ))
                lookalikes[shotID] = id
            }
        }
    }
}

/// Apple Photos stand-in: the generated assets and a tiny picture for each
/// (shots of one burst look alike, so they stack).
final class SyntheticPhotosSource: PhotosAssetSource, @unchecked Sendable {
    private let assets: [PhotosAssetDescriptor]
    /// Burst shot id → the shot it looks like.
    private let lookalikes: [String: String]

    init(assets: [PhotosAssetDescriptor], lookalikes: [String: String]) {
        self.assets = assets
        self.lookalikes = lookalikes
    }

    var authorizationStatus: PhotosAuthorizationStatus { .authorized }
    func requestAuthorization() async -> PhotosAuthorizationStatus { .authorized }
    func fetchAssets(selection: PhotosImportSelection) async throws -> [PhotosAssetDescriptor] { assets }
    func observeChanges(_ handler: @escaping @Sendable (PhotosChangeEvent) -> Void) -> any PhotosChangeObservation {
        SyntheticObservation()
    }

    func thumbnailData(forLocalIdentifier localIdentifier: String, targetSize: CGSize, networkAccessAllowed: Bool) async throws -> Data? {
        nil
    }

    func thumbnailImage(forLocalIdentifier localIdentifier: String, targetSize: CGSize, networkAccessAllowed: Bool) async -> CGImage? {
        let seed = Int((lookalikes[localIdentifier] ?? localIdentifier).suffix(6)) ?? 0
        var random = SplitMix(seed: UInt64(seed) &+ 99)
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        for index in pixels.indices { pixels[index] = UInt8(random.below(256)) }
        return pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
    }

    private final class SyntheticObservation: PhotosChangeObservation {
        func invalidate() {}
    }
}

/// Names places from their coordinates: cities on a half-degree grid, areas
/// and spots on finer ones. Answers at once, like a warm cache.
struct SyntheticGeocoder: ImportGeocoder {
    func reverseGeocode(coordinate: GeoPoint) async throws -> ImportGeocodeResult {
        func cell(_ value: Double, _ size: Double) -> Int { Int((value / size).rounded(.down)) }
        let city = "City \(cell(coordinate.latitude, 0.5))/\(cell(coordinate.longitude, 0.5))"
        let offset = Int((coordinate.longitude / 15).rounded()) * 3_600
        return ImportGeocodeResult(
            city: city,
            area: "Area \(cell(coordinate.latitude, 0.05))/\(cell(coordinate.longitude, 0.05))",
            spot: "Spot \(cell(coordinate.latitude, 0.005))/\(cell(coordinate.longitude, 0.005))",
            timeZoneIdentifier: TimeZone(secondsFromGMT: offset)?.identifier,
            country: "Country \(cell(coordinate.latitude, 10))/\(cell(coordinate.longitude, 10))"
        )
    }
}

/// A small deterministic random generator (SplitMix64).
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// In [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }

    /// Standard normal (Box–Muller).
    mutating func normal() -> Double {
        let u = max(unit(), 1e-12)
        return sqrt(-2 * log(u)) * cos(2 * .pi * unit())
    }
}
#endif

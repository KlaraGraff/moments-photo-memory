import Foundation

/// One stable group of related media.
public struct MediaCollection: Identifiable, Equatable, Sendable {
    public let id: String
    public let items: [MediaDescriptor]
    public let cover: MediaDescriptor

    public init(id: String, items: [MediaDescriptor], cover: MediaDescriptor) {
        self.id = id
        self.items = items
        self.cover = cover
    }

    public var itemIDs: [String] { items.map(\.id) }
    public var coverID: String { cover.id }
    public var count: Int { items.count }
    public var isSingleton: Bool { items.count == 1 }
}

/// Groups temporally close media, optionally requiring compatible injected
/// feature prints. No Vision request is made here.
public struct CollectionGrouper: Sendable {
    public let burstInterval: TimeInterval
    public let featurePrintDistanceThreshold: Double

    public init(
        burstInterval: TimeInterval = 90,
        featurePrintDistanceThreshold: Double = 0.20
    ) {
        self.burstInterval = max(0, burstInterval)
        self.featurePrintDistanceThreshold = max(0, featurePrintDistanceThreshold)
    }

    /// Groups all supplied media. Screenshot filtering is available through
    /// ``groupVisible(_:,using:)`` so callers can retain the detector's reason.
    public func group(_ media: [MediaDescriptor]) -> [MediaCollection] {
        let ordered = media.sorted(by: canonicalOrder)
        guard !ordered.isEmpty else { return [] }

        var groups: [[MediaDescriptor]] = []
        var current: [MediaDescriptor] = []

        for item in ordered {
            guard let date = item.captureDate else {
                if !current.isEmpty {
                    groups.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                groups.append([item])
                continue
            }

            guard let previous = current.last,
                  let previousDate = previous.captureDate,
                  date.timeIntervalSince(previousDate) <= burstInterval,
                  current.allSatisfy({ featurePrintsCompatible($0.featurePrint, item.featurePrint) })
            else {
                if !current.isEmpty { groups.append(current) }
                current = [item]
                continue
            }

            current.append(item)
        }
        if !current.isEmpty { groups.append(current) }

        return groups.map(makeCollection)
    }

    /// Groups after removing media classified as screenshots. The detector is
    /// also available to the caller when it needs to display each reason.
    public func groupVisible(
        _ media: [MediaDescriptor],
        using detector: ScreenshotDetector = ScreenshotDetector()
    ) -> [MediaCollection] {
        group(detector.visibleMedia(from: media))
    }

    private func featurePrintsCompatible(_ lhs: [Float]?, _ rhs: [Float]?) -> Bool {
        guard let lhs, let rhs else { return true }
        guard lhs.count == rhs.count, !lhs.isEmpty else { return false }

        var dot: Double = 0
        var lhsMagnitude: Double = 0
        var rhsMagnitude: Double = 0
        for (left, right) in zip(lhs, rhs) {
            let leftValue = Double(left)
            let rightValue = Double(right)
            dot += leftValue * rightValue
            lhsMagnitude += leftValue * leftValue
            rhsMagnitude += rightValue * rightValue
        }

        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return false }
        let cosineSimilarity = dot / (sqrt(lhsMagnitude) * sqrt(rhsMagnitude))
        let distance = 1 - cosineSimilarity
        return distance <= featurePrintDistanceThreshold
    }

    private func canonicalOrder(_ lhs: MediaDescriptor, _ rhs: MediaDescriptor) -> Bool {
        switch (lhs.captureDate, rhs.captureDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        default:
            return lhs.id < rhs.id
        }
    }

    private func makeCollection(from items: [MediaDescriptor]) -> MediaCollection {
        let orderedItems = items.sorted(by: canonicalOrder)
        let cover = orderedItems.max {
            if $0.pixelCount != $1.pixelCount { return $0.pixelCount < $1.pixelCount }
            switch ($0.captureDate, $1.captureDate) {
            case let (left?, right?) where left != right:
                return left > right
            case (nil, .some):
                return true
            case (.some, nil):
                return false
            default:
                return $0.id > $1.id
            }
        } ?? items[0]

        let id = stableCollectionID(for: orderedItems.map(\.id))
        return MediaCollection(id: id, items: orderedItems, cover: cover)
    }

    private func stableCollectionID(for itemIDs: [String]) -> String {
        // FNV-1a is small, deterministic, and available on every platform
        // supported by Swift Foundation. The sorted IDs make this independent
        // of input ordering and of the order in which a burst was discovered.
        var hash: UInt64 = 14_695_981_039_346_656_037
        let bytes = Array(("moments-collection-v1\u{0}" + itemIDs.joined(separator: "\u{0}")).utf8)
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let hexadecimal = String(hash, radix: 16, uppercase: false)
        return "collection-" + String(repeating: "0", count: max(0, 16 - hexadecimal.count)) + hexadecimal
    }
}

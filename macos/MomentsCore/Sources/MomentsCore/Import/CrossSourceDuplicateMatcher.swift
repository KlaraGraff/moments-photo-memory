import Foundation

/// What the cross-source duplicate check needs to know about one photo or
/// video, whichever source (a folder or Apple Photos) it came from.
public struct DuplicateCandidate: Equatable, Sendable {
    public let id: String
    /// The capture moment in absolute time (UTC), after time-zone resolution.
    public let captureDate: Date
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let location: GeoPoint?
    /// The 64-bit difference hash of a small thumbnail, as 16 hex digits.
    public let perceptualHash: String?

    public init(
        id: String,
        captureDate: Date,
        pixelWidth: Int,
        pixelHeight: Int,
        location: GeoPoint?,
        perceptualHash: String?
    ) {
        self.id = id
        self.captureDate = captureDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.location = location
        self.perceptualHash = perceptualHash
    }
}

/// Decides whether a photo imported from one source is probably the same
/// photo as one already imported from another source (#40).
///
/// Two items are a candidate pair when all of these hold:
/// 1. Their capture times are at most `timeTolerance` apart.
/// 2. They have the same pixel dimensions, in either orientation.
/// 3. Both have a location no more than `distanceTolerance` apart, or, when
///    either has no location, their perceptual hashes differ in at most
///    `maximumHashDistance` bits.
///
/// A match is only a flag for review; nothing is ever merged automatically.
public struct CrossSourceDuplicateMatcher: Sendable {
    public var timeTolerance: TimeInterval
    public var distanceTolerance: Double
    public var maximumHashDistance: Int

    public init(
        timeTolerance: TimeInterval = 1,
        distanceTolerance: Double = 50,
        maximumHashDistance: Int = 6
    ) {
        self.timeTolerance = max(0, timeTolerance)
        self.distanceTolerance = max(0, distanceTolerance)
        self.maximumHashDistance = max(0, maximumHashDistance)
    }

    public func isMatch(_ lhs: DuplicateCandidate, _ rhs: DuplicateCandidate) -> Bool {
        guard abs(lhs.captureDate.timeIntervalSince(rhs.captureDate)) <= timeTolerance else { return false }
        guard Self.sameDimensions(lhs, rhs) else { return false }
        if let left = lhs.location, let right = rhs.location {
            return left.distance(to: right) <= distanceTolerance
        }
        guard let leftHash = lhs.perceptualHash,
              let rightHash = rhs.perceptualHash,
              let distance = Self.hammingDistance(leftHash, rightHash) else { return false }
        return distance <= maximumHashDistance
    }

    /// The ids of `incoming` items that match at least one of `existing`.
    ///
    /// The existing items are indexed by capture second, so a first import of
    /// tens of thousands of photos against a library of the same size stays
    /// close to linear instead of comparing every pair.
    public func matchingIDs(
        _ incoming: [DuplicateCandidate],
        against existing: [DuplicateCandidate]
    ) -> Set<String> {
        guard !incoming.isEmpty, !existing.isEmpty else { return [] }
        let bucketWidth = max(1, timeTolerance)
        var buckets: [Int: [DuplicateCandidate]] = [:]
        for candidate in existing {
            buckets[Self.bucket(candidate.captureDate, width: bucketWidth), default: []].append(candidate)
        }
        var matches = Set<String>()
        for candidate in incoming {
            let bucket = Self.bucket(candidate.captureDate, width: bucketWidth)
            let found = (bucket - 1...bucket + 1).contains { neighbour in
                buckets[neighbour]?.contains { isMatch(candidate, $0) } == true
            }
            if found { matches.insert(candidate.id) }
        }
        return matches
    }

    /// The number of differing bits between two 16-digit hex hashes, or nil
    /// when either is not such a hash.
    public static func hammingDistance(_ lhs: String, _ rhs: String) -> Int? {
        guard lhs.count == 16, rhs.count == 16,
              let left = UInt64(lhs, radix: 16),
              let right = UInt64(rhs, radix: 16) else { return nil }
        return (left ^ right).nonzeroBitCount
    }

    private static func sameDimensions(_ lhs: DuplicateCandidate, _ rhs: DuplicateCandidate) -> Bool {
        guard lhs.pixelWidth > 0, lhs.pixelHeight > 0 else { return false }
        return (lhs.pixelWidth == rhs.pixelWidth && lhs.pixelHeight == rhs.pixelHeight)
            || (lhs.pixelWidth == rhs.pixelHeight && lhs.pixelHeight == rhs.pixelWidth)
    }

    private static func bucket(_ date: Date, width: TimeInterval) -> Int {
        Int((date.timeIntervalSinceReferenceDate / width).rounded(.down))
    }
}

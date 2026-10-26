import Foundation

/// What the stack detector knows about one photo: when it was taken and how
/// it looks. Videos and screenshots are never passed in.
public struct StackPhoto: Identifiable, Equatable, Sendable {
    public let id: String
    public let captureDate: Date?
    /// The 64-bit difference hash written at import.
    public let perceptualHash: UInt64?
    /// Vision's image feature print, once the photo has been analysed.
    public let featurePrint: [Float]?
    public let quality: StackQuality?

    public init(
        id: String,
        captureDate: Date?,
        perceptualHash: UInt64? = nil,
        featurePrint: [Float]? = nil,
        quality: StackQuality? = nil
    ) {
        self.id = id
        self.captureDate = captureDate
        self.perceptualHash = perceptualHash
        self.featurePrint = featurePrint
        self.quality = quality
    }

    /// Parses the hexadecimal hash stored on a media item.
    public static func hash(fromHex hex: String?) -> UInt64? {
        guard let hex, hex.count == 16 else { return nil }
        return UInt64(hex, radix: 16)
    }
}

/// How good one shot of a burst looks, measured on the device.
public struct StackQuality: Codable, Equatable, Sendable {
    /// Variance of the Laplacian of a small grey copy: higher is sharper.
    public var sharpness: Double
    public var faceCount: Int
    /// Mean Vision face capture quality, 0...1; 0 without faces.
    public var faceQuality: Double
    /// Share of faces with both eyes open, 0...1; 0 without faces.
    public var eyesOpen: Double

    public init(sharpness: Double, faceCount: Int = 0, faceQuality: Double = 0, eyesOpen: Double = 0) {
        self.sharpness = sharpness
        self.faceCount = faceCount
        self.faceQuality = faceQuality
        self.eyesOpen = eyesOpen
    }
}

/// What someone changed about a stack. Stored, so it survives a new detection
/// pass and can be shared with the other person.
public struct StackDecision: Codable, Equatable, Sendable {
    public var id: String
    /// The stack as the person last saw it; it stays together as it is.
    public var memberIDs: [String]
    /// The photo shown for the stack; `nil` lets the best shot be picked.
    public var coverID: String?
    /// The stack was taken apart: its photos show one by one.
    public var isUnstacked: Bool
    /// Photos taken out of the stack; they show on their own.
    public var removedIDs: [String]

    public init(id: String, memberIDs: [String], coverID: String? = nil, isUnstacked: Bool = false, removedIDs: [String] = []) {
        self.id = id
        self.memberIDs = memberIDs
        self.coverID = coverID
        self.isUnstacked = isUnstacked
        self.removedIDs = removedIDs
    }
}

/// Photos shot moments apart of the same thing, shown as one.
public struct PhotoStack: Identifiable, Equatable, Sendable {
    public let id: String
    /// Oldest first.
    public let memberIDs: [String]
    public let coverID: String
    /// The cover was chosen by a person rather than picked automatically.
    public let isCoverChosen: Bool

    public init(id: String, memberIDs: [String], coverID: String, isCoverChosen: Bool) {
        self.id = id
        self.memberIDs = memberIDs
        self.coverID = coverID
        self.isCoverChosen = isCoverChosen
    }

    public var count: Int { memberIDs.count }
}

/// One cell of a grid after stacks are folded: the photo shown and, for a
/// stack, how many of its photos are in the grid.
public struct StackedEntry: Equatable, Sendable {
    public let id: String
    public let stackID: String?
    public let count: Int

    public init(id: String, stackID: String?, count: Int) {
        self.id = id
        self.stackID = stackID
        self.count = count
    }

    public var isStack: Bool { stackID != nil && count > 1 }
}

public struct PhotoStackIndex: Equatable, Sendable {
    public let stacks: [String: PhotoStack]
    public let stackIDByMember: [String: String]

    public static let empty = PhotoStackIndex(stacks: [:], stackIDByMember: [:])

    public init(stacks: [String: PhotoStack], stackIDByMember: [String: String]) {
        self.stacks = stacks
        self.stackIDByMember = stackIDByMember
    }

    public init(_ list: [PhotoStack]) {
        var stacks: [String: PhotoStack] = [:]
        var byMember: [String: String] = [:]
        for stack in list {
            stacks[stack.id] = stack
            for member in stack.memberIDs { byMember[member] = stack.id }
        }
        self.init(stacks: stacks, stackIDByMember: byMember)
    }

    public var isEmpty: Bool { stacks.isEmpty }

    public func stack(containing itemID: String) -> PhotoStack? {
        stackIDByMember[itemID].flatMap { stacks[$0] }
    }

    /// Folds each stack in `orderedIDs` into one entry where its first photo
    /// in that order sits. The entry shows the cover when the cover is among
    /// `orderedIDs`, otherwise that first photo. A stack with one photo left
    /// in the order is an ordinary photo.
    public func collapse(_ orderedIDs: [String]) -> [StackedEntry] {
        guard !stacks.isEmpty else { return orderedIDs.map { StackedEntry(id: $0, stackID: nil, count: 1) } }
        let present = Set(orderedIDs)
        var counts: [String: Int] = [:]
        for id in orderedIDs {
            if let stackID = stackIDByMember[id] { counts[stackID, default: 0] += 1 }
        }
        var emitted = Set<String>()
        var result: [StackedEntry] = []
        result.reserveCapacity(orderedIDs.count)
        for id in orderedIDs {
            guard let stackID = stackIDByMember[id], let stack = stacks[stackID], let count = counts[stackID], count > 1 else {
                result.append(StackedEntry(id: id, stackID: nil, count: 1))
                continue
            }
            guard emitted.insert(stackID).inserted else { continue }
            let shown = present.contains(stack.coverID) ? stack.coverID : id
            result.append(StackedEntry(id: shown, stackID: stackID, count: count))
        }
        return result
    }

    /// Every photo the entries stand for, each stack expanded in place.
    public func expand(_ ids: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for id in ids {
            if let stack = stack(containing: id) {
                for member in stack.memberIDs where seen.insert(member).inserted { result.append(member) }
            } else if seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }
}

/// Finds bursts: photos taken a few seconds apart that look alike. Someone
/// tapping the shutter again and again gives one stack; two different
/// scenes shot quickly one after the other stay apart.
public struct PhotoStackDetector: Sendable {
    /// Longest pause between two neighbouring shots of one stack.
    public var maximumGap: TimeInterval
    /// Longest time from a stack's first shot to its last.
    public var maximumSpan: TimeInterval
    /// Largest cosine distance between neighbouring feature prints.
    public var featurePrintDistance: Double
    /// Largest number of differing bits between neighbouring difference hashes.
    public var hashDistance: Int

    public init(
        maximumGap: TimeInterval = 5,
        maximumSpan: TimeInterval = 60,
        featurePrintDistance: Double = 0.2,
        hashDistance: Int = 18
    ) {
        self.maximumGap = maximumGap
        self.maximumSpan = maximumSpan
        self.featurePrintDistance = featurePrintDistance
        self.hashDistance = hashDistance
    }

    public func detect(_ photos: [StackPhoto], decisions: [StackDecision] = []) -> PhotoStackIndex {
        let byID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var claimed = Set<String>()
        var stacks: [PhotoStack] = []

        // A stack someone touched stays as they left it.
        for decision in decisions.sorted(by: { $0.id < $1.id }) {
            if decision.isUnstacked {
                claimed.formUnion(decision.memberIDs.filter { byID[$0] != nil })
            }
            claimed.formUnion(decision.removedIDs.filter { byID[$0] != nil })
            guard !decision.isUnstacked else { continue }
            let members = decision.memberIDs
                .filter { byID[$0] != nil && !claimed.contains($0) && !decision.removedIDs.contains($0) }
                .compactMap { byID[$0] }
            claimed.formUnion(members.map(\.id))
            guard members.count > 1 else { continue }
            let ordered = members.sorted(by: Self.canonicalOrder)
            let chosen = decision.coverID.flatMap { cover in ordered.contains { $0.id == cover } ? cover : nil }
            stacks.append(PhotoStack(
                id: decision.id,
                memberIDs: ordered.map(\.id),
                coverID: chosen ?? Self.bestCover(ordered),
                isCoverChosen: chosen != nil
            ))
        }

        let ordered = photos
            .filter { $0.captureDate != nil && !claimed.contains($0.id) }
            .sorted(by: Self.canonicalOrder)
        var run: [StackPhoto] = []
        func close() {
            if run.count > 1 {
                stacks.append(PhotoStack(
                    id: "stack-\(run[0].id)",
                    memberIDs: run.map(\.id),
                    coverID: Self.bestCover(run),
                    isCoverChosen: false
                ))
            }
            run.removeAll(keepingCapacity: true)
        }
        for photo in ordered {
            if let last = run.last, let first = run.first,
               let date = photo.captureDate, let lastDate = last.captureDate, let firstDate = first.captureDate,
               date.timeIntervalSince(lastDate) <= maximumGap,
               date.timeIntervalSince(firstDate) <= maximumSpan,
               similar(last, photo) {
                run.append(photo)
            } else {
                close()
                run = [photo]
            }
        }
        close()
        return PhotoStackIndex(stacks)
    }

    /// Neighbouring shots look alike: by feature print when both have one,
    /// otherwise by difference hash. Without either they never stack.
    public func similar(_ lhs: StackPhoto, _ rhs: StackPhoto) -> Bool {
        if let left = lhs.featurePrint, let right = rhs.featurePrint,
           let distance = Self.cosineDistance(left, right) {
            return distance <= featurePrintDistance
        }
        if let left = lhs.perceptualHash, let right = rhs.perceptualHash {
            return (left ^ right).nonzeroBitCount <= hashDistance
        }
        return false
    }

    static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var dot = 0.0, left = 0.0, right = 0.0
        for index in lhs.indices {
            let a = Double(lhs[index]), b = Double(rhs[index])
            dot += a * b
            left += a * a
            right += b * b
        }
        guard left > 0, right > 0 else { return nil }
        return 1 - dot / (left.squareRoot() * right.squareRoot())
    }

    /// The shot to show for a stack: with people in it, a clear face with
    /// open eyes counts most; otherwise the sharpest. Each measure is
    /// compared within the stack only. Without measurements, the first shot.
    public static func bestCover(_ members: [StackPhoto]) -> String {
        let ordered = members.sorted(by: canonicalOrder)
        guard let first = ordered.first else { return "" }
        let measured = ordered.compactMap(\.quality)
        guard !measured.isEmpty else { return first.id }
        let sharpness = measured.map(\.sharpness)
        let faces = measured.map(\.faceQuality)
        let hasFaces = measured.contains { $0.faceCount > 0 }
        func normalized(_ value: Double, in values: [Double]) -> Double {
            guard let low = values.min(), let high = values.max(), high > low else { return 0.5 }
            return (value - low) / (high - low)
        }
        func score(_ photo: StackPhoto) -> Double {
            guard let quality = photo.quality else { return -1 }
            let sharp = normalized(quality.sharpness, in: sharpness)
            guard hasFaces else { return sharp }
            guard quality.faceCount > 0 else { return 0.2 * sharp }
            return 0.45 * normalized(quality.faceQuality, in: faces) + 0.35 * quality.eyesOpen + 0.2 * sharp
        }
        var best = first
        var bestScore = score(first)
        for photo in ordered.dropFirst() {
            let value = score(photo)
            // Earlier shots win ties, so the pick is stable.
            if value > bestScore + 1e-9 {
                best = photo
                bestScore = value
            }
        }
        return best.id
    }

    static func canonicalOrder(_ lhs: StackPhoto, _ rhs: StackPhoto) -> Bool {
        switch (lhs.captureDate, rhs.captureDate) {
        case let (left?, right?) where left != right: return left < right
        case (nil, .some): return false
        case (.some, nil): return true
        default: return lhs.id < rhs.id
        }
    }
}

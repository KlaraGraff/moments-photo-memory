import Foundation

/// How much the model looks at when organizing chapters.
public enum ChapterAIVision: String, CaseIterable, Codable, Sendable {
    /// Every photo is described once (the default).
    case allPhotos
    /// A few photos a day, spread over the day.
    case sampled
    /// No images: dates, places, people and notes only.
    case textOnly
}

/// Chooses the photos the model describes.
public struct CaptionSampler: Sendable {
    public struct Photo: Equatable, Sendable {
        public let id: String
        public let dayKey: String
        public let date: Date
        /// The 64-bit difference hash written at import.
        public let hash: UInt64?
        public let hasFaces: Bool
        public let isScreenshot: Bool

        public init(id: String, dayKey: String, date: Date, hash: UInt64? = nil, hasFaces: Bool = false, isScreenshot: Bool = false) {
            self.id = id
            self.dayKey = dayKey
            self.date = date
            self.hash = hash
            self.hasFaces = hasFaces
            self.isScreenshot = isScreenshot
        }
    }

    /// Sampled: this many photos a day at least, one more per
    /// `photosPerExtra`, never more than `maximumPerDay`.
    public var minimumPerDay = 2
    public var photosPerExtra = 8
    public var maximumPerDay = 8
    /// Photos this close in time, or this alike, count as one.
    public var burstGap: TimeInterval = 60
    public var hashDistance = 8

    public init() {}

    /// The ids to describe, oldest first. Screenshots are never described:
    /// they are counted as documents instead.
    public func choose(_ photos: [Photo], vision: ChapterAIVision) -> [String] {
        let candidates = photos.filter { !$0.isScreenshot }.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        switch vision {
        case .textOnly:
            return []
        case .allPhotos:
            return candidates.map(\.id)
        case .sampled:
            let byDay = Dictionary(grouping: candidates, by: \.dayKey)
            return byDay.keys.sorted().flatMap { key -> [String] in
                let day = distinct(byDay[key] ?? [])
                let limit = min(maximumPerDay, minimumPerDay + day.count / max(photosPerExtra, 1))
                return pick(day, limit: limit).map(\.id)
            }
        }
    }

    /// One photo per burst and per near-duplicate run, the one with faces if any.
    func distinct(_ photos: [Photo]) -> [Photo] {
        var result: [Photo] = []
        for photo in photos {
            if let last = result.last, isSame(last, photo) {
                if photo.hasFaces && !last.hasFaces { result[result.count - 1] = photo }
            } else {
                result.append(photo)
            }
        }
        return result
    }

    private func isSame(_ a: Photo, _ b: Photo) -> Bool {
        if abs(b.date.timeIntervalSince(a.date)) <= burstGap { return true }
        guard let left = a.hash, let right = b.hash else { return false }
        return (left ^ right).nonzeroBitCount <= hashDistance
    }

    /// Spread over the day; inside each stretch, a photo with faces first.
    private func pick(_ photos: [Photo], limit: Int) -> [Photo] {
        guard photos.count > limit, limit > 0 else { return limit > 0 ? photos : [] }
        return (0..<limit).compactMap { part in
            let lower = part * photos.count / limit
            let upper = (part + 1) * photos.count / limit
            let stretch = photos[lower..<upper]
            return stretch.first(where: \.hasFaces) ?? stretch.first
        }
    }
}

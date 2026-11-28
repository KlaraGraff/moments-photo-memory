import Foundation

/// A place of daily life, measured against: where the person lives or works,
/// or their home town.
public struct EvidenceBase: Equatable, Sendable {
    public var role: PlaceRole
    /// The name the person gave, shown on this Mac only.
    public var name: String?
    public var centre: GeoPoint

    public init(role: PlaceRole, name: String? = nil, centre: GeoPoint) {
        self.role = role
        self.name = name
        self.centre = centre
    }
}

/// Everything the judge knows about one stretch of photos, as plain facts.
///
/// It holds no photo and no coordinate, only dates, counts, distances in
/// kilometres and words for what the photos show. It is what a model is
/// sent, and what is remembered when the person corrects a chapter.
public struct SegmentEvidence: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    /// Calendar days from the first photo to the last, both counted.
    public var dayCount: Int
    /// Of those days, how many fall on a weekend.
    public var weekendDayCount: Int
    /// The first and the last day of the week (1 is Sunday, 7 Saturday).
    public var firstWeekday: Int
    public var lastWeekday: Int
    public var photoCount: Int
    /// Days with at least one photo.
    public var photoDayCount: Int
    /// Share of photos taken on a workday between 8:00 and 18:00.
    public var workHourShare: Double
    /// From the middle of the photos to the nearest place where the person
    /// lives or works, in kilometres. Nil when none is known.
    public var kmFromBase: Double?
    public var baseRole: PlaceRole?
    /// That place's name, shown on this Mac only: never sent to a model.
    public var baseName: String?
    /// From the middle of the photos to the nearest home town.
    public var kmFromHomeTown: Double?
    /// True when the photos are in another country than daily life.
    public var isAbroad: Bool?
    /// Photos whose scenes were looked at.
    public var sceneSample: Int
    /// Of those, the share showing work (sites, machines, papers, offices)
    /// and the share showing leisure (sea, mountains, sights, meals).
    public var workSceneShare: Double?
    public var leisureSceneShare: Double?
    /// The words seen most often, most common first.
    public var sceneWords: [String]
    /// The city or area the photos were taken in.
    public var placeName: String?
    /// The chapter's title, when the person gave one.
    public var title: String?
    /// Changes whenever a photo joins or leaves the stretch.
    public var photoSetHash: String?

    public init(
        start: Date,
        end: Date,
        dayCount: Int,
        weekendDayCount: Int,
        firstWeekday: Int = 1,
        lastWeekday: Int = 1,
        photoCount: Int,
        photoDayCount: Int,
        workHourShare: Double,
        kmFromBase: Double? = nil,
        baseRole: PlaceRole? = nil,
        baseName: String? = nil,
        kmFromHomeTown: Double? = nil,
        isAbroad: Bool? = nil,
        sceneSample: Int = 0,
        workSceneShare: Double? = nil,
        leisureSceneShare: Double? = nil,
        sceneWords: [String] = [],
        placeName: String? = nil,
        title: String? = nil,
        photoSetHash: String? = nil
    ) {
        self.start = start
        self.end = end
        self.dayCount = max(1, dayCount)
        self.weekendDayCount = min(max(0, weekendDayCount), max(1, dayCount))
        self.firstWeekday = firstWeekday
        self.lastWeekday = lastWeekday
        self.photoCount = max(0, photoCount)
        self.photoDayCount = max(1, photoDayCount)
        self.workHourShare = min(max(0, workHourShare), 1)
        self.kmFromBase = kmFromBase
        self.baseRole = baseRole
        self.baseName = baseName
        self.kmFromHomeTown = kmFromHomeTown
        self.isAbroad = isAbroad
        self.sceneSample = max(0, sceneSample)
        self.workSceneShare = workSceneShare
        self.leisureSceneShare = leisureSceneShare
        self.sceneWords = sceneWords
        self.placeName = placeName
        self.title = title
        self.photoSetHash = photoSetHash
    }

    private enum CodingKeys: String, CodingKey {
        case start, end, dayCount, weekendDayCount, firstWeekday, lastWeekday, photoCount, photoDayCount
        case workHourShare, kmFromBase, baseRole, kmFromHomeTown, isAbroad, sceneSample, workSceneShare
        case leisureSceneShare, sceneWords, placeName, title, photoSetHash
    }

    /// Stored evidence goes through the same limits as new evidence, so a
    /// damaged value never divides by zero. The base's name is never stored.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            start: try c.decode(Date.self, forKey: .start),
            end: try c.decode(Date.self, forKey: .end),
            dayCount: try c.decode(Int.self, forKey: .dayCount),
            weekendDayCount: (try? c.decodeIfPresent(Int.self, forKey: .weekendDayCount)) ?? 0,
            firstWeekday: (try? c.decodeIfPresent(Int.self, forKey: .firstWeekday)) ?? 1,
            lastWeekday: (try? c.decodeIfPresent(Int.self, forKey: .lastWeekday)) ?? 1,
            photoCount: (try? c.decodeIfPresent(Int.self, forKey: .photoCount)) ?? 0,
            photoDayCount: (try? c.decodeIfPresent(Int.self, forKey: .photoDayCount)) ?? 1,
            workHourShare: (try? c.decodeIfPresent(Double.self, forKey: .workHourShare)) ?? 0,
            kmFromBase: try? c.decodeIfPresent(Double.self, forKey: .kmFromBase),
            baseRole: try? c.decodeIfPresent(PlaceRole.self, forKey: .baseRole),
            kmFromHomeTown: try? c.decodeIfPresent(Double.self, forKey: .kmFromHomeTown),
            isAbroad: try? c.decodeIfPresent(Bool.self, forKey: .isAbroad),
            sceneSample: (try? c.decodeIfPresent(Int.self, forKey: .sceneSample)) ?? 0,
            workSceneShare: try? c.decodeIfPresent(Double.self, forKey: .workSceneShare),
            leisureSceneShare: try? c.decodeIfPresent(Double.self, forKey: .leisureSceneShare),
            sceneWords: (try? c.decodeIfPresent([String].self, forKey: .sceneWords)) ?? [],
            placeName: try? c.decodeIfPresent(String.self, forKey: .placeName),
            title: try? c.decodeIfPresent(String.self, forKey: .title),
            photoSetHash: try? c.decodeIfPresent(String.self, forKey: .photoSetHash)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(dayCount, forKey: .dayCount)
        try c.encode(weekendDayCount, forKey: .weekendDayCount)
        try c.encode(firstWeekday, forKey: .firstWeekday)
        try c.encode(lastWeekday, forKey: .lastWeekday)
        try c.encode(photoCount, forKey: .photoCount)
        try c.encode(photoDayCount, forKey: .photoDayCount)
        try c.encode(workHourShare, forKey: .workHourShare)
        try c.encodeIfPresent(kmFromBase, forKey: .kmFromBase)
        try c.encodeIfPresent(baseRole, forKey: .baseRole)
        try c.encodeIfPresent(kmFromHomeTown, forKey: .kmFromHomeTown)
        try c.encodeIfPresent(isAbroad, forKey: .isAbroad)
        try c.encode(sceneSample, forKey: .sceneSample)
        try c.encodeIfPresent(workSceneShare, forKey: .workSceneShare)
        try c.encodeIfPresent(leisureSceneShare, forKey: .leisureSceneShare)
        try c.encode(sceneWords, forKey: .sceneWords)
        try c.encodeIfPresent(placeName, forKey: .placeName)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(photoSetHash, forKey: .photoSetHash)
    }

    /// The place name and title, unless they could name where the person
    /// lives or works: near daily life, or holding the name of one of their
    /// places (`privateNames`, plus this stretch's base).
    public func shareablePlaceName(privateNames: [String] = []) -> String? { shareable(placeName, privateNames: privateNames) }
    public func shareableTitle(privateNames: [String] = []) -> String? { shareable(title, privateNames: privateNames) }

    /// Any text about this stretch, such as an example's title, held to
    /// the same test.
    public func shareable(_ text: String?, privateNames: [String] = []) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let km = kmFromBase, km < 150 { return nil }
        let lowered = text.lowercased()
        for name in privateNames + [baseName].compactMap({ $0 }) {
            let base = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !base.isEmpty else { continue }
            if lowered.contains(base) || base.contains(lowered) { return nil }
        }
        return text
    }

    public var weekendShare: Double { Double(weekendDayCount) / Double(max(dayCount, 1)) }
    public var workdayCount: Int { max(0, dayCount - weekendDayCount) }
    public var photosPerDay: Double { Double(photoCount) / Double(max(photoDayCount, 1)) }

    /// Changes when the photos of the stretch change, so a stretch whose
    /// photos moved is judged again.
    public var signature: String {
        "\(photoCount)-\(Int(start.timeIntervalSince1970))-\(Int(end.timeIntervalSince1970))-\(photoSetHash ?? "")"
    }
}

extension SegmentEvidence {
    /// Builds the evidence for a stretch from its photos.
    ///
    /// - Parameters:
    ///   - photos: the stretch's photos, in any order.
    ///   - bases: where the person lives, works and comes from.
    ///   - scenes: for each photo looked at, the words for what it shows.
    ///   - calendar: the person's calendar, which says what a weekend is.
    public static func make(
        photos: [PhotoStop],
        bases: [EvidenceBase],
        scenes: [[String]] = [],
        calendar: Calendar,
        isAbroad: Bool? = nil,
        placeName: String? = nil,
        title: String? = nil
    ) -> SegmentEvidence? {
        let dates = photos.map(\.date).sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        let firstDay = calendar.startOfDay(for: first)
        let lastDay = calendar.startOfDay(for: last)
        let span = (calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0) + 1
        var weekendDays = 0
        var day = firstDay
        for _ in 0..<min(span, 3_660) {
            if calendar.isDateInWeekend(day) { weekendDays += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        let photoDays = Set(dates.map { calendar.startOfDay(for: $0) }).count
        let workHourPhotos = dates.filter { date in
            guard !calendar.isDateInWeekend(date) else { return false }
            let hour = calendar.component(.hour, from: date)
            return (8..<18).contains(hour)
        }.count

        let located = photos.compactMap(\.coordinate)
        var kmFromBase: Double?
        var baseRole: PlaceRole?
        var baseName: String?
        var kmFromHomeTown: Double?
        if let centre = Self.median(located) {
            let daily = bases.filter { $0.role == .home || $0.role == .work }
            if let nearest = daily.min(by: { $0.centre.distance(to: centre) < $1.centre.distance(to: centre) }) {
                kmFromBase = nearest.centre.distance(to: centre) / 1_000
                baseRole = nearest.role
                baseName = nearest.name
            }
            kmFromHomeTown = bases.filter { $0.role == .homeTown }
                .map { $0.centre.distance(to: centre) / 1_000 }
                .min()
        }
        let summary = SceneVocabulary.summarize(scenes)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for id in photos.map(\.id).sorted() {
            for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            hash = (hash ^ 0x1f) &* 0x0000_0100_0000_01b3
        }
        return SegmentEvidence(
            start: first,
            end: last,
            dayCount: span,
            weekendDayCount: weekendDays,
            firstWeekday: calendar.component(.weekday, from: first),
            lastWeekday: calendar.component(.weekday, from: last),
            photoCount: dates.count,
            photoDayCount: photoDays,
            workHourShare: dates.isEmpty ? 0 : Double(workHourPhotos) / Double(dates.count),
            kmFromBase: kmFromBase,
            baseRole: baseRole,
            baseName: baseName,
            kmFromHomeTown: kmFromHomeTown,
            isAbroad: isAbroad,
            sceneSample: summary.sample,
            workSceneShare: summary.workShare,
            leisureSceneShare: summary.leisureShare,
            sceneWords: summary.words,
            placeName: placeName,
            title: title,
            photoSetHash: String(hash, radix: 16)
        )
    }

    /// The point in the middle of the photos, robust to a few stray ones.
    static func median(_ points: [GeoPoint]) -> GeoPoint? {
        guard !points.isEmpty else { return nil }
        let latitudes = points.map(\.latitude).sorted()
        let longitudes = points.map(\.longitude).sorted()
        return GeoPoint(latitude: latitudes[latitudes.count / 2], longitude: longitudes[longitudes.count / 2])
    }
}

/// Sorts the words an image classifier gives for a photo into work and
/// leisure. The words are the classifier's own identifiers, such as
/// "construction_vehicle" or "beach".
public enum SceneVocabulary {
    static let work: Set<String> = [
        "construction", "crane", "excavator", "bulldozer", "scaffolding", "scaffold", "machinery", "machine",
        "tool", "tools", "document", "documents", "paper", "papers", "text", "whiteboard", "blackboard",
        "office", "conference", "meeting", "computer", "laptop", "monitor", "keyboard", "cable", "pipe",
        "pipes", "concrete", "brick", "bricks", "steel", "rebar", "factory", "warehouse", "industrial",
        "blueprint", "diagram", "chart", "receipt", "hardhat", "helmet", "forklift", "truck", "workshop",
        "drill", "plywood", "lumber", "cement", "site", "presentation", "projector", "printer",
    ]
    static let leisure: Set<String> = [
        "beach", "sea", "ocean", "shore", "coast", "seashore", "mountain", "mountains", "hill", "desert",
        "dune", "lake", "river", "waterfall", "forest", "park", "garden", "landmark", "monument", "castle",
        "temple", "mosque", "church", "cathedral", "museum", "ruins", "palace", "food", "meal", "dish",
        "dessert", "cake", "restaurant", "cafe", "bar", "drink", "cocktail", "wine", "pool", "sunset",
        "sunrise", "camel", "boat", "sailboat", "island", "snow", "ski", "festival", "fireworks",
        "souvenir", "market", "bazaar", "canyon", "cliff", "valley", "zoo", "aquarium", "amusement",
        "hiking", "picnic", "selfie", "statue", "fountain", "harbor", "harbour", "palm",
    ]

    public struct Summary: Equatable, Sendable {
        public var sample: Int
        public var workShare: Double?
        public var leisureShare: Double?
        public var words: [String]
    }

    /// What one photo shows: work, leisure or neither.
    public enum Lean: Equatable, Sendable { case work, leisure, neither }

    public static func lean(of identifiers: [String]) -> Lean {
        var workHits = 0
        var leisureHits = 0
        for identifier in identifiers {
            let tokens = tokens(of: identifier)
            if tokens.contains(where: work.contains) { workHits += 1 }
            if tokens.contains(where: leisure.contains) { leisureHits += 1 }
        }
        if workHits > leisureHits { return .work }
        if leisureHits > workHits { return .leisure }
        return .neither
    }

    public static func summarize(_ scenes: [[String]]) -> Summary {
        let sampled = scenes.filter { !$0.isEmpty }
        guard !sampled.isEmpty else { return Summary(sample: 0, workShare: nil, leisureShare: nil, words: []) }
        var workCount = 0
        var leisureCount = 0
        var counts: [String: Int] = [:]
        for identifiers in sampled {
            switch lean(of: identifiers) {
            case .work: workCount += 1
            case .leisure: leisureCount += 1
            case .neither: break
            }
            for identifier in Set(identifiers) {
                counts[readable(identifier), default: 0] += 1
            }
        }
        let words = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(6)
            .map(\.key)
        let total = Double(sampled.count)
        return Summary(
            sample: sampled.count,
            workShare: Double(workCount) / total,
            leisureShare: Double(leisureCount) / total,
            words: words
        )
    }

    static func tokens(of identifier: String) -> [String] {
        identifier.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
    }

    static func readable(_ identifier: String) -> String {
        tokens(of: identifier).joined(separator: " ")
    }
}

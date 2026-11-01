import Foundation

/// Turns the model's chapters into photos per chapter, leaving alone what
/// people made or changed by hand.
public enum ChapterAssignment {
    public struct Item: Equatable, Sendable {
        public let id: String
        public let dayKey: String
        public let isScreenshot: Bool
        /// May change trips: not placed by hand, and not in a trip someone
        /// made, renamed or edited.
        public let isFree: Bool
        /// In a trip that Moments made and nobody touched.
        public let isInMachineTrip: Bool

        public init(id: String, dayKey: String, isScreenshot: Bool = false, isFree: Bool = true, isInMachineTrip: Bool = false) {
            self.id = id
            self.dayKey = dayKey
            self.isScreenshot = isScreenshot
            self.isFree = isFree
            self.isInMachineTrip = isInMachineTrip
        }
    }

    /// Days already in a chapter someone made or edited, or a chapter
    /// someone deleted after Moments made it.
    public struct Taken: Equatable, Sendable {
        public let start: String
        public let end: String
        public let isTrip: Bool

        public init(start: String, end: String, isTrip: Bool) {
            self.start = start
            self.end = end
            self.isTrip = isTrip
        }
    }

    public struct Chapter: Equatable, Sendable {
        public let proposal: ChapterProposal
        /// Oldest day first, then by id.
        public let itemIDs: [String]
    }

    public struct Result: Equatable, Sendable {
        public var trips: [Chapter] = []
        public var chapters: [Chapter] = []
        /// Photos to take out of the trip Moments put them in.
        public var leaving: [String] = []
        /// Proposals left out: already taken, or without photos.
        public var skipped: [ChapterProposal] = []
    }

    /// A proposal sharing at least this much of its days with a taken
    /// chapter of the same kind is that chapter again.
    public static let takenShare = 0.5

    /// `scope` limits which photos may leave a trip: only days inside it
    /// were looked at again.
    public static func assign(
        items: [Item],
        proposals: [ChapterProposal],
        taken: [Taken] = [],
        scope: ClosedRange<String>? = nil
    ) -> Result {
        let photos = items.filter { !$0.isScreenshot && DayKey.ordinal($0.dayKey) != nil }
            .sorted { ($0.dayKey, $0.id) < ($1.dayKey, $1.id) }
        var result = Result()
        var inAITrip = Set<String>()
        for proposal in proposals {
            let isTrip = proposal.type == .trip
            let clash = taken.contains { other in
                other.isTrip == isTrip
                    && proposal.overlapShare(with: ChapterProposal(start: other.start, end: other.end, type: proposal.type, title: "")) >= takenShare
            }
            let members = photos.filter { item in
                item.dayKey >= proposal.start && item.dayKey <= proposal.end
                    && (!isTrip || (item.isFree && !inAITrip.contains(item.id)))
            }.map(\.id)
            guard !clash, !members.isEmpty else {
                result.skipped.append(proposal)
                continue
            }
            if isTrip {
                inAITrip.formUnion(members)
                result.trips.append(Chapter(proposal: proposal, itemIDs: members))
            } else {
                result.chapters.append(Chapter(proposal: proposal, itemIDs: members))
            }
        }
        result.leaving = items.filter { item in
            item.isFree && item.isInMachineTrip && !inAITrip.contains(item.id)
                && (scope.map { $0.contains(item.dayKey) } ?? true)
        }.map(\.id).sorted()
        return result
    }
}

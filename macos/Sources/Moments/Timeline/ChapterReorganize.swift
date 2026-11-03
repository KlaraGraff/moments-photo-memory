import Foundation
import SwiftData

/// The manual "reorganize" on Chapters: groups trips again by the current
/// rules and looks at the big days someone deleted once more.
///
/// `TripRegrouping.runOnce` only runs after a rules change, so a library keeps
/// the grouping it got then. This runs when the person asks for it, and it
/// keeps every hand edit exactly as `TripRegrouping` does (a trip renamed,
/// confirmed, merged, split, given a cover or a memory, or holding a
/// hand-placed photo), plus the trips of photos placed by hand. Then it
/// forgets which big days were suggested before, so `EventSuggestions` thinks
/// about them again: an event deleted by hand comes back once, and deleting it
/// again keeps it gone.
enum ChapterReorganize {
    struct Outcome: Equatable {
        var regroup: TripRegrouping.Outcome
        var events: Int
    }

    @MainActor
    static func run(
        context: ModelContext,
        defaults: UserDefaults = TripAssignmentLocks.store
    ) throws -> Outcome {
        // The same two lists `TripRegrouping.runOnce` reads, so a manual run
        // keeps what an automatic one keeps.
        let covered = Set(TripCoverChoice.decode(defaults.string(forKey: TripCoverChoice.defaultsKey) ?? "").keys)
        let regroup = try TripRegrouping.regroup(
            context: context,
            locked: TripAssignmentLocks.lockedIDs(defaults: defaults),
            covered: covered
        )
        // Daily life has left its trips, so its big days can become events.
        defaults.set(TripRegrouping.currentVersion, forKey: TripRegrouping.versionKey)
        // Someone asking for a regroup means deleted events too: the list of
        // days already suggested goes, so a big day deleted by hand is
        // suggested once more. `suggest` writes back only what it saw now.
        defaults.removeObject(forKey: EventSuggestions.suggestedDaysKey)
        let events = EventSuggestions.suggest(in: context, defaults: defaults)
        try context.save()
        return Outcome(regroup: regroup, events: events)
    }
}

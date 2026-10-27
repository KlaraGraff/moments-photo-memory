import Foundation
import MomentsCore
import SwiftData

/// Turns the big days of daily life (`BigDayFinder`) into Event chapters,
/// after an import. Only photos in no trip count: days away are trips
/// already. A day suggested once is never suggested again, so an event
/// someone deletes stays gone, and days a chapter already covers are left
/// alone.
enum EventSuggestions {
    static let suggestedDaysKey = "moments.chapter.suggestedEventDays"

    @MainActor
    @discardableResult
    static func suggest(
        in context: ModelContext,
        defaults: UserDefaults = TripAssignmentLocks.store,
        calendar: Calendar = .current,
        now: Date = .now
    ) -> Int {
        let items = (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        let daily = items.filter { $0.tripID == nil && $0.trip == nil && !$0.isScreenshot }
        let photos = daily.compactMap { item -> BigDayFinder.Photo? in
            guard let key = item.localDayKey, let date = item.effectiveCaptureDate else { return nil }
            return BigDayFinder.Photo(dayKey: key, date: date)
        }
        let runs = BigDayFinder().bigDays(photos)
        guard !runs.isEmpty else { return 0 }

        var suggested = Set(defaults.stringArray(forKey: suggestedDaysKey) ?? [])
        let chapters = (try? context.fetch(FetchDescriptor<UserGroup>(predicate: #Predicate { $0.kindRaw == "chapter" }))) ?? []
        let covered = chapters.compactMap { group -> ClosedRange<String>? in
            let info = group.chapterInfo
            guard let start = info.startDate, let end = info.endDate, start <= end else { return nil }
            return dayKey(start, calendar: calendar)...dayKey(end, calendar: calendar)
        }
        let byDay = Dictionary(grouping: daily.filter { $0.localDayKey != nil }, by: { $0.localDayKey ?? "" })
        var created = 0
        for run in runs {
            guard let first = run.first, let last = run.last,
                  !run.contains(where: suggested.contains),
                  !covered.contains(where: { $0.overlaps(first...last) }),
                  let start = dayStart(first, calendar: calendar),
                  let lastStart = dayStart(last, calendar: calendar),
                  let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: lastStart) else { continue }
            let group = UserGroup(name: name(start: start, calendar: calendar), kind: .chapter, createdAt: now, updatedAt: now)
            group.chapterInfo = ChapterInfo(type: ChapterType.event.raw, symbol: nil, startDate: start, endDate: end)
            context.insert(group)
            for item in run.flatMap({ byDay[$0] ?? [] }) {
                context.insert(UserGroupItem(groupID: group.id, mediaID: item.id, addedAt: now))
            }
            suggested.formUnion(run)
            created += 1
        }
        guard created > 0 else { return 0 }
        try? context.save()
        defaults.set(Array(suggested).sorted(), forKey: suggestedDaysKey)
        return created
    }

    /// "Event 3 October 2026", in the person's language.
    static func name(start: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.year().month(.wide).day()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return ChapterType.event.label + " " + start.formatted(style)
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func dayStart(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

import Foundation
import MomentsCore
import SwiftData

/// Organizes Chapters with Claude, in three steps:
/// 1. Describe: the model writes one line about each photo it has not seen
///    yet (every photo, a few a day, or none, per Settings). Lines are kept
///    on this Mac, so a photo is looked at once.
/// 2. Organize: each day becomes one line of text (places, counts, people,
///    notes, the descriptions, the rules' hints) and the model reads the
///    lines and proposes trips, events, celebrations and stretches of time.
/// 3. Write: `ChapterAIApplier` writes them, leaving hand edits alone.
///
/// Only names and words go out, plus small JPEGs without metadata: never
/// coordinates, file paths or a partner's photos.
@MainActor
final class ChapterAIOrganizer {
    enum Phase: Equatable {
        case describing
        case organizing
        case writing
    }

    struct Progress: Equatable {
        var phase: Phase
        var done: Int
        var total: Int
    }

    struct Outcome {
        var described = 0
        /// Photos with no copy on this Mac, or whose batch failed.
        var notDescribed = 0
        var captionUsage = ModelUsage()
        var chapterUsage = ModelUsage()
        var windows = 0
        var failedWindows = 0
        var failedIndices: Set<Int> = []
        /// Days of the windows that failed, left as they were.
        var frozen: [ClosedRange<String>] = []
        var proposals: [ChapterProposal] = []
        var written: ChapterAIApplier.Written?

        var usage: ModelUsage { captionUsage + chapterUsage }
    }

    let context: ModelContext
    let client: ClaudeChapterClient
    var vision: ChapterAIVision = ChapterAISettings.vision()
    var language = ChapterAISettings.languageName
    var captions: PhotoCaptionStore = .shared
    var photos: (any PhotosAssetSource)? = PhotoKitAssetSource()
    var defaults: UserDefaults = TripAssignmentLocks.store
    var calendar: Calendar = .current
    var digest = ChapterDigest()
    /// Photos per describing request.
    var batchSize = 40
    var parallelRequests = 4
    /// Off for a run that only reports what it would do.
    var writes = true
    var onProgress: (Progress) -> Void = { _ in }
    /// Each request's text and answer, for a test run's report.
    var onExchange: ((_ name: String, _ request: String, _ answer: String) -> Void)?

    init(context: ModelContext, client: ClaudeChapterClient) {
        self.context = context
        self.client = client
    }

    private struct Entry {
        let item: MediaItem
        let dayKey: String
        let date: Date
    }

    /// `scope`: only these days and two weeks around them, after an
    /// import; nil for the whole library.
    func run(scope: ClosedRange<String>? = nil) async throws -> Outcome {
        var outcome = Outcome()
        let undated = ImportCaptureDateSource.fileDateFallback.rawValue
        let items = try context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil }))
        let entries = items.compactMap { item -> Entry? in
            guard ChapterAIApplier.isMine(item), item.captureDateSourceRaw != undated,
                  let date = item.effectiveCaptureDate, let key = PhotoNoteDay.key(for: item) else { return nil }
            return Entry(item: item, dayKey: key, date: date)
        }.sorted { ($0.date, $0.item.id) < ($1.date, $1.item.id) }
        let window = scope.map { scope in
            (DayKey.adding(-14, to: scope.lowerBound) ?? scope.lowerBound)...(DayKey.adding(14, to: scope.upperBound) ?? scope.upperBound)
        }
        let considered = window.map { range in entries.filter { range.contains($0.dayKey) } } ?? entries
        guard !considered.isEmpty else { throw ChapterAIError.noPhotos }

        let faces = try faceNames()
        try await describe(considered, faces: faces, outcome: &outcome)

        let applier = ChapterAIApplier(context: context, defaults: defaults, calendar: calendar)
        let state = try applier.state()
        let days = evidence(considered, library: entries, faces: faces, state: state, applier: applier)
        let windows = digest.windows(days)
        outcome.windows = windows.count
        let answers = try await organize(windows, outcome: &outcome)
        var proposals = ChapterPlan.merge(answers)
        // Days a failed window covers and no other window does.
        let covered = zip(windows, answers.indices).filter { !outcome.failedIndices.contains($0.1) }.map { $0.0.firstDay...$0.0.lastDay }
        outcome.frozen = outcome.failedIndices.sorted().map { windows[$0].firstDay...windows[$0].lastDay }.flatMap { range in
            Self.uncovered(range, by: covered)
        }
        var applied = scope
        if let scope {
            proposals = proposals.filter { $0.end >= scope.lowerBound && $0.start <= scope.upperBound }
            // A trip running past the new days is redone whole.
            applied = proposals.reduce(scope) { range, proposal in
                min(range.lowerBound, proposal.start)...max(range.upperBound, proposal.end)
            }
        }
        outcome.proposals = proposals

        guard writes, outcome.windows > 0, outcome.failedWindows < outcome.windows else { return outcome }
        onProgress(Progress(phase: .writing, done: 0, total: 1))
        outcome.written = try applier.apply(proposals, scope: applied, frozen: outcome.frozen)
        onProgress(Progress(phase: .writing, done: 1, total: 1))
        return outcome
    }

    // MARK: - Describing

    private struct Batch: Sendable {
        struct Photo: Sendable {
            let id: String
            let label: String
            let source: ChapterAIThumbnails.Source
        }
        let photos: [Photo]
    }

    private enum BatchResult: Sendable {
        case described([String: ChapterPrompts.Caption], missing: Int, usage: ModelUsage, request: String, answer: String)
        case failed(Error, count: Int)
    }

    private func describe(_ entries: [Entry], faces: [String: [String]], outcome: inout Outcome) async throws {
        let samples = entries.map { entry in
            CaptionSampler.Photo(
                id: entry.item.id,
                dayKey: entry.dayKey,
                date: entry.date,
                hash: StackPhoto.hash(fromHex: entry.item.perceptualHash),
                hasFaces: faces[entry.item.id] != nil,
                isScreenshot: entry.item.isScreenshot
            )
        }
        let byID = Dictionary(entries.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
        let wanted = CaptionSampler().choose(samples, vision: vision).filter { captions.caption(for: $0) == nil }
        guard !wanted.isEmpty else { return }
        let batches = stride(from: 0, to: wanted.count, by: batchSize).map { start in
            Batch(photos: wanted[start..<min(start + batchSize, wanted.count)].compactMap { id in
                guard let entry = byID[id] else { return nil }
                let item = entry.item
                return Batch.Photo(
                    id: id,
                    label: label(for: entry),
                    source: .init(id: id, photosLocalIdentifier: item.photosLocalIdentifier, bookmark: item.originalBookmarkData, isVideo: item.kind == .video)
                )
            })
        }
        let instructions = ChapterPrompts.captionInstructions(language: language)
        let schema = ChapterPrompts.captionSchema
        let client = client
        let photos = photos
        var done = 0
        onProgress(Progress(phase: .describing, done: 0, total: wanted.count))

        try await withThrowingTaskGroup(of: BatchResult.self) { group in
            var next = 0
            while next < min(parallelRequests, batches.count) {
                let batch = batches[next]
                next += 1
                group.addTask { await Self.describeBatch(batch, client: client, photos: photos, instructions: instructions, schema: schema) }
            }
            while let result = try await group.next() {
                switch result {
                case let .described(new, missing, usage, request, answer):
                    captions.add(new)
                    outcome.described += new.count
                    outcome.notDescribed += missing
                    outcome.captionUsage += usage
                    done += new.count + missing
                    onExchange?("describe", request, answer)
                case let .failed(error, count):
                    // A bad key or a refused network stops the run; anything
                    // else leaves these photos for the next run.
                    if case NoteOrganizerError.http(let status, _) = error, status == 401 || status == 403 {
                        group.cancelAll()
                        throw error
                    }
                    if case NoteOrganizerError.missingKey = error { throw error }
                    outcome.notDescribed += count
                    done += count
                }
                onProgress(Progress(phase: .describing, done: done, total: wanted.count))
                if next < batches.count {
                    let batch = batches[next]
                    next += 1
                    group.addTask { await Self.describeBatch(batch, client: client, photos: photos, instructions: instructions, schema: schema) }
                }
            }
        }
    }

    nonisolated private static func describeBatch(
        _ batch: Batch,
        client: ClaudeChapterClient,
        photos: (any PhotosAssetSource)?,
        instructions: String,
        schema: [String: Any]
    ) async -> BatchResult {
        var content: [[String: Any]] = []
        var numbered: [String] = []
        var labels: [String] = []
        for photo in batch.photos {
            guard let jpeg = await ChapterAIThumbnails.jpeg(for: photo.source, photos: photos) else { continue }
            numbered.append(photo.id)
            let label = ChapterPrompts.captionLabel(number: numbered.count, time: nil, place: nil) + photo.label
            labels.append(label)
            content.append(ClaudeChapterClient.text(label))
            content.append(ClaudeChapterClient.image(jpeg: jpeg))
        }
        let missing = batch.photos.count - numbered.count
        guard !numbered.isEmpty else {
            return .described([:], missing: missing, usage: ModelUsage(), request: "", answer: "")
        }
        content.append(ClaudeChapterClient.text("Describe photos 1 to \(numbered.count)."))
        do {
            let reply = try await client.send(system: instructions, content: content, schema: schema, maxTokens: 8_000, effort: "low", thinking: false)
            let parsed = try ChapterPrompts.parseCaptions(reply.text, count: numbered.count)
            var result: [String: ChapterPrompts.Caption] = [:]
            for (number, caption) in parsed { result[numbered[number - 1]] = caption }
            return .described(result, missing: missing + numbered.count - result.count, usage: reply.usage, request: labels.joined(separator: "\n"), answer: reply.text)
        } catch {
            return .failed(error, count: batch.photos.count)
        }
    }

    /// " · 14:05 · Kyoto, Gion": the photo's own local time and place.
    private func label(for entry: Entry) -> String {
        var local = calendar
        if let identifier = entry.item.timeZoneIdentifier, let zone = TimeZone(identifier: identifier) {
            local.timeZone = zone
        } else if let minutes = entry.item.localTimeZoneOffsetMinutes, let zone = TimeZone(secondsFromGMT: minutes * 60) {
            local.timeZone = zone
        }
        let parts = local.dateComponents([.hour, .minute], from: entry.date)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let place = placeNames(of: entry.item).joined(separator: ", ")
        return " · " + ([time] + (place.isEmpty ? [] : [place])).joined(separator: " · ")
    }

    // MARK: - Organizing

    /// The parts of `range` no range in `others` covers.
    static func uncovered(_ range: ClosedRange<String>, by others: [ClosedRange<String>]) -> [ClosedRange<String>] {
        guard let first = DayKey.ordinal(range.lowerBound), let last = DayKey.ordinal(range.upperBound) else { return [range] }
        let spans = others.compactMap { other -> ClosedRange<Int>? in
            guard let start = DayKey.ordinal(other.lowerBound), let end = DayKey.ordinal(other.upperBound), start <= end else { return nil }
            return start...end
        }
        var result: [ClosedRange<String>] = []
        var runStart: Int?
        for day in first...(last + 1) {
            let open = day <= last && !spans.contains { $0.contains(day) }
            if open, runStart == nil { runStart = day }
            if !open, let start = runStart {
                result.append(DayKey.key(ordinal: start)...DayKey.key(ordinal: day - 1))
                runStart = nil
            }
        }
        return result
    }

    private func organize(_ windows: [ChapterDigest.Window], outcome: inout Outcome) async throws -> [[ChapterProposal]] {
        let instructions = ChapterPrompts.chapterInstructions(language: language)
        let schema = ChapterPrompts.chapterSchema
        let client = client
        let messages = windows.map(ChapterPrompts.chapterMessage)
        let onExchange = onExchange
        let onProgress = onProgress
        var answers: [[ChapterProposal]] = Array(repeating: [], count: windows.count)
        var done = 0
        onProgress(Progress(phase: .organizing, done: 0, total: windows.count))
        try await withThrowingTaskGroup(of: (Int, Result<ClaudeChapterClient.Reply, Error>).self) { group in
            var next = 0
            func record(_ finished: (Int, Result<ClaudeChapterClient.Reply, Error>)) throws {
                let (index, result) = finished
                done += 1
                switch result {
                case let .success(reply):
                    outcome.chapterUsage += reply.usage
                    onExchange?("organize \(index + 1)", messages[index], reply.text)
                    if let proposals = try? ChapterPlan.parse(reply.text, firstDay: windows[index].firstDay, lastDay: windows[index].lastDay) {
                        answers[index] = proposals
                    } else {
                        outcome.failedWindows += 1
                        outcome.failedIndices.insert(index)
                    }
                case let .failure(error):
                    if case NoteOrganizerError.http(let status, _) = error, status == 401 || status == 403 {
                        throw error
                    }
                    outcome.failedWindows += 1
                    outcome.failedIndices.insert(index)
                    onExchange?("organize \(index + 1) failed", messages[index], error.localizedDescription)
                }
                onProgress(Progress(phase: .organizing, done: done, total: windows.count))
            }
            // At most a few at a time, so a large library is not throttled.
            while next < windows.count {
                if next >= parallelRequests, let finished = try await group.next() {
                    try record(finished)
                }
                let index = next
                let message = messages[index]
                next += 1
                group.addTask {
                    do {
                        let reply = try await client.send(
                            system: instructions,
                            content: [ClaudeChapterClient.text(message)],
                            schema: schema,
                            maxTokens: 16_000,
                            effort: "medium",
                            thinking: true
                        )
                        return (index, .success(reply))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            while let finished = try await group.next() {
                try record(finished)
            }
        }
        return answers
    }

    // MARK: - Evidence

    /// Named people by photo id, from faces in People.
    private func faceNames() throws -> [String: [String]] {
        var descriptor = FetchDescriptor<FaceObservation>(predicate: #Predicate { $0.personID != nil })
        descriptor.propertiesToFetch = [\.mediaID, \.personID]
        let faces = try context.fetch(descriptor)
        let people = try context.fetch(FetchDescriptor<Person>())
        let names = Dictionary(people.compactMap { person -> (String, String)? in
            guard !person.hidden, let name = person.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            return (person.id, name)
        }, uniquingKeysWith: { first, _ in first })
        var result: [String: [String]] = [:]
        for face in faces {
            guard let personID = face.personID, let name = names[personID] else { continue }
            if result[face.mediaID]?.contains(name) != true { result[face.mediaID, default: []].append(name) }
        }
        return result
    }

    private func evidence(
        _ entries: [Entry],
        library: [Entry],
        faces: [String: [String]],
        state: ChapterAIApplier.State,
        applier: ChapterAIApplier
    ) -> [DayEvidence] {
        let ids = Set(entries.map(\.item.id))
        // Away from the usual places, and the rules' own trips, as hints.
        let stops = entries.map { PhotoStop(id: $0.item.id, date: $0.date, coordinate: coordinate(of: $0.item)) }
        let around = library.filter { !ids.contains($0.item.id) }.compactMap { entry -> PhotoStop? in
            coordinate(of: entry.item).map { PhotoStop(id: entry.item.id, date: entry.date, coordinate: $0) }
        }
        let segments = TripSegmenter().segment(stops, context: around)
        var ruleTrip: [String: Int] = [:]
        for (index, trip) in segments.trips.enumerated() {
            for id in trip { ruleTrip[id] = index + 1 }
        }
        let daily = entries.filter { ruleTrip[$0.item.id] == nil }
        let bigDays = Set(BigDayFinder().bigDays(daily.map { BigDayFinder.Photo(dayKey: $0.dayKey, date: $0.date) }).flatMap { $0 })

        let dayNotes = Dictionary(grouping: (try? dayMemories()) ?? [], by: \.scopeKey)
        let fixed = fixedChapters(state, applier: applier)

        return Dictionary(grouping: entries, by: \.dayKey).map { key, day in
            let photos = day.filter { $0.item.kind != .video }.count
            let videos = day.count - photos
            let awayCount = day.filter { ruleTrip[$0.item.id] != nil }.count
            let tripVotes = Dictionary(day.compactMap { ruleTrip[$0.item.id] }.map { ($0, 1) }, uniquingKeysWith: +)
            var places: [String] = []
            var people: [String] = []
            var notes: [String] = dayNotes[key]?.filter { $0.authorAccountID == MomentsAccount.localID }.map(\.text) ?? []
            var captionTexts: [String] = []
            var documents = 0
            for entry in day {
                for name in placeNames(of: entry.item) where !places.contains(name) { places.append(name) }
                for name in faces[entry.item.id] ?? [] where !people.contains(name) { people.append(name) }
                // A partner's words stay off the network, like their photos.
                notes += entry.item.memories.filter { ($0.authorAccountID ?? MomentsAccount.localID) == MomentsAccount.localID }.map(\.text)
                if entry.item.isScreenshot {
                    documents += 1
                } else if let caption = captions.caption(for: entry.item.id) {
                    if caption.isDocument { documents += 1 } else { captionTexts.append(caption.text) }
                }
            }
            return DayEvidence(
                dayKey: key,
                photos: photos,
                videos: videos,
                moments: BigDayFinder.moments(in: day.map(\.date)),
                isAway: awayCount * 2 > day.count,
                places: Array(places.prefix(6)),
                people: people,
                notes: notes.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                captions: captionTexts,
                documents: documents,
                ruleTrip: tripVotes.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key,
                isBigDay: bigDays.contains(key),
                fixedChapter: fixed.first { $0.range.contains(key) }?.name
            )
        }.sorted { $0.dayKey < $1.dayKey }
    }

    private func dayMemories() throws -> [CollectionMemory] {
        let scope = NoteMemoryScope.day.rawValue
        return try context.fetch(FetchDescriptor<CollectionMemory>(predicate: #Predicate { $0.scopeRaw == scope }))
    }

    private func fixedChapters(_ state: ChapterAIApplier.State, applier: ChapterAIApplier) -> [(name: String, range: ClosedRange<String>)] {
        var result: [(name: String, range: ClosedRange<String>)] = []
        for trip in state.keptTrips {
            guard let start = trip.startDate, let end = trip.endDate, start <= end else { continue }
            result.append((trip.effectiveName, TripEdits.dayKey(start, calendar: calendar)...TripEdits.dayKey(end, calendar: calendar)))
        }
        for group in state.keptGroups {
            guard let range = applier.dayRange(of: group) else { continue }
            result.append((group.name, range))
        }
        return result
    }

    /// The city first, then the spot or area, as named in Moments.
    private func placeNames(of item: MediaItem) -> [String] {
        if let override = item.placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return [override]
        }
        guard let place = item.place else { return [] }
        var names: [String] = []
        var current: Place? = place
        var depth = 0
        while let candidate = current, depth < 4 {
            if let name = PlaceDisplayName.ownName(of: candidate), !names.contains(name) { names.insert(name, at: 0) }
            current = candidate.parent
            depth += 1
        }
        return names
    }

    private func coordinate(of item: MediaItem) -> GeoPoint? {
        guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }
}

import Foundation
import MomentsCore
import Observation
import SwiftData
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Kinds on the page

extension ChapterType {
    /// The chapter kind a judged trip shows.
    init(kind: ChapterKind) {
        switch kind {
        case .trip, .daily: self = .trip
        case .businessTrip: self = .businessTrip
        case .homeVisit: self = .homeVisit
        case let .custom(label): self = .custom(label)
        }
    }
}

extension ChapterKind {
    /// What the person reads for the kind.
    var label: String {
        self == .daily ? String(localized: "Daily life") : ChapterType(kind: self).label
    }
}

// MARK: - Storage

/// The chapter judge's book (`ChapterJudgeBook`): its settings, what it
/// decided for each trip and what it learned from the person. Kept with the
/// library's decisions, so it travels with backups and never leaves the Mac.
enum ChapterJudgeStore {
    static let key = "moments.chapters.judge"

    /// The decoded book, kept so cards can read it while they draw.
    private static let cache = Cache()

    /// Holds the book with the text it was read from, so a book written
    /// elsewhere (a restored backup, another window) is read again.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        private var book: ChapterJudgeBook?

        func read(_ text: String?) -> ChapterJudgeBook {
            lock.lock()
            defer { lock.unlock() }
            if let book, stored == text { return book }
            let loaded = ChapterJudgeBook.decode(text)
            stored = text
            book = loaded
            return loaded
        }

        func write(_ value: ChapterJudgeBook, text: String) {
            lock.lock()
            book = value
            stored = text
            lock.unlock()
        }
    }

    static func book(defaults: any DecisionStore = TripAssignmentLocks.store) -> ChapterJudgeBook {
        guard defaults === TripAssignmentLocks.store else { return ChapterJudgeBook.decode(defaults.string(forKey: key)) }
        return cache.read(defaults.string(forKey: key))
    }

    static func save(_ book: ChapterJudgeBook, defaults: any DecisionStore = TripAssignmentLocks.store) {
        let text = book.encoded()
        if defaults === TripAssignmentLocks.store { cache.write(book, text: text) }
        defaults.set(text, forKey: key)
    }

    @discardableResult
    static func change(defaults: any DecisionStore = TripAssignmentLocks.store, _ edit: (inout ChapterJudgeBook) -> Void) -> ChapterJudgeBook {
        var book = book(defaults: defaults)
        edit(&book)
        save(book, defaults: defaults)
        return book
    }

    /// The kind a trip shows, or nil while it is a question or not judged.
    static func shownType(for tripID: String) -> ChapterType? {
        book().shownKind(for: tripID).map(ChapterType.init(kind:))
    }
}

// MARK: - Evidence

@MainActor
enum ChapterEvidenceBuilder {
    /// Where the person lives, works and comes from: the places they named,
    /// or, before they named any, the places the photos call home.
    static func bases(places: KnownPlaceBook, found: [FoundPlace]) -> [EvidenceBase] {
        var bases = places.places.compactMap { place -> EvidenceBase? in
            switch place.role {
            case .home, .work, .homeTown: EvidenceBase(role: place.role, name: place.name, centre: place.centre)
            case .formerWork, .notTrip: nil
            }
        }
        if !bases.contains(where: { $0.role == .home || $0.role == .work }) {
            for place in found where place.candidate.isCurrent {
                let role: PlaceRole = place.candidate.suggestedRole == .homeTown ? .homeTown : .home
                bases.append(EvidenceBase(role: role, name: place.name, centre: place.candidate.centre))
            }
        }
        return bases
    }

    /// The names of the person's places, kept out of what a model is sent.
    static func privateNames(places: KnownPlaceBook, found: [FoundPlace]) -> [String] {
        places.places.map(\.name) + found.map(\.name)
    }

    /// The photos to look at for scenes: up to eight, spread over the trip.
    static func scenePhotos(of items: [MediaItem], limit: Int = 8) -> [PhotoStackAnalyzer.PendingPhoto] {
        let stills = items.filter { $0.kind != .video && !$0.isScreenshot && ($0.photosLocalIdentifier != nil || $0.originalBookmarkData != nil) }
        guard !stills.isEmpty else { return [] }
        let step = max(1, stills.count / limit)
        return stride(from: 0, to: stills.count, by: step).prefix(limit).map { index in
            let item = stills[index]
            return PhotoStackAnalyzer.PendingPhoto(id: item.id, photosLocalIdentifier: item.photosLocalIdentifier, bookmark: item.originalBookmarkData)
        }
    }

    /// What each photo shows, in the classifier's words, off the main thread.
    nonisolated static func scenes(_ photos: [PhotoStackAnalyzer.PendingPhoto]) async -> [[String]] {
        var scenes: [[String]] = []
        for photo in photos {
            guard !Task.isCancelled, let image = await PhotoStackAnalyzer.loadImage(photo) else { continue }
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
            let words = (request.results ?? [])
                .filter { $0.confidence >= 0.3 }
                .sorted { $0.confidence > $1.confidence }
                .prefix(8)
                .map(\.identifier)
            scenes.append(Array(words))
        }
        return scenes
    }

    /// The calendar the trip's hours are read in: the photos' own time zone.
    static func calendar(for items: [MediaItem]) -> Calendar {
        var calendar = Calendar.autoupdatingCurrent
        if let offset = items.lazy.compactMap(\.localTimeZoneOffsetMinutes).first,
           let zone = TimeZone(secondsFromGMT: offset * 60) {
            calendar.timeZone = zone
        }
        return calendar
    }

    /// The city the photos were taken in, if they say.
    static func placeName(of items: [MediaItem]) -> String? {
        var counts: [String: Int] = [:]
        let step = max(1, items.count / 400)
        for index in stride(from: 0, to: items.count, by: step) {
            guard let name = KnownPlaceStore.cityName(of: items[index]) else { continue }
            counts[name, default: 0] += 1
        }
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    static func stops(of items: [MediaItem]) -> [PhotoStop] {
        items.compactMap { item in
            guard let date = item.effectiveCaptureDate else { return nil }
            var point: GeoPoint?
            if let latitude = item.latitude, let longitude = item.longitude, latitude != 0 || longitude != 0 {
                point = GeoPoint(latitude: latitude, longitude: longitude)
            }
            return PhotoStop(id: item.id, date: date, coordinate: point)
        }
    }
}

// MARK: - Model

/// Which model judges, as Settings → AI chose it. Only that one: the
/// on-device choice never falls back to a cloud model.
enum ChapterJudgeEngine: Equatable {
    case onDevice
    case cloud
    /// No model can be used; the rules judge alone.
    case rules

    static func current(settings: AISettings = .load()) -> ChapterJudgeEngine {
        guard settings.enabled else { return .rules }
        switch settings.engine {
        case .onDevice:
            return AppleOnDeviceOrganizer.unavailableReason() == nil ? .onDevice : .rules
        case .cloud:
            return ChapterJudgeModel.cloudCall(settings: settings) == nil ? .rules : .cloud
        }
    }
}

enum ChapterJudgeModel {
    enum Failure: Error { case unavailable, badResponse }

    /// The language the model writes its reason in: the app's own.
    static var language: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        if code.hasPrefix("zh") { return "Simplified Chinese" }
        if code.hasPrefix("de") { return "German" }
        return "English"
    }

    struct CloudCall {
        var isAnthropic: Bool
        var apiKey: String
        var model: String
        var url: URL
    }

    static func cloudCall(settings: AISettings, apiKey: (CloudProvider) -> String? = AIKeychain.key(for:)) -> CloudCall? {
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.provider == .claude {
            guard let key = apiKey(.claude), !key.isEmpty else { return nil }
            return CloudCall(isAnthropic: true, apiKey: key, model: model.isEmpty ? CloudProvider.claude.defaultModel : model, url: ClaudeOrganizer.endpoint)
        }
        guard let key = apiKey(.openAICompatible), !key.isEmpty else { return nil }
        if NoteOrganizerFactory.isAnthropic(base) {
            return CloudCall(isAnthropic: true, apiKey: key, model: model.isEmpty ? CloudProvider.claude.defaultModel : model, url: ClaudeOrganizer.endpoint)
        }
        guard !model.isEmpty, let url = OpenAICompatibleOrganizer.endpoint(from: base) else { return nil }
        return CloudCall(isAnthropic: false, apiKey: key, model: model, url: url)
    }

    /// The model's answer, as text, for the prompt.
    static func answer(_ prompt: JudgePrompt, engine: ChapterJudgeEngine, settings: AISettings = .load()) async throws -> String {
        switch engine {
        case .rules:
            throw Failure.unavailable
        case .onDevice:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let session = LanguageModelSession(instructions: prompt.system)
                return try await session.respond(to: prompt.user).content
            }
            #endif
            throw Failure.unavailable
        case .cloud:
            guard let call = cloudCall(settings: settings) else { throw Failure.unavailable }
            return try await cloud(prompt, call: call)
        }
    }

    private static func cloud(_ prompt: JudgePrompt, call: CloudCall) async throws -> String {
        var request = URLRequest(url: call.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        let body: [String: Any]
        if call.isAnthropic {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(call.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            var outputConfig: [String: Any] = [:]
            if let schema = (try? JSONSerialization.jsonObject(with: Data(prompt.responseSchemaJSON.utf8))) as? [String: Any] {
                outputConfig["format"] = ["type": "json_schema", "schema": schema]
            }
            var anthropic: [String: Any] = [
                "model": call.model,
                "max_tokens": 1_000,
                "system": prompt.system,
                "messages": [["role": "user", "content": prompt.user]],
            ]
            // Only the models we list get the newer options.
            if let known = ClaudeModel(rawValue: call.model) {
                outputConfig["effort"] = "low"
                if known.supportsServerFallback {
                    anthropic["fallbacks"] = "default"
                    request.setValue(ClaudeOrganizer.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
                }
            }
            anthropic["output_config"] = outputConfig
            body = anthropic
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(call.apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": call.model,
                "messages": [
                    ["role": "system", "content": prompt.system],
                    ["role": "user", "content": prompt.user],
                ],
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let object = try await CloudHTTP.send(request, session: .shared)
        if call.isAnthropic {
            let blocks = object["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw Failure.badResponse }
            return text
        }
        let choices = object["choices"] as? [[String: Any]] ?? []
        guard let text = (choices.first?["message"] as? [String: Any])?["content"] as? String else { throw Failure.badResponse }
        return text
    }
}

// MARK: - Running

/// Judges the trips that need it, one at a time, and keeps the page told.
@MainActor
@Observable
final class ChapterJudgeRunner {
    /// Trips being judged in this pass, and how many are done.
    private(set) var total = 0
    private(set) var done = 0
    /// Which pass the counts belong to, so a pass that was cancelled and
    /// ends late leaves the newer pass's counts alone.
    private var pass = 0

    var isRunning: Bool { total > 0 && done < total }

    /// What the judge's answers rest on besides the photos: the person's
    /// places and the model. When these change, its answers are redone.
    static func contextKey(bases: [EvidenceBase], engine: ChapterJudgeEngine) -> String {
        let places = bases
            .map { "\($0.role.rawValue):\(Int(($0.centre.latitude * 100).rounded())),\(Int(($0.centre.longitude * 100).rounded()))" }
            .sorted()
            .joined(separator: ";")
        return "\(engine)|\(places)"
    }

    /// Judges every trip that needs it. What to remove or ask about is the
    /// page's to decide afterwards, from the book.
    func run(trips: [Trip], places: KnownPlaceBook, found: [FoundPlace]) async {
        var book = ChapterJudgeStore.book()
        guard book.enabled, !trips.isEmpty else { return }
        let bases = ChapterEvidenceBuilder.bases(places: places, found: found)
        let names = ChapterEvidenceBuilder.privateNames(places: places, found: found)
        let engine = ChapterJudgeEngine.current()
        let context = Self.contextKey(bases: bases, engine: engine)

        struct Pending {
            let trip: Trip
            let items: [MediaItem]
            let stops: [PhotoStop]
            let calendar: Calendar
            let signature: String
        }
        var work: [Pending] = []
        for trip in trips where !trip.items.isEmpty {
            let items = trip.orderedItems
            let stops = ChapterEvidenceBuilder.stops(of: items)
            let calendar = ChapterEvidenceBuilder.calendar(for: items)
            guard let quick = SegmentEvidence.make(photos: stops, bases: bases, calendar: calendar) else { continue }
            let signature = quick.signature + "|" + context
            guard book.needsJudging(trip.id, signature: signature) else { continue }
            work.append(Pending(trip: trip, items: items, stops: stops, calendar: calendar, signature: signature))
        }
        book.prune(keeping: Set(trips.map(\.id)))
        ChapterJudgeStore.save(book)
        guard !work.isEmpty else { return }
        // Newest first: what was just imported is judged first.
        work.sort { ($0.trip.startDate ?? .distantPast) > ($1.trip.startDate ?? .distantPast) }

        pass &+= 1
        let current = pass
        total = work.count
        done = 0
        defer {
            if pass == current { total = 0; done = 0 }
        }
        func step() { if pass == current { done += 1 } }

        for entry in work {
            guard !Task.isCancelled else { break }
            let photos = ChapterEvidenceBuilder.scenePhotos(of: entry.items)
            let scenes = await Task.detached(priority: .utility) { await ChapterEvidenceBuilder.scenes(photos) }.value
            guard !Task.isCancelled else { break }
            // The trip may have gone while its photos were looked at.
            guard !entry.trip.isDeleted, entry.trip.modelContext != nil,
                  let evidence = SegmentEvidence.make(
                      photos: entry.stops,
                      bases: bases,
                      scenes: scenes,
                      calendar: entry.calendar,
                      placeName: ChapterEvidenceBuilder.placeName(of: entry.items),
                      title: entry.trip.overrideName
                  ) else { step(); continue }
            book = ChapterJudgeStore.book()
            var verdict = RuleJudge.judge(evidence, book: book)
            if engine != .rules {
                let prompt = JudgePrompt.make(evidence: evidence, book: book, language: ChapterJudgeModel.language, calendar: entry.calendar, privateNames: names)
                if let text = try? await ChapterJudgeModel.answer(prompt, engine: engine), let model = prompt.parse(text) {
                    verdict = RuleJudge.combine(rules: verdict, model: model, evidence: evidence, book: book)
                }
                guard !Task.isCancelled else { break }
                guard !entry.trip.isDeleted, entry.trip.modelContext != nil else { step(); continue }
            }
            // The person may have answered meanwhile; their answer stays.
            book = ChapterJudgeStore.book()
            guard book.enabled, book.needsJudging(entry.trip.id, signature: entry.signature) else { step(); continue }
            book.record(verdict, for: entry.trip.id, signature: entry.signature, now: .now)
            ChapterJudgeStore.save(book)
            step()
        }
    }
}

// MARK: - Evidence for a decision

@MainActor
enum ChapterJudgeEvidence {
    /// The facts about a trip, for remembering what the person decided.
    static func evidence(of trip: Trip, places: KnownPlaceBook, found: [FoundPlace]) -> SegmentEvidence? {
        let items = trip.orderedItems
        return SegmentEvidence.make(
            photos: ChapterEvidenceBuilder.stops(of: items),
            bases: ChapterEvidenceBuilder.bases(places: places, found: found),
            calendar: ChapterEvidenceBuilder.calendar(for: items),
            placeName: ChapterEvidenceBuilder.placeName(of: items),
            title: trip.overrideName
        )
    }
}

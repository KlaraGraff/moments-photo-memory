import Foundation
import Security
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns a note into structured fields. Implementations never see the photo,
/// its coordinates or anyone else's memories: only ``NoteOrganizerContext``.
public protocol NoteOrganizing: Sendable {
    var label: String { get }
    func organize(_ context: NoteOrganizerContext) async throws -> NoteOrganizerResult
}

// MARK: - Settings

public enum AIEngine: String, CaseIterable, Sendable {
    case onDevice
    case cloud
}

public enum CloudProvider: String, CaseIterable, Sendable {
    case claude
    case openAICompatible

    public var defaultModel: String {
        switch self {
        case .claude: return "claude-opus-5-5"
        case .openAICompatible: return ""
        }
    }
}

public enum OnDeviceFallback: String, CaseIterable, Sendable {
    /// Keep the words and organize them later.
    case keepForLater
    case useCloud
}

/// The AI model choice, kept in UserDefaults. The API key lives in the Keychain.
public struct AISettings: Equatable, Sendable {
    public static let engineKey = "moments.ai.engine"
    public static let providerKey = "moments.ai.cloudProvider"
    public static let modelKey = "moments.ai.cloudModel"
    public static let baseURLKey = "moments.ai.cloudBaseURL"
    public static let fallbackKey = "moments.ai.fallback"

    public var engine: AIEngine = .onDevice
    public var provider: CloudProvider = .claude
    public var model: String = CloudProvider.claude.defaultModel
    public var baseURL: String = ""
    public var fallback: OnDeviceFallback = .keepForLater

    public init() {}

    public static func load(from defaults: UserDefaults = .standard) -> AISettings {
        var settings = AISettings()
        settings.engine = defaults.string(forKey: engineKey).flatMap(AIEngine.init(rawValue:)) ?? .onDevice
        settings.provider = defaults.string(forKey: providerKey).flatMap(CloudProvider.init(rawValue:)) ?? .claude
        settings.model = defaults.string(forKey: modelKey) ?? settings.provider.defaultModel
        settings.baseURL = defaults.string(forKey: baseURLKey) ?? ""
        settings.fallback = defaults.string(forKey: fallbackKey).flatMap(OnDeviceFallback.init(rawValue:)) ?? .keepForLater
        return settings
    }
}

/// Stores cloud API keys as generic passwords in the login keychain.
public enum AIKeychain {
    static let service = "Moments AI"

    public static func key(for provider: CloudProvider) -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    @discardableResult
    public static func setKey(_ value: String, for provider: CloudProvider) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(baseQuery(provider) as CFDictionary)
        guard !trimmed.isEmpty else { return true }
        var item = baseQuery(provider)
        item[kSecValueData as String] = Data(trimmed.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(_ provider: CloudProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
        ]
    }
}

// MARK: - Choosing a model

public enum NoteOrganizerFactory {
    /// The organizers to try, in order. An `.unavailable` error from one moves
    /// on to the next; any other error stops.
    public static func organizers(
        settings: AISettings = .load(),
        apiKey: (CloudProvider) -> String? = AIKeychain.key(for:)
    ) -> [any NoteOrganizing] {
        let cloud = cloudOrganizer(settings: settings, apiKey: apiKey)
        switch settings.engine {
        case .cloud:
            return [cloud]
        case .onDevice:
            var list: [any NoteOrganizing] = [AppleOnDeviceOrganizer()]
            if settings.fallback == .useCloud { list.append(cloud) }
            return list
        }
    }

    static func cloudOrganizer(settings: AISettings, apiKey: (CloudProvider) -> String?) -> any NoteOrganizing {
        let key = apiKey(settings.provider)
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch settings.provider {
        case .claude:
            return ClaudeOrganizer(apiKey: key, model: model.isEmpty ? CloudProvider.claude.defaultModel : model)
        case .openAICompatible:
            return OpenAICompatibleOrganizer(apiKey: key, model: model, baseURL: settings.baseURL)
        }
    }
}

// MARK: - Apple on-device model

public struct AppleOnDeviceOrganizer: NoteOrganizing {
    public init() {}

    public var label: String { String(localized: "On-device model") }

    /// nil when the model can run now, otherwise why not.
    public static func unavailableReason() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return String(localized: "Turn on Apple Intelligence in System Settings to use the on-device model.")
            case .unavailable(.modelNotReady):
                return String(localized: "The on-device model is still downloading. Try again later.")
            case .unavailable:
                return String(localized: "This Mac can't run Apple's on-device model.")
            }
        }
        #endif
        return String(localized: "The on-device model needs macOS 26 or later with Apple Intelligence.")
    }

    public func organize(_ context: NoteOrganizerContext) async throws -> NoteOrganizerResult {
        if let reason = Self.unavailableReason() { throw NoteOrganizerError.unavailable(reason) }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: NotePrompt.instructions)
            let response = try await session.respond(to: NotePrompt.message(for: context), generating: GeneratedNote.self)
            let note = response.content
            func clean(_ value: String) -> String? {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return NoteOrganizerResult(
                placeName: clean(note.placeName),
                placeDescription: clean(note.placeDescription),
                memory: clean(note.memory),
                memoryScope: clean(note.memoryScope)
            )
        }
        #endif
        throw NoteOrganizerError.unavailable(String(localized: "The on-device model needs macOS 26 or later with Apple Intelligence."))
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct GeneratedNote {
    @Guide(description: "Correct name of the place where the photo was taken, only if the note corrects or names it; otherwise empty")
    var placeName: String
    @Guide(description: "What the place is like or tips about it, one or two neutral sentences; otherwise empty")
    var placeDescription: String
    @Guide(description: "The person's own experience in their voice and mostly their own words; otherwise empty")
    var memory: String
    @Guide(description: "photo, day or trip: what the memory is about")
    var memoryScope: String
}
#endif

// MARK: - Cloud models

struct ClaudeOrganizer: NoteOrganizing {
    let apiKey: String?
    let model: String
    var session: URLSession = .shared

    var label: String { "Claude" }

    func organize(_ context: NoteOrganizerContext) async throws -> NoteOrganizerResult {
        guard let apiKey else { throw NoteOrganizerError.missingKey }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4000,
            "system": NotePrompt.instructions,
            "messages": [["role": "user", "content": NotePrompt.message(for: context)]],
            "output_config": ["format": ["type": "json_schema", "schema": NotePrompt.jsonSchema]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let object = try await CloudHTTP.send(request, session: session)
        if object["stop_reason"] as? String == "refusal" { throw NoteOrganizerError.refused }
        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        return try NoteOrganizerParser.parse(text)
    }
}

struct OpenAICompatibleOrganizer: NoteOrganizing {
    let apiKey: String?
    let model: String
    let baseURL: String
    var session: URLSession = .shared

    var label: String { model.isEmpty ? String(localized: "Cloud model") : model }

    static func endpoint(from baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/chat/completions") { return URL(string: base) }
        return URL(string: base + "/chat/completions")
    }

    func organize(_ context: NoteOrganizerContext) async throws -> NoteOrganizerResult {
        guard let apiKey else { throw NoteOrganizerError.missingKey }
        guard let url = Self.endpoint(from: baseURL), !model.isEmpty else {
            throw NoteOrganizerError.unavailable(String(localized: "Fill in the endpoint and model in Settings › AI Model."))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": NotePrompt.instructions],
                ["role": "user", "content": NotePrompt.message(for: context)]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let object = try await CloudHTTP.send(request, session: session)
        let choices = object["choices"] as? [[String: Any]] ?? []
        let message = choices.first?["message"] as? [String: Any]
        guard let text = message?["content"] as? String else { throw NoteOrganizerError.badResponse }
        return try NoteOrganizerParser.parse(text)
    }
}

enum CloudHTTP {
    static func send(_ request: URLRequest, session: URLSession) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let error = object["error"] as? [String: Any]
            throw NoteOrganizerError.http(status, error?["message"] as? String ?? "")
        }
        return object
    }
}

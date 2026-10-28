import Foundation
import MomentsCore

enum ChapterAIError: LocalizedError, Equatable {
    case cutOff
    case noPhotos

    var errorDescription: String? {
        switch self {
        case .cutOff: return String(localized: "The model's answer was cut off.")
        case .noPhotos: return String(localized: "There are no dated photos to organize.")
        }
    }
}

/// One Messages API request with a JSON answer, retried when Anthropic is
/// busy. Uses the same key, version and error wording as notes.
struct ClaudeChapterClient: Sendable {
    let apiKey: String
    let model: String
    var session: URLSession = .shared
    /// Waits before each retry of a busy or failed request.
    var retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(40)]

    struct Reply {
        let text: String
        let usage: ModelUsage
    }

    static func text(_ value: String) -> [String: Any] {
        ["type": "text", "text": value]
    }

    static func image(jpeg: Data) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
    }

    /// `thinking` off for plain describing work: cheaper, and quick. Only
    /// the models we list get the newer options.
    func requestBody(system: String, content: [[String: Any]], schema: [String: Any], maxTokens: Int, effort: String, thinking: Bool) -> [String: Any] {
        var outputConfig: [String: Any] = ["format": ["type": "json_schema", "schema": schema]]
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": content]]
        ]
        if ClaudeModel(rawValue: model) != nil {
            outputConfig["effort"] = effort
            if !thinking { body["thinking"] = ["type": "disabled"] }
        }
        body["output_config"] = outputConfig
        return body
    }

    func send(system: String, content: [[String: Any]], schema: [String: Any], maxTokens: Int, effort: String, thinking: Bool) async throws -> Reply {
        var request = URLRequest(url: ClaudeOrganizer.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(
            system: system, content: content, schema: schema, maxTokens: maxTokens, effort: effort, thinking: thinking
        ))

        var attempt = 0
        while true {
            do {
                let object = try await ClaudeOrganizer.send(request, session: session)
                return try Self.reply(from: object, model: model)
            } catch let error as NoteOrganizerError {
                guard attempt < retryDelays.count, Self.isWorthRetrying(error) else { throw error }
            }
            try await Task.sleep(for: retryDelays[attempt])
            attempt += 1
        }
    }

    /// Busy, overloaded or briefly unreachable; a bad key or request is not.
    static func isWorthRetrying(_ error: NoteOrganizerError) -> Bool {
        switch error {
        case .http(let status, _): return status == 408 || status == 429 || status >= 500
        case .unavailable: return true
        default: return false
        }
    }

    static func reply(from object: [String: Any], model: String) throws -> Reply {
        switch object["stop_reason"] as? String {
        case "refusal": throw NoteOrganizerError.refused
        case "max_tokens": throw ChapterAIError.cutOff
        default: break
        }
        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        let usage = object["usage"] as? [String: Any] ?? [:]
        func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        return Reply(text: text, usage: ModelUsage(
            model: model,
            input: count("input_tokens"),
            output: count("output_tokens"),
            cacheRead: count("cache_read_input_tokens"),
            cacheWrite: count("cache_creation_input_tokens")
        ))
    }
}

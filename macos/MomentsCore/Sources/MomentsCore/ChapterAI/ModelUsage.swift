import Foundation

/// Tokens one or more requests used, and what they cost.
public struct ModelUsage: Codable, Equatable, Sendable {
    public var requests = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheWriteTokens = 0
    /// In US dollars, summed per request (Haiku's price depends on each
    /// request's prompt length); nil once a request's model has no known price.
    public var dollars: Double? = 0

    public init() {}

    /// One request, as the Messages API reports it in `usage`.
    public init(model: String, input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0) {
        requests = 1
        inputTokens = input
        outputTokens = output
        cacheReadTokens = cacheRead
        cacheWriteTokens = cacheWrite
        dollars = ModelPricing.dollars(model: model, input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
    }

    public static func + (lhs: ModelUsage, rhs: ModelUsage) -> ModelUsage {
        var sum = lhs
        sum.requests += rhs.requests
        sum.inputTokens += rhs.inputTokens
        sum.outputTokens += rhs.outputTokens
        sum.cacheReadTokens += rhs.cacheReadTokens
        sum.cacheWriteTokens += rhs.cacheWriteTokens
        if let left = lhs.dollars, let right = rhs.dollars { sum.dollars = left + right } else { sum.dollars = nil }
        return sum
    }

    public static func += (lhs: inout ModelUsage, rhs: ModelUsage) { lhs = lhs + rhs }
}

/// Standard prices per million tokens (platform.claude.com pricing,
/// checked 2026-10-28): base input, 5-minute cache write, cache hit, output.
public enum ModelPricing {
    struct Rates {
        let input: Double
        let cacheWrite: Double
        let cacheRead: Double
        let output: Double
    }

    /// Haiku 5.5 prompts over this many tokens pay the higher prices.
    public static let haikuLongPrompt = 100_000

    static func rates(model: String, promptTokens: Int) -> Rates? {
        switch model {
        case "claude-haiku-5-5":
            return promptTokens > haikuLongPrompt
                ? Rates(input: 0.50, cacheWrite: 0.625, cacheRead: 0.05, output: 2.50)
                : Rates(input: 0.10, cacheWrite: 0.125, cacheRead: 0.01, output: 0.50)
        case "claude-sonnet-5-5":
            return Rates(input: 2, cacheWrite: 2.50, cacheRead: 0.10, output: 10)
        case "claude-opus-5-5":
            return Rates(input: 4, cacheWrite: 5, cacheRead: 0.20, output: 20)
        default:
            return nil
        }
    }

    public static func dollars(model: String, input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0) -> Double? {
        guard let rates = rates(model: model, promptTokens: input + cacheRead + cacheWrite) else { return nil }
        let millions = Double(input) * rates.input + Double(cacheWrite) * rates.cacheWrite
            + Double(cacheRead) * rates.cacheRead + Double(output) * rates.output
        return millions / 1_000_000
    }

    /// Visual tokens for an image: one per 28 × 28 pixel patch.
    public static func imageTokens(width: Int, height: Int) -> Int {
        ((width + 27) / 28) * ((height + 27) / 28)
    }
}

import Foundation

struct ModelChoice: Identifiable, Equatable {
    let providerId: String
    let model: String

    var id: String { "\(providerId)|\(model)" }
}

struct ModelInfo: Identifiable, Equatable {
    let id: String
    /// USD per token (OpenRouter provides them; local servers usually don't)
    let promptPrice: Double?
    let completionPrice: Double?

    var priceLabel: String? {
        guard let promptPrice, let completionPrice else { return nil }
        if promptPrice == 0 && completionPrice == 0 { return "free" }
        return "$\(Self.perMillion(promptPrice)) / $\(Self.perMillion(completionPrice))"
    }

    private static func perMillion(_ perToken: Double) -> String {
        let value = perToken * 1_000_000
        if value == 0 { return "0" }
        if value < 1 { return String(format: "%.3f", value) }
        return String(format: "%.2f", value)
    }
}

/// Fetches available models from an OpenAI-compatible `/models` endpoint
/// (works for openrouter.ai, which includes pricing, and for llama-swap).
enum ModelCatalog {
    static func fetch(baseUrl: String, apiKey: String?) async throws -> [ModelInfo] {
        let base = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        guard let url = URL(string: "\(base)/models") else {
            throw ChatClientError.badUrl
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            throw ChatClientError.http(http.statusCode, String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]]
        else {
            throw URLError(.cannotParseResponse)
        }
        return list.compactMap { item -> ModelInfo? in
            guard let id = item["id"] as? String else { return nil }
            let pricing = item["pricing"] as? [String: Any]
            return ModelInfo(
                id: id,
                promptPrice: Self.price(pricing?["prompt"]),
                completionPrice: Self.price(pricing?["completion"])
            )
        }
        .sorted { $0.id < $1.id }
    }

    /// Models reachable through the local OpenCode install, as `provider/model`.
    ///
    /// The list comes from the running server, so it reflects the providers the
    /// user is actually authenticated for. Prices are list prices and mostly
    /// informational here: the point of a harness is that the subscription
    /// already covers the call.
    static func fetchOpenCode(install: HarnessInstall) async throws -> [ModelInfo] {
        let endpoint = try await OpenCodeServer.shared.endpoint(install: install)
        var request = endpoint.request("config/providers")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            throw ChatClientError.http(http.statusCode, String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = json["providers"] as? [[String: Any]]
        else { throw URLError(.cannotParseResponse) }

        return providers.flatMap { provider -> [ModelInfo] in
            guard let providerId = provider["id"] as? String,
                  let models = provider["models"] as? [String: Any]
            else { return [] }
            return models.compactMap { modelId, value -> ModelInfo? in
                let cost = (value as? [String: Any])?["cost"] as? [String: Any]
                // OpenCode quotes USD per million tokens; ModelInfo stores per
                // token and formats back to millions.
                return ModelInfo(
                    id: "\(providerId)/\(modelId)",
                    promptPrice: perToken(cost?["input"]),
                    completionPrice: perToken(cost?["output"])
                )
            }
        }
        .sorted { $0.id < $1.id }
    }

    /// Models offered for Claude Code.
    ///
    /// The CLI has no model-list endpoint, so this list is static. The aliases
    /// come first because the CLI resolves them to whatever the current model
    /// is, which means they never go stale; the full ids are today's, and any
    /// other one can be typed into the search box and added.
    static let claudeCodeModels: [ModelInfo] = [
        "sonnet", "opus", "haiku", "fable",
        "claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5", "claude-fable-5",
    ].map { ModelInfo(id: $0, promptPrice: nil, completionPrice: nil) }

    private static func perToken(_ value: Any?) -> Double? {
        guard let perMillion = price(value) else { return nil }
        return perMillion / 1_000_000
    }

    private static func price(_ value: Any?) -> Double? {
        if let string = value as? String { return Double(string) }
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        return nil
    }
}

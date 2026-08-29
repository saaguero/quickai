import Foundation

enum ChatClientError: LocalizedError {
    case missingKey
    case badUrl
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Missing OpenRouter API key. Open Settings (⌘,) and add it."
        case .badUrl:
            return "Invalid provider base URL. Check Settings (⌘,)."
        case .http(let status, let detail):
            if status == 429 {
                return "Rate limited (429). Free-tier daily quota may be exhausted. \(detail)"
            }
            return "HTTP \(status): \(detail)"
        }
    }
}

enum ChatClient {
    /// Streams an answer from whichever transport the provider uses.
    ///
    /// `conversationId` only matters for harness providers, which keep the
    /// context in a server-side session keyed by it.
    /// - Parameter ephemeral: a throwaway call (a conversation title) that must
    ///   leave no trace in a harness's own session history.
    static func stream(
        provider: Provider,
        messages: [Message],
        conversationId: String,
        systemPrompt: String,
        ephemeral: Bool = false
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        switch provider.kind {
        case .openAI:
            return openAIStream(provider: provider, messages: messages)
        case .harness(let kind):
            guard let install = provider.install else {
                return AsyncThrowingStream {
                    $0.finish(throwing: kind == .opencode
                        ? OpenCodeServerError.notInstalled
                        : ClaudeCodeClientError.notInstalled)
                }
            }
            switch kind {
            case .opencode:
                return OpenCodeClient.stream(
                    install: install,
                    model: provider.model,
                    systemPrompt: provider.leanMode ? systemPrompt : nil,
                    disableTools: provider.leanMode,
                    conversationId: conversationId,
                    messages: messages
                )
            case .claudeCode:
                return ClaudeCodeClient.stream(
                    install: install,
                    model: provider.model,
                    systemPrompt: provider.leanMode ? systemPrompt : nil,
                    lean: provider.leanMode,
                    conversationId: conversationId,
                    messages: messages,
                    ephemeral: ephemeral
                )
            }
        }
    }

    private static func openAIStream(provider: Provider, messages: [Message]) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if provider.id == "openrouter" && provider.apiKey == nil {
                        throw ChatClientError.missingKey
                    }
                    let base = provider.baseUrl.hasSuffix("/") ? String(provider.baseUrl.dropLast()) : provider.baseUrl
                    guard let url = URL(string: "\(base)/chat/completions") else {
                        throw ChatClientError.badUrl
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 120
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let key = provider.apiKey {
                        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    }
                    request.setValue("https://github.com/saaguero/quickai", forHTTPHeaderField: "HTTP-Referer")
                    request.setValue("QuickAI (macOS)", forHTTPHeaderField: "X-Title")

                    let body: [String: Any] = [
                        "model": provider.model,
                        "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                        "stream": true,
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    if http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 4096 { break }
                        }
                        throw ChatClientError.http(http.statusCode, Self.errorDetail(from: data))
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue } // skips SSE comments/keep-alives
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        for chunk in Self.chunks(from: payload) {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One-shot, non-streaming completion (used for cheap auxiliary calls like titles).
    static func complete(provider: Provider, messages: [Message], maxTokens: Int) async throws -> String {
        if case .harness = provider.kind {
            // Harnesses have no one-shot endpoint, so collect a throwaway
            // stream. Its own session id keeps it out of the user's context.
            var text = ""
            for try await chunk in stream(
                provider: provider,
                messages: messages,
                conversationId: "title-\(UUID().uuidString)",
                systemPrompt: "Answer with the requested text only.",
                ephemeral: true
            ) {
                if case .text(let piece) = chunk { text += piece }
            }
            return text
        }
        if provider.id == "openrouter" && provider.apiKey == nil {
            throw ChatClientError.missingKey
        }
        let base = provider.baseUrl.hasSuffix("/") ? String(provider.baseUrl.dropLast()) : provider.baseUrl
        guard let url = URL(string: "\(base)/chat/completions") else {
            throw ChatClientError.badUrl
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = provider.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": provider.model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": false,
            "max_tokens": maxTokens,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ChatClientError.http((response as? HTTPURLResponse)?.statusCode ?? -1, Self.errorDetail(from: data))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw URLError(.cannotParseResponse)
        }
        return content
    }

    /// Reasoning and answer text out of one SSE payload. OpenRouter exposes
    /// thinking models' traces as a `reasoning` delta alongside `content`.
    private static func chunks(from payload: String) -> [StreamChunk] {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any]
        else { return [] }

        var chunks: [StreamChunk] = []
        if let reasoning = delta["reasoning"] as? String, !reasoning.isEmpty {
            chunks.append(.reasoning(reasoning))
        }
        if let content = delta["content"] as? String, !content.isEmpty {
            chunks.append(.text(content))
        }
        return chunks
    }

    private static func errorDetail(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}

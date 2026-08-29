import Foundation

/// One piece of a streamed answer.
///
/// Reasoning is kept separate from the answer on purpose: it is shown as live
/// progress while the model works and never becomes part of the saved message.
enum StreamChunk {
    case reasoning(String)
    case text(String)
}

enum OpenCodeClientError: LocalizedError {
    case badModel(String)
    case http(Int, String)
    case session(String)

    var errorDescription: String? {
        switch self {
        case .badModel(let model):
            return "Model \"\(model)\" is not in OpenCode's provider/model form."
        case .http(let status, let detail):
            return "OpenCode server HTTP \(status): \(detail)"
        case .session(let message):
            return message
        }
    }
}

/// Maps a QuickAI conversation to the opencode session that holds its context.
///
/// QuickAI owns the transcript and opencode owns the session, so the mapping
/// lives in memory only: after a relaunch (or a server restart) the lookup
/// misses, a fresh session is created and the prior turns are replayed into the
/// first prompt.
private actor SessionRegistry {
    static let shared = SessionRegistry()

    private var sessions: [String: String] = [:]

    func existing(for conversationId: String) -> String? { sessions[conversationId] }

    func remember(_ sessionId: String, for conversationId: String) {
        sessions[conversationId] = sessionId
    }

    func forget(_ conversationId: String) { sessions.removeValue(forKey: conversationId) }
}

/// Streams answers out of a local `opencode serve` process.
enum OpenCodeClient {
    /// - Parameters:
    ///   - model: `provider/model`, as listed by the model browser.
    ///   - systemPrompt: QuickAI's prompt in lean mode; nil leaves opencode's
    ///     own agent prompt in place ("normal" mode).
    ///   - disableTools: lean mode turns every tool off, so the panel answers
    ///     with text instead of touching the machine.
    static func stream(
        install: HarnessInstall,
        model: String,
        systemPrompt: String?,
        disableTools: Bool,
        conversationId: String,
        messages: [Message]
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var endpoint: OpenCodeServer.Endpoint?
                var sessionId: String?
                do {
                    let (providerId, modelId) = try Self.split(model)
                    let resolved = try await OpenCodeServer.shared.endpoint(install: install)
                    endpoint = resolved

                    let existing = await SessionRegistry.shared.existing(for: conversationId)
                    let session: String
                    if let existing {
                        session = existing
                    } else {
                        session = try await Self.createSession(resolved, conversationId: conversationId)
                    }
                    sessionId = session

                    // Everything the model still needs to be told. On a known
                    // session opencode already holds the history, so only the
                    // new question goes out.
                    let prompt = Self.promptText(messages: messages, replayHistory: existing == nil)

                    // The event stream must be open BEFORE the prompt is posted:
                    // deltas emitted in between are otherwise lost.
                    var eventRequest = resolved.request("event")
                    eventRequest.timeoutInterval = 3600
                    let (bytes, response) = try await URLSession.shared.bytes(for: eventRequest)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw OpenCodeClientError.http(
                            (response as? HTTPURLResponse)?.statusCode ?? -1, "could not open the event stream"
                        )
                    }

                    try await Self.postPrompt(
                        resolved,
                        sessionId: session,
                        providerId: providerId,
                        modelId: modelId,
                        systemPrompt: systemPrompt,
                        disableTools: disableTools,
                        text: prompt
                    )

                    try await Self.consume(bytes, sessionId: session, continuation: continuation)
                    continuation.finish()
                } catch {
                    // A cancelled stream (⎋ or a new question) must also stop the
                    // model on the server, otherwise it keeps burning quota.
                    if let endpoint, let sessionId, error is CancellationError {
                        Task.detached { try? await Self.abort(endpoint, sessionId: sessionId) }
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Drops the remembered session so the next turn starts clean.
    static func reset(conversationId: String) async {
        await SessionRegistry.shared.forget(conversationId)
    }

    // MARK: - Event stream

    private static func consume(
        _ bytes: URLSession.AsyncBytes,
        sessionId: String,
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) async throws {
        // `field` is "text" on reasoning deltas too, so the only reliable
        // discriminator is the part's declared type, which arrives earlier in a
        // `message.part.updated` event. Role matters as well: the user's own
        // prompt comes back as a text part and must not be echoed.
        var partType: [String: String] = [:]
        var partMessage: [String: String] = [:]
        var messageRole: [String: String] = [:]

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty,
                  let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String,
                  let properties = event["properties"] as? [String: Any]
            else { continue }

            // The endpoint is global, so other sessions share it.
            if let eventSession = properties["sessionID"] as? String, eventSession != sessionId { continue }

            switch type {
            case "message.updated":
                if let info = properties["info"] as? [String: Any],
                   let id = info["id"] as? String,
                   let role = info["role"] as? String {
                    messageRole[id] = role
                }

            case "message.part.updated":
                if let part = properties["part"] as? [String: Any], let id = part["id"] as? String {
                    partType[id] = part["type"] as? String ?? ""
                    partMessage[id] = part["messageID"] as? String ?? ""
                }

            case "message.part.delta":
                guard let partId = properties["partID"] as? String,
                      let delta = properties["delta"] as? String, !delta.isEmpty,
                      let kind = partType[partId],
                      let messageId = partMessage[partId],
                      messageRole[messageId] == "assistant"
                else { continue }
                if kind == "text" {
                    continuation.yield(.text(delta))
                } else if kind == "reasoning" {
                    continuation.yield(.reasoning(delta))
                }

            case "session.error":
                throw OpenCodeClientError.session(Self.errorMessage(properties))

            case "session.idle":
                return

            default:
                continue
            }
        }
    }

    private static func errorMessage(_ properties: [String: Any]) -> String {
        guard let error = properties["error"] as? [String: Any] else { return "OpenCode reported an error." }
        let name = error["name"] as? String
        let detail = (error["data"] as? [String: Any])?["message"] as? String
        return [name, detail].compactMap { $0 }.joined(separator: ": ")
    }

    // MARK: - Requests

    private static func createSession(_ endpoint: OpenCodeServer.Endpoint, conversationId: String) async throws -> String {
        var request = endpoint.request("session")
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenCodeClientError.http(
                (response as? HTTPURLResponse)?.statusCode ?? -1,
                String(decoding: data.prefix(200), as: UTF8.self)
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String
        else { throw OpenCodeClientError.session("OpenCode did not return a session id.") }

        await SessionRegistry.shared.remember(id, for: conversationId)
        return id
    }

    private static func postPrompt(
        _ endpoint: OpenCodeServer.Endpoint,
        sessionId: String,
        providerId: String,
        modelId: String,
        systemPrompt: String?,
        disableTools: Bool,
        text: String
    ) async throws {
        var body: [String: Any] = [
            "model": ["providerID": providerId, "modelID": modelId],
            "parts": [["type": "text", "text": text]],
        ]
        if let systemPrompt, !systemPrompt.isEmpty {
            body["system"] = systemPrompt
        }
        if disableTools {
            // Measured: this drops a turn from ~21k to ~15k tokens and keeps the
            // panel from touching the machine.
            body["tools"] = ["*": false]
        }

        var request = endpoint.request("session/\(sessionId)/prompt_async")
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenCodeClientError.http(
                (response as? HTTPURLResponse)?.statusCode ?? -1,
                String(decoding: data.prefix(300), as: UTF8.self)
            )
        }
    }

    private static func abort(_ endpoint: OpenCodeServer.Endpoint, sessionId: String) async throws {
        var request = endpoint.request("session/\(sessionId)/abort")
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        _ = try await URLSession.shared.data(for: request)
    }

    // MARK: - Helpers

    /// Splits `provider/model` at the FIRST slash: model ids often contain more.
    private static func split(_ model: String) throws -> (String, String) {
        let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw OpenCodeClientError.badModel(model)
        }
        return (parts[0], parts[1])
    }

    /// The text to send. On a fresh session the earlier turns are replayed as a
    /// preamble, because opencode holds no history for it yet.
    private static func promptText(messages: [Message], replayHistory: Bool) -> String {
        let question = messages.last(where: { $0.role == .user })?.content ?? ""
        guard replayHistory else { return question }

        let earlier = messages.dropLast().filter { $0.role == .user || $0.role == .assistant }
        guard !earlier.isEmpty else { return question }

        let transcript = earlier
            .map { "\($0.role == .user ? "User" : "Assistant"): \($0.content)" }
            .joined(separator: "\n\n")
        return "Conversation so far:\n\n\(transcript)\n\n---\n\n\(question)"
    }
}

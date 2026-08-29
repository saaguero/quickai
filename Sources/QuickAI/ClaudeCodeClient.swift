import Foundation

enum ClaudeCodeClientError: LocalizedError {
    case notInstalled
    case launchFailed(String)
    case meteredApiKey(String)
    case failed(String)
    case noInit

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Claude Code was not found. Open Settings (⌘,) to set its path. \(HarnessKind.claudeCode.installHint)"
        case .launchFailed(let detail):
            return "Could not start Claude Code: \(detail)"
        case .meteredApiKey(let source):
            return """
                Claude Code reported the API key source "\(source)", so this answer would be billed \
                per token instead of covered by your subscription. QuickAI stopped before sending it. \
                Run: claude auth login
                """
        case .failed(let detail):
            return "Claude Code: \(detail)"
        case .noInit:
            return "Claude Code did not start a session (no init event)."
        }
    }
}

/// Maps a QuickAI conversation to a Claude Code session.
///
/// QuickAI picks the session id itself (`--session-id`) on the first turn and
/// resumes it (`--resume`) afterwards, so the CLI keeps the context and only
/// the new question travels. An id becomes resumable only after a turn has
/// finished: a session that never completed has nothing on disk to resume.
private actor ClaudeSessionRegistry {
    static let shared = ClaudeSessionRegistry()

    private var sessions: [String: String] = [:]
    private var resumable: Set<String> = []

    /// The session id for a conversation, and whether it can be resumed.
    func session(for conversationId: String) -> (id: String, resumable: Bool) {
        if let existing = sessions[conversationId] {
            return (existing, resumable.contains(existing))
        }
        let fresh = UUID().uuidString.lowercased()
        sessions[conversationId] = fresh
        return (fresh, false)
    }

    func markResumable(_ sessionId: String) { resumable.insert(sessionId) }

    func forget(_ conversationId: String) {
        if let id = sessions.removeValue(forKey: conversationId) { resumable.remove(id) }
    }
}

/// Lets `onTermination` reach the child process from any thread.
private final class ChildHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func adopt(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    /// Ends the turn. Closing the pipe is what unblocks the reader, so this is
    /// also how a cancelled stream stops burning quota.
    func terminate() {
        lock.lock()
        let process = self.process
        self.process = nil
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }
}

/// Streams answers out of the local `claude` CLI, one child process per turn.
///
/// The invocation is the Agent SDK's own subprocess contract, read out of
/// `sdk.mjs`: stream-json in and out, no `-p`. Its shape is deliberate and
/// documented in AGENTS.md; the flags that look like the obvious minimal mode
/// (`--bare`, `-p`) are the ones to stay away from.
///
/// Nothing here can outlive the app for long: the child gets its prompt on
/// stdin, stdin is closed immediately, and the process exits when the turn ends.
enum ClaudeCodeClient {
    /// - Parameters:
    ///   - systemPrompt: QuickAI's prompt in lean mode; nil leaves Claude
    ///     Code's own system prompt in place ("normal" mode).
    ///   - lean: strips tools, skills, plugins, MCP servers and CLAUDE.md, so
    ///     the panel answers with text instead of touching the machine.
    ///   - ephemeral: for throwaway calls (conversation titles). Nothing is
    ///     written to the user's session history and nothing is resumable.
    static func stream(
        install: HarnessInstall,
        model: String,
        systemPrompt: String?,
        lean: Bool,
        conversationId: String,
        messages: [Message],
        ephemeral: Bool = false
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let child = ChildHandle()
            let task = Task {
                do {
                    let session = ephemeral ? nil : await ClaudeSessionRegistry.shared.session(for: conversationId)
                    let prompt = Self.promptText(messages: messages, replayHistory: !(session?.resumable ?? false))

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: install.path)
                    process.arguments = Self.arguments(
                        model: model, systemPrompt: systemPrompt, lean: lean, session: session
                    )
                    process.currentDirectoryURL = try Self.workspaceDirectory()
                    process.environment = Self.environment()

                    let input = Pipe()
                    let output = Pipe()
                    process.standardInput = input
                    process.standardOutput = output
                    // The CLI is quiet on stderr in this mode and we never read
                    // it; discarding avoids wedging the child on a full pipe.
                    process.standardError = FileHandle.nullDevice

                    do {
                        try process.run()
                    } catch {
                        throw ClaudeCodeClientError.launchFailed(error.localizedDescription)
                    }
                    child.adopt(process)

                    // One user message, then EOF: that is what makes the child
                    // answer and exit instead of waiting for another turn.
                    let payload: [String: Any] = [
                        "type": "user",
                        "message": ["role": "user", "content": prompt],
                    ]
                    let line = try JSONSerialization.data(withJSONObject: payload) + Data("\n".utf8)
                    try? input.fileHandleForWriting.write(contentsOf: line)
                    try? input.fileHandleForWriting.close()

                    try await Self.consume(
                        output.fileHandleForReading,
                        child: child,
                        sessionId: session?.id,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    child.terminate()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                child.terminate()
            }
        }
    }

    /// Drops the remembered session so the next turn starts clean.
    static func reset(conversationId: String) async {
        await ClaudeSessionRegistry.shared.forget(conversationId)
    }

    // MARK: - Event stream

    private static func consume(
        _ handle: FileHandle,
        child: ChildHandle,
        sessionId: String?,
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) async throws {
        // Nothing may be yielded before the subscription guard has run, so the
        // init event is required and checked first.
        var sawInit = false

        // A child that never reaches init is hung (a stalled update check, a
        // prompt it is waiting on). Fail loudly instead of spinning forever.
        let watchdog = Task {
            do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
            child.terminate()
        }
        defer { watchdog.cancel() }

        for try await line in handle.bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("{"), let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }

            switch type {
            case "system":
                guard event["subtype"] as? String == "init" else { continue }
                // The money guard. "none" means the CLI authenticated with the
                // user's subscription login; anything else is a metered key,
                // which is the one thing this provider exists to avoid.
                let source = event["apiKeySource"] as? String ?? "unknown"
                guard source == "none" else {
                    child.terminate()
                    throw ClaudeCodeClientError.meteredApiKey(source)
                }
                sawInit = true
                watchdog.cancel()

            case "stream_event":
                guard let inner = event["event"] as? [String: Any],
                      inner["type"] as? String == "content_block_delta",
                      let delta = inner["delta"] as? [String: Any]
                else { continue }
                switch delta["type"] as? String {
                case "text_delta":
                    if let text = delta["text"] as? String, !text.isEmpty { continuation.yield(.text(text)) }
                case "thinking_delta":
                    if let text = delta["thinking"] as? String, !text.isEmpty {
                        continuation.yield(.reasoning(text))
                    }
                default:
                    // input_json_delta (tool arguments) and signature_delta are
                    // neither answer nor reasoning.
                    continue
                }

            case "result":
                if let isError = event["is_error"] as? Bool, isError {
                    throw ClaudeCodeClientError.failed(Self.errorMessage(event))
                }
                if let sessionId { await ClaudeSessionRegistry.shared.markResumable(sessionId) }
                return

            default:
                continue
            }
        }

        guard sawInit else { throw ClaudeCodeClientError.noInit }
    }

    private static func errorMessage(_ event: [String: Any]) -> String {
        if let result = event["result"] as? String, !result.isEmpty { return result }
        return event["subtype"] as? String ?? "the turn failed"
    }

    // MARK: - Invocation

    /// The child's command line.
    ///
    /// Safe mode is the floor: `--dangerously-skip-permissions` and
    /// `--permission-mode bypassPermissions` are never passed, in either mode.
    /// Without a permission handler the CLI denies anything that needs one
    /// (measured: the tool call comes back refused and the turn continues), so
    /// even normal mode cannot change the machine on its own.
    private static func arguments(
        model: String,
        systemPrompt: String?,
        lean: Bool,
        session: (id: String, resumable: Bool)?
    ) -> [String] {
        // The Agent SDK's own base args. `-p` is deliberately absent: passing
        // `--input-format stream-json` is what runs the CLI headless.
        var arguments = [
            "--output-format", "stream-json",
            "--verbose",
            "--input-format", "stream-json",
            "--include-partial-messages",
        ]

        let model = model.trimmingCharacters(in: .whitespaces)
        if !model.isEmpty { arguments += ["--model", model] }

        if let session {
            arguments += session.resumable ? ["--resume", session.id] : ["--session-id", session.id]
        } else {
            // A throwaway call must not land in the user's session history.
            arguments.append("--no-session-persistence")
        }

        if lean {
            // --safe-mode drops CLAUDE.md, skills, plugins, hooks, MCP servers,
            // agents and output styles while leaving auth alone; --restricted
            // and --tools "" remove the tools themselves.
            arguments += [
                "--tools", "",
                "--restricted",
                "--disable-slash-commands",
                "--strict-mcp-config",
                "--safe-mode",
            ]
            if let systemPrompt, !systemPrompt.isEmpty {
                arguments += ["--system-prompt", systemPrompt]
            }
        }
        return arguments
    }

    /// The child's environment.
    ///
    /// HOME is inherited untouched: that is where the subscription login lives,
    /// and using it is the entire point. The three variables that would route
    /// the request through a metered key are removed instead, so the `apiKeySource`
    /// guard and this scrub are independent layers rather than the same one twice.
    private static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        let searchPath = ProcessRunner.loginShellPath + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = searchPath.joined(separator: ":")

        environment["CLAUDE_CODE_ENTRYPOINT"] = "sdk-ts"
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"] {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    /// An empty directory of our own, so the agent's cwd is never a real
    /// project: in normal mode that is also what it would read CLAUDE.md from.
    private static func workspaceDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = support.appendingPathComponent("QuickAI/claude-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The text to send. A resumed session already holds the history, so only
    /// the new question goes out; a fresh one gets the transcript as a preamble.
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

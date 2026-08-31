import CryptoKit
import Foundation

enum CopilotClientError: LocalizedError {
    case notInstalled
    case launchFailed(String)
    case failed(String)
    case modelUnavailable(String)
    case noEvents

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Copilot was not found. Open Settings (⌘,) to set its path. \(HarnessKind.copilot.installHint)"
        case .launchFailed(let detail):
            return "Could not start Copilot: \(detail)"
        case .failed(let detail):
            return "Copilot: \(detail)"
        case .modelUnavailable(let detail):
            return "Copilot: \(detail) Some plans only include \"auto\" (Copilot Student is one); switch models with ⌘P."
        case .noEvents:
            return "Copilot produced no response (no events on its JSON stream)."
        }
    }
}

/// Maps a QuickAI conversation to a Copilot CLI session, exactly like the
/// Claude one: QuickAI picks the id (`--session-id`) on the first turn and
/// resumes it (`--resume`) afterwards, and an id becomes resumable only after
/// a turn has finished.
private actor CopilotSessionRegistry {
    static let shared = CopilotSessionRegistry()

    private var sessions: [String: String] = [:]
    private var resumable: Set<String> = []

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
private final class CopilotChildHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func adopt(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let process = self.process
        self.process = nil
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }
}

/// Collects the child's stderr off the reading thread: Copilot prints its
/// errors there as plain text (`Error: Model "x" ... is not available.`) and
/// that line is the only useful message when no `result` event ever arrives.
///
/// The buffer accumulates incrementally instead of waiting for EOF: stdout
/// reaches EOF a beat before stderr closes, so a read-to-end snapshot taken at
/// that moment was still empty and the panel showed the fallback text instead
/// of the CLI's own message (seen live with a rejected model).
private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var closed = false

    func drain(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let chunk = handle.availableData // blocks; empty means EOF
                guard let self else { return }
                self.lock.lock()
                if chunk.isEmpty { self.closed = true } else { self.data.append(chunk) }
                self.lock.unlock()
                if chunk.isEmpty { return }
            }
        }
    }

    private func snapshot() -> (text: String, closed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), closed)
    }

    /// stderr so far, giving the exiting child a moment to finish writing.
    func text(waitingUpTo timeout: TimeInterval) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let (text, done) = snapshot()
            if done || !text.isEmpty || Date() > deadline { return text }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

/// Streams answers out of the local `copilot` CLI (GitHub Copilot), one child
/// process per turn, paid by the user's Copilot subscription.
///
/// The invocation is non-interactive JSONL: the question goes on stdin (never
/// in argv), `--output-format json --stream on` yields one event per line, and
/// the child exits when the turn ends. Unlike claude there is no separate
/// system-prompt flag and no way to shed Copilot's own prompt: lean mode
/// delivers QuickAI's prompt as an `AGENTS.md` custom-instructions file in a
/// workspace directory QuickAI owns (verified to reach the model; the
/// documented `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` variable did not).
///
/// The child always runs with a QuickAI-private `COPILOT_HOME`. Auth lives in
/// the Keychain ("copilot-cli"), so the login survives the override, while the
/// user's own MCP servers, plugins, sessions and memory never touch the panel,
/// and no turn of ours ever lands in their session list. Copilot has no
/// equivalent of claude's `--no-session-persistence`, so this is also what
/// keeps throwaway title calls out of the user's history.
enum CopilotClient {
    /// - Parameters:
    ///   - systemPrompt: written as AGENTS.md into the child's cwd in lean
    ///     mode; nil leaves only Copilot's own prompt in place.
    ///   - lean: `--available-tools=none --disable-builtin-mcps`, so the model
    ///     has no tools at all (an empty `--available-tools=` filters nothing).
    ///     In either mode nothing is ever auto-approved: without a permission
    ///     handler the CLI denies every request and the turn continues
    ///     (measured: "Permission denied and could not request permission from
    ///     user", no file created).
    ///   - ephemeral: for throwaway calls (conversation titles). No session
    ///     flags are passed; the leftover session lands in QuickAI's private
    ///     home, never in the user's.
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
            let child = CopilotChildHandle()
            let task = Task {
                do {
                    let session = ephemeral ? nil : await CopilotSessionRegistry.shared.session(for: conversationId)
                    let prompt = Self.promptText(messages: messages, replayHistory: !(session?.resumable ?? false))

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: install.path)
                    process.arguments = Self.arguments(model: model, lean: lean, session: session)
                    process.currentDirectoryURL = try Self.workspaceDirectory(
                        systemPrompt: lean ? systemPrompt : nil
                    )
                    process.environment = Self.environment()

                    let input = Pipe()
                    let output = Pipe()
                    let errorOutput = Pipe()
                    process.standardInput = input
                    process.standardOutput = output
                    process.standardError = errorOutput

                    do {
                        try process.run()
                    } catch {
                        throw CopilotClientError.launchFailed(error.localizedDescription)
                    }
                    child.adopt(process)

                    let stderr = StderrBuffer()
                    stderr.drain(errorOutput.fileHandleForReading)

                    // The prompt, then EOF: that is what makes the child answer
                    // and exit instead of waiting for a terminal.
                    try? input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                    try? input.fileHandleForWriting.close()

                    try await Self.consume(
                        output.fileHandleForReading,
                        child: child,
                        stderr: stderr,
                        model: model,
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
        await CopilotSessionRegistry.shared.forget(conversationId)
    }

    // MARK: - Event stream

    private static func consume(
        _ handle: FileHandle,
        child: CopilotChildHandle,
        stderr: StderrBuffer,
        model: String,
        sessionId: String?,
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) async throws {
        var sawEvent = false
        // Message ids that already streamed deltas: their final
        // `assistant.message` is a repeat, not new text.
        var streamedMessages = Set<String>()

        // A child that emits nothing is hung (a stalled network call, a prompt
        // it is waiting on). Fail loudly instead of spinning forever; a stall
        // of a few minutes was observed once during probing.
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
            if !sawEvent {
                sawEvent = true
                watchdog.cancel()
            }
            let payload = event["data"] as? [String: Any]

            switch type {
            case "assistant.message_delta":
                if let messageId = payload?["messageId"] as? String { streamedMessages.insert(messageId) }
                if let text = payload?["deltaContent"] as? String, !text.isEmpty {
                    continuation.yield(.text(text))
                }

            case "assistant.reasoning_delta":
                if let text = payload?["deltaContent"] as? String, !text.isEmpty {
                    continuation.yield(.reasoning(text))
                }

            case "assistant.message":
                // Only a fallback: some models answer without delta events, and
                // this is the complete message they end with.
                guard let messageId = payload?["messageId"] as? String,
                      !streamedMessages.contains(messageId),
                      let text = payload?["content"] as? String, !text.isEmpty
                else { continue }
                streamedMessages.insert(messageId)
                continuation.yield(.text(text))

            case "result":
                let exitCode = event["exitCode"] as? Int ?? 0
                guard exitCode == 0 else {
                    throw await Self.failure(stderr: stderr, fallback: "exit code \(exitCode)")
                }
                if let sessionId { await CopilotSessionRegistry.shared.markResumable(sessionId) }
                // An explicit model that answered proves the plan includes it,
                // so the "auto only" note in Settings can retract itself.
                if !model.isEmpty, model != "auto" {
                    UserDefaults.standard.set(false, forKey: Self.autoOnlyDefaultsKey)
                }
                return

            default:
                continue
            }
        }

        // EOF without a result event: the child bailed out before the turn
        // (bad model id, not logged in, network down). Stderr has the reason.
        guard sawEvent else {
            throw await Self.failure(stderr: stderr, fallback: CopilotClientError.noEvents.localizedDescription)
        }
        throw await Self.failure(stderr: stderr, fallback: "the turn ended without a result event")
    }

    /// UserDefaults flag Settings reads to explain that this plan has been
    /// rejecting every model except "auto". Set on the rejection, cleared the
    /// moment an explicit model answers, so a plan change heals it either way.
    static let autoOnlyDefaultsKey = "copilotAutoOnlyObserved"

    /// The typed error for whatever the child left on stderr. Copilot's own
    /// errors are one-liners like `Error: Model "x" from --model flag is not
    /// available.`; the wait is for the exiting child to finish writing.
    private static func failure(stderr: StderrBuffer, fallback: String) async -> CopilotClientError {
        let text = await stderr.text(waitingUpTo: 1.5)
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? fallback
        guard line.contains("from --model flag is not available") else {
            return .failed(line)
        }
        UserDefaults.standard.set(true, forKey: autoOnlyDefaultsKey)
        return .modelUnavailable(line.replacingOccurrences(of: "Error: ", with: ""))
    }

    // MARK: - Invocation

    /// The child's command line.
    ///
    /// Safe mode is the floor: `--allow-all-tools`, `--allow-all`, `--yolo` and
    /// `--autopilot` are never passed, in either mode. The help claims
    /// `--allow-all-tools` is "required for non-interactive mode"; it is not:
    /// without it every tool request is denied and the turn continues, which is
    /// exactly the behavior QuickAI wants.
    private static func arguments(
        model: String,
        lean: Bool,
        session: (id: String, resumable: Bool)?
    ) -> [String] {
        var arguments = [
            "--output-format", "json",
            "--stream", "on",
            "--no-auto-update",
        ]

        // "auto" is Copilot's own routing and also the only value some plans
        // accept: on Copilot Education every explicit id, including the one
        // auto itself routes to, comes back "not available".
        let model = model.trimmingCharacters(in: .whitespaces)
        if !model.isEmpty { arguments += ["--model", model] }

        if let session {
            arguments += session.resumable ? ["--resume", session.id] : ["--session-id", session.id]
        }
        // No session flags for ephemeral calls: the CLI has no equivalent of
        // claude's --no-session-persistence, so the throwaway session simply
        // lands in QuickAI's private COPILOT_HOME.

        if lean {
            // =none matters: a bare `--available-tools=` filters nothing
            // (measured: all 18 tools stayed visible).
            arguments += ["--available-tools=none", "--disable-builtin-mcps"]
        }
        return arguments
    }

    /// The child's environment.
    ///
    /// COPILOT_HOME points at a directory QuickAI owns. The login itself lives
    /// in the Keychain (service "copilot-cli"), so it survives the override,
    /// while everything file-based stays out of the user's ~/.copilot: their
    /// MCP servers and plugins never spawn under the panel, and our sessions
    /// never appear in their resume list.
    ///
    /// The scrub keeps billing on the subscription login: COPILOT_PROVIDER_*
    /// activates BYOK (a metered key, the thing a harness exists to avoid) and
    /// the GitHub token variables would silently switch whose plan pays. The
    /// private home is the second, independent layer: BYOK is env-only, so a
    /// config file cannot re-enable it either.
    private static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        let searchPath = ProcessRunner.loginShellPath + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = searchPath.joined(separator: ":")

        environment["COPILOT_HOME"] = homeDirectory().path
        environment["COPILOT_AUTO_UPDATE"] = "false"

        for key in environment.keys where key.hasPrefix("COPILOT_PROVIDER_") {
            environment.removeValue(forKey: key)
        }
        for key in [
            "COPILOT_OFFLINE", "COPILOT_ALLOW_ALL", "COPILOT_ASSISTED_APPROVAL", "COPILOT_MODEL",
            "COPILOT_CUSTOM_INSTRUCTIONS_DIRS", "COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN",
        ] {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    private static func supportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("QuickAI", isDirectory: true)
    }

    /// QuickAI's private COPILOT_HOME.
    private static func homeDirectory() -> URL {
        let directory = (try? supportDirectory().appendingPathComponent("copilot-home", isDirectory: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("QuickAI-copilot-home")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// An empty directory of our own as the child's cwd, so the agent never
    /// reads a real project. With a system prompt it also carries AGENTS.md,
    /// the only injection channel Copilot leaves: one directory per prompt
    /// content, because concurrent children (a title call racing a follow-up)
    /// carry different prompts and a shared file would cross them.
    private static func workspaceDirectory(systemPrompt: String?) throws -> URL {
        let root = try supportDirectory().appendingPathComponent("copilot-workspace", isDirectory: true)
        guard let systemPrompt, !systemPrompt.isEmpty else {
            let plain = root.appendingPathComponent("plain", isDirectory: true)
            try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
            return plain
        }

        let digest = SHA256.hash(data: Data(systemPrompt.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        let directory = root.appendingPathComponent("p-\(key)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let instructions = directory.appendingPathComponent("AGENTS.md")
        if (try? String(contentsOf: instructions, encoding: .utf8)) != systemPrompt {
            try systemPrompt.write(to: instructions, atomically: true, encoding: .utf8)
        }
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

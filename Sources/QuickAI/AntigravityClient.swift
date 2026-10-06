import CryptoKit
import Foundation

enum AntigravityClientError: LocalizedError {
    case notInstalled
    case launchFailed(String)
    case meteredAuth(String)
    case failed(String)
    case deniedActions([String])
    case noInit

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Antigravity was not found. Open Settings (⌘,) to set its path. \(HarnessKind.antigravity.installHint)"
        case .launchFailed(let detail):
            return "Could not start Antigravity: \(detail)"
        case .meteredAuth(let method):
            return """
                Antigravity signed in with "\(method)", so this answer would be billed per token \
                instead of covered by your Google plan. QuickAI stopped before sending it. \
                Run agy in a terminal and sign in with your Google account.
                """
        case .failed(let detail):
            return "Antigravity: \(detail)"
        case .deniedActions(let actions):
            return """
                Antigravity stopped because it needed permission for \(actions.joined(separator: ", ")), \
                and QuickAI never approves tools. Lean mode (Settings) answers without them.
                """
        case .noInit:
            return "Antigravity did not start a session (no init event)."
        }
    }
}

/// What a child was started with. A turn can only reuse a child whose key
/// matches: the model, the agent and its prompt are fixed for its lifetime.
private struct AntigravityChildKey: Hashable {
    let path: String
    let model: String
    let lean: Bool
    let systemPrompt: String

    /// The custom agent that carries lean mode, one per prompt content so a
    /// title call and a follow-up never share a file. Nil runs agy's default
    /// agent.
    var agentName: String? {
        guard lean else { return nil }
        let digest = SHA256.hash(data: Data(systemPrompt.utf8))
        return "quickai-" + digest.map { String(format: "%02x", $0) }.joined().prefix(16)
    }
}

/// One stdout event per line, handed to whichever turn is reading. A child
/// serves many turns, so the queue outlives any single reader.
private final class AntigravityEventQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [[String: Any]] = []
    private var finished = false
    private var waiter: CheckedContinuation<[String: Any]?, Never>?

    func push(_ event: [String: Any]) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: event)
        } else {
            buffer.append(event)
            lock.unlock()
        }
    }

    func finish() {
        lock.lock()
        finished = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: nil)
    }

    /// The next event, or nil once the child's stdout is closed.
    func next() async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !buffer.isEmpty {
                let event = buffer.removeFirst()
                lock.unlock()
                continuation.resume(returning: event)
            } else if finished {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    /// Drops anything a previous turn left behind, so a late event can never
    /// be read as part of the next answer.
    func discardBuffered() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }
}

/// One `agy` process in stream-json mode. It answers one turn per message
/// written to its stdin and stays up between them, so a follow-up skips the
/// ~5s of sign-in and model-config round trips every agy launch pays.
/// Closing stdin is the whole teardown: the child exits on EOF, which also
/// happens when QuickAI itself dies, so no orphan can outlive the app.
private final class AntigravityChild: @unchecked Sendable {
    let key: AntigravityChildKey
    private let process: Process
    private let input: FileHandle
    private let events = AntigravityEventQueue()
    let stderr = StderrBuffer()
    private let logURL: URL

    private let lock = NSLock()
    private var readiness: Task<String, Error>?
    private(set) var lastUsed = Date()

    init(key: AntigravityChildKey, resume conversation: String?) throws {
        self.key = key
        logURL = try AntigravityClient.logDirectory().appendingPathComponent("\(UUID().uuidString).log")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: key.path)
        process.arguments = AntigravityClient.arguments(key: key, logURL: logURL, resume: conversation)
        process.currentDirectoryURL = try AntigravityClient.workspaceDirectory()
        process.environment = try AntigravityClient.environment()
        if let agent = key.agentName {
            try AntigravityClient.writeAgent(named: agent, systemPrompt: key.systemPrompt)
        }

        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
        // A write to a child that already exited must fail, not raise SIGPIPE
        // and take the whole app down with it.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        do {
            try process.run()
        } catch {
            throw AntigravityClientError.launchFailed(error.localizedDescription)
        }
        self.process = process
        self.input = input.fileHandleForWriting
        stderr.drain(errorOutput.fileHandleForReading)

        let events = events
        let handle = output.fileHandleForReading
        Task.detached(priority: .userInitiated) {
            do {
                for try await line in handle.bytes.lines {
                    guard line.hasPrefix("{"), let data = line.data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { continue }
                    events.push(event)
                }
            } catch {}
            events.finish()
        }
    }

    var isAlive: Bool { process.isRunning }

    func touch() { lastUsed = Date() }

    /// agy's own conversation id, once the child has signed in and proved the
    /// login is the subscription one. Shared by every caller: a pre-warmed
    /// child usually has its answer queued before anyone asks.
    func ready() async throws -> String {
        try await readinessTask().value
    }

    private func readinessTask() -> Task<String, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let readiness { return readiness }
        let task = Task { try await self.awaitInit() }
        readiness = task
        return task
    }

    private func awaitInit() async throws -> String {
        // A child that never signs in is hung (a stalled network call, a
        // login prompt nobody can answer). Startup measured 5 to 9 seconds.
        let watchdog = Task {
            do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
            self.terminate()
        }
        defer { watchdog.cancel() }

        while let event = await events.next() {
            switch event["event"] as? String {
            case "init":
                guard let conversation = event["conversation_id"] as? String, !conversation.isEmpty else {
                    throw AntigravityClientError.noInit
                }
                try await verifySubscription()
                return conversation
            case "result":
                // Startup failures (not signed in, unknown model) arrive as a
                // result with no turn behind it.
                throw await failure(result: event["result"] as? [String: Any])
            default:
                continue
            }
        }
        throw await failure(result: nil)
    }

    /// The third billing layer, the analog of claude's `apiKeySource`: agy logs
    /// how it signed in (`applyAuthResult: ... authMethod=consumer`) before it
    /// announces the session, and only the personal sign-in is covered by the
    /// plan. `gemini_api_key` (measured with a poisoned home) and the Google
    /// Cloud pay-as-you-go routes bill per token, and anything unrecognized is
    /// treated the same way. Checked before the question is written, so a
    /// refused child never sends it.
    private func verifySubscription() async throws {
        defer { try? FileManager.default.removeItem(at: logURL) }
        var method: String?
        for _ in 0..<10 {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if let range = log.range(of: #"authMethod=[^,\s]+"#, options: .regularExpression) {
                method = String(log[range].dropFirst("authMethod=".count))
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard method == "consumer" else {
            terminate()
            throw AntigravityClientError.meteredAuth(method ?? "unknown")
        }
    }

    func send(_ text: String) throws {
        events.discardBuffered()
        let message: [String: Any] = ["event": "user", "message": ["role": "user", "content": text]]
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        do {
            try input.write(contentsOf: data)
        } catch {
            throw AntigravityClientError.launchFailed("the agy process is gone (\(error.localizedDescription))")
        }
    }

    func next() async -> [String: Any]? { await events.next() }

    /// Lets a one-shot child exit by itself once its single turn is done.
    func finishInput() { try? input.close() }

    func terminate() {
        finishInput()
        if process.isRunning { process.terminate() }
    }

    /// The typed error for a result event or, failing that, whatever the
    /// child left on stderr (`error: ...` lines, or the structured
    /// `AGY_ERROR: {"short_error": ...}` line).
    func failure(result: [String: Any]?) async -> AntigravityClientError {
        if let message = result?["error"] as? String, !message.isEmpty {
            return .failed(Self.clean(message))
        }
        let text = await stderr.text(waitingUpTo: 1.5)
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let line = lines.last(where: { !$0.hasPrefix("AGY_ERROR:") }) {
            return .failed(Self.clean(line))
        }
        if let line = lines.last,
           let data = line.dropFirst("AGY_ERROR:".count).data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let short = json["short_error"] as? String {
            return .failed(short)
        }
        if let status = result?["status"] as? String {
            return .failed("the turn ended with status \(status)")
        }
        return .noInit
    }

    private static func clean(_ message: String) -> String {
        var message = message
        while let range = message.range(of: #"^(?i:error):\s*"#, options: .regularExpression) {
            message.removeSubrange(range)
        }
        return message
    }
}

/// Owns every agy child: one pre-warmed spare, and the children bound to
/// QuickAI conversations, each idle between turns.
private actor AntigravityPool {
    static let shared = AntigravityPool()

    /// A child stays up this long after its last turn. Long enough for a
    /// follow-up, short enough that ~170MB per child does not sit around.
    private static let idleLifetime: UInt64 = 300_000_000_000
    /// Children bound to conversations, beyond the spare. ⌘[ / ⌘] can hop
    /// between two conversations without paying startup twice.
    private static let liveLimit = 2

    /// agy's conversation id per QuickAI conversation, once a turn finished,
    /// so a new child can pick the context up with `--conversation`.
    private var conversations: [String: String] = [:]
    private var live: [String: AntigravityChild] = [:]
    private var spare: AntigravityChild?

    func prewarm(_ key: AntigravityChildKey) {
        if let spare, spare.key == key, spare.isAlive { return }
        spare?.terminate()
        spare = try? AntigravityChild(key: key, resume: nil)
        if let spare { scheduleExpiry(spare) }
    }

    /// The child for this conversation's next turn, and whether it already
    /// holds the conversation (so only the new question needs to travel).
    func checkout(conversationId: String, key: AntigravityChildKey) throws -> (AntigravityChild, resumed: Bool) {
        if let child = live.removeValue(forKey: conversationId) {
            if child.key == key, child.isAlive { return (child, true) }
            child.terminate()
        }
        if let conversation = conversations[conversationId] {
            return (try AntigravityChild(key: key, resume: conversation), true)
        }
        if let child = spare, child.key == key, child.isAlive {
            spare = nil
            return (child, false)
        }
        return (try AntigravityChild(key: key, resume: nil), false)
    }

    /// A turn finished cleanly: keep the child for the next one.
    func checkin(_ child: AntigravityChild, conversationId: String, agyConversation: String) {
        conversations[conversationId] = agyConversation
        live[conversationId]?.terminate()
        live[conversationId] = child
        scheduleExpiry(child)
        while live.count > Self.liveLimit,
              let oldest = live.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            oldest.value.terminate()
            live.removeValue(forKey: oldest.key)
        }
    }

    func forget(_ conversationId: String) {
        conversations.removeValue(forKey: conversationId)
        live.removeValue(forKey: conversationId)?.terminate()
    }

    private func scheduleExpiry(_ child: AntigravityChild) {
        child.touch()
        let stamp = child.lastUsed
        Task {
            try? await Task.sleep(nanoseconds: Self.idleLifetime)
            self.expire(child, ifIdleSince: stamp)
        }
    }

    private func expire(_ child: AntigravityChild, ifIdleSince stamp: Date) {
        guard child.lastUsed == stamp else { return }
        if spare === child {
            spare = nil
            child.terminate()
        }
        if let entry = live.first(where: { $0.value === child }) {
            live.removeValue(forKey: entry.key)
            child.terminate()
        }
    }
}

/// Lets `onTermination` reach the turn's child from any thread.
private final class AntigravityTurnHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var child: AntigravityChild?

    func adopt(_ child: AntigravityChild) {
        lock.lock()
        self.child = child
        lock.unlock()
    }

    func release() {
        lock.lock()
        child = nil
        lock.unlock()
    }

    /// Stops the turn. The child goes with it: agy has no way to interrupt a
    /// turn from stream-json, and the next turn resumes the conversation in a
    /// fresh child with `--conversation`.
    func terminate() {
        lock.lock()
        let child = self.child
        self.child = nil
        lock.unlock()
        child?.terminate()
    }
}

/// Streams answers out of the local `agy` CLI (Google Antigravity), paid by
/// the user's Google plan.
///
/// The invocation is stream-json both ways and never uses `-p`: one NDJSON
/// message per turn on stdin (the question never touches argv), `init`, then
/// `step_update` events with `text_delta`, then `result`. Unlike claude and
/// copilot the child is long-lived, one per conversation plus a spare started
/// when the panel opens: every agy launch spends about five seconds on sign-in
/// and model-config round trips before it can take a question, so a cold turn
/// took ~8s to its first token and a warm one ~2s.
///
/// The child runs with a QuickAI-private `HOME`. agy keeps everything under
/// `~/.gemini` (conversations, settings, rules, skills, plugins, MCP servers),
/// and none of that may leak either way: our turns stay out of the user's
/// `/resume` list, and their settings (`modelProvider`, permission rules, an
/// always-proceed mode) and MCP servers never reach the panel. The login lives
/// in the Keychain (service "gemini", account "antigravity"), and the Keychain
/// is found through `$HOME/Library/Keychains`, so the private home carries a
/// symlink to the real one and nothing else.
enum AntigravityClient {
    /// - Parameters:
    ///   - systemPrompt: the body of the lean-mode agent; nil leaves agy's own
    ///     prompt in place.
    ///   - lean: runs a QuickAI agent with `excludeDefaultComponents` (no
    ///     default prompt, no tools) and `inheritCustomizations: false`. A
    ///     lean turn measured 590 input tokens against 12,860 for the default
    ///     agent. In either mode nothing is ever approved: headless agy denies
    ///     every request that needs permission (measured: write and command
    ///     refused, no file), and `--dangerously-skip-permissions` is never
    ///     passed.
    ///   - ephemeral: a one-shot child for throwaway calls (titles). Its
    ///     conversation lands in QuickAI's private home, never the user's.
    static func stream(
        install: HarnessInstall,
        model: String,
        systemPrompt: String?,
        lean: Bool,
        conversationId: String,
        messages: [Message],
        ephemeral: Bool = false
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        let key = AntigravityChildKey(
            path: install.path, model: model.trimmingCharacters(in: .whitespaces),
            lean: lean, systemPrompt: systemPrompt ?? ""
        )
        return AsyncThrowingStream { continuation in
            let handle = AntigravityTurnHandle()
            let task = Task {
                do {
                    let child: AntigravityChild
                    let resumed: Bool
                    if ephemeral {
                        (child, resumed) = (try AntigravityChild(key: key, resume: nil), false)
                    } else {
                        (child, resumed) = try await AntigravityPool.shared.checkout(conversationId: conversationId, key: key)
                    }
                    handle.adopt(child)
                    // ⎋ may have landed while the child was being picked, before
                    // there was anything for onTermination to stop.
                    try Task.checkCancellation()

                    let agyConversation = try await child.ready()
                    try Task.checkCancellation()
                    try child.send(Self.promptText(messages: messages, replayHistory: !resumed))
                    if ephemeral { child.finishInput() }

                    try await Self.consume(child, continuation: continuation)
                    handle.release()
                    if !ephemeral {
                        await AntigravityPool.shared.checkin(
                            child, conversationId: conversationId, agyConversation: agyConversation
                        )
                    }
                    continuation.finish()
                } catch {
                    handle.terminate()
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                handle.terminate()
            }
        }
    }

    /// Starts a child in the background so the next question skips agy's
    /// startup. Called when the panel opens or the model changes; a no-op
    /// when a matching spare is already up.
    static func prewarm(install: HarnessInstall, model: String, systemPrompt: String?, lean: Bool) {
        let key = AntigravityChildKey(
            path: install.path, model: model.trimmingCharacters(in: .whitespaces),
            lean: lean, systemPrompt: systemPrompt ?? ""
        )
        Task.detached(priority: .utility) { await AntigravityPool.shared.prewarm(key) }
    }

    /// `agy models` output, run like a turn (private home, scrubbed
    /// environment) so listing models never touches the user's own state.
    static func listModels(install: HarnessInstall) throws -> String {
        let log = try logDirectory().appendingPathComponent("models-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        guard let result = ProcessRunner.run(
            install.path, ["--log-file", log.path, "models"], environment: try environment(), timeout: 30
        ) else {
            throw AntigravityClientError.launchFailed("agy models did not run")
        }
        guard result.succeeded else {
            let line = result.stderr.split(separator: "\n").last.map(String.init) ?? "agy models failed"
            throw AntigravityClientError.failed(line)
        }
        return result.stdout
    }

    /// Drops the conversation's child and its agy session, so the next turn
    /// starts clean.
    static func reset(conversationId: String) async {
        await AntigravityPool.shared.forget(conversationId)
    }

    // MARK: - Event stream

    private static func consume(
        _ child: AntigravityChild,
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) async throws {
        var sawText = false
        var textStep: Int?

        while let event = await child.next() {
            try Task.checkCancellation()
            switch event["event"] as? String {
            case "step_update":
                guard let step = event["step_update"] as? [String: Any],
                      step["step_type"] as? String == "agent_response"
                else { continue }
                // agy has a thinking delta in its protocol, but no model has
                // emitted one here (27s of silent thinking on flash-high), so
                // the reasoning channel stays empty; wired in case it appears.
                if let thinking = step["thinking_delta"] as? String, !thinking.isEmpty {
                    continuation.yield(.reasoning(thinking))
                }
                guard let text = step["text_delta"] as? String, !text.isEmpty else { continue }
                // Normal mode can answer in several steps around a tool call;
                // keep them from running into each other.
                let index = step["step_index"] as? Int
                if sawText, index != textStep { continuation.yield(.text("\n\n")) }
                textStep = index
                sawText = true
                continuation.yield(.text(text))

            case "result":
                let result = event["result"] as? [String: Any] ?? [:]
                guard result["status"] as? String == "SUCCESS" else {
                    throw await child.failure(result: result)
                }
                if !sawText {
                    if let response = result["response"] as? String,
                       !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continuation.yield(.text(response))
                    } else if let denied = result["denied_actions"] as? [[String: Any]], !denied.isEmpty {
                        // Headless agy ends the turn, with no answer at all,
                        // when the model reaches for a tool that needs approval.
                        throw AntigravityClientError.deniedActions(
                            denied.compactMap { $0["action"] as? String }
                        )
                    }
                }
                return

            default:
                continue
            }
        }
        try Task.checkCancellation()
        // EOF without a result: the child died mid-turn. Stderr has the reason.
        throw await child.failure(result: nil)
    }

    // MARK: - Invocation

    /// The child's command line.
    ///
    /// Safe mode is the floor: `--dangerously-skip-permissions` is never
    /// passed, and neither is `--mode`, whose `plan` value proceeds through
    /// plan review on its own in headless runs. `--disable-slash-commands`
    /// keeps a question that starts with "/" a question (measured: `/usage
    /// what is 2+2?` reached the model) instead of a CLI command.
    fileprivate static func arguments(key: AntigravityChildKey, logURL: URL, resume: String?) -> [String] {
        var arguments = [
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--disable-slash-commands",
            // Also how the subscription check reads `authMethod`, and it keeps
            // a per-launch log out of the private home's own log directory.
            "--log-file", logURL.path,
        ]
        if !key.model.isEmpty { arguments += ["--model", key.model] }
        if let agent = key.agentName { arguments += ["--agent", agent] }
        if let resume { arguments += ["--conversation", resume] }
        return arguments
    }

    /// The child's environment.
    ///
    /// The scrub keeps billing on the Google sign-in. `GEMINI_API_KEY` and
    /// `GOOGLE_API_KEY` switch agy to the metered Gemini API (together with a
    /// `modelProvider` setting, which the private home also keeps out),
    /// `AGY_ADC_AUTH` and the Google Cloud variables to Application Default
    /// Credentials billed to a project, and `GOOGLE_GEMINI_BASE_URL` /
    /// `CLOUD_CODE_URL` to another endpoint. `ANTIGRAVITY_*` is what the
    /// desktop app hands its own terminals to attach to a running server.
    static func environment() throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        let searchPath = ProcessRunner.loginShellPath + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = searchPath.joined(separator: ":")
        environment["HOME"] = try homeDirectory().path
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"

        for key in environment.keys where key.hasPrefix("ANTIGRAVITY_") {
            environment.removeValue(forKey: key)
        }
        for key in [
            "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GEMINI_BASE_URL", "CLOUD_CODE_URL",
            "AGY_ADC_AUTH", "AGY_ACCOUNT", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT",
            "GOOGLE_CLOUD_LOCATION", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_GENAI_USE_ENTERPRISE",
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

    /// QuickAI's private HOME for agy, rebuilt on every launch so a damaged
    /// one heals itself.
    ///
    /// `Library/Keychains` points at the real one: with a bare private HOME
    /// agy could not find its login at all (measured: "authentication
    /// required"). `useG1Credits` is pinned off so a used-up plan quota can
    /// never roll over into paid AI credits.
    private static func homeDirectory() throws -> URL {
        let manager = FileManager.default
        let home = try supportDirectory().appendingPathComponent("antigravity-home", isDirectory: true)

        let library = home.appendingPathComponent("Library", isDirectory: true)
        try manager.createDirectory(at: library, withIntermediateDirectories: true)
        let keychains = library.appendingPathComponent("Keychains")
        let realKeychains = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Keychains")
        if (try? manager.destinationOfSymbolicLink(atPath: keychains.path)) != realKeychains {
            try? manager.removeItem(at: keychains)
            try manager.createSymbolicLink(atPath: keychains.path, withDestinationPath: realKeychains)
        }

        let cli = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        try manager.createDirectory(at: cli, withIntermediateDirectories: true)
        let settingsURL = cli.appendingPathComponent("settings.json")
        var settings = (try? Data(contentsOf: settingsURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        // agy saves `false` by leaving the key out, so `{}` is the healthy state
        // and only a value that turns something on needs undoing.
        if settings["useG1Credits"] as? Bool == true || settings["modelProvider"] != nil {
            settings["useG1Credits"] = false
            settings.removeValue(forKey: "modelProvider")
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: .atomic)
        }
        return home
    }

    /// The lean-mode agent, in the private home's global agents directory.
    ///
    /// `excludeDefaultComponents` drops agy's coding prompt and its built-in
    /// tools, `tools: []` names none back, and `inheritCustomizations: false`
    /// keeps skills, rules, plugins and subagents out even if the private
    /// home ever grew some. The body after the H1 is the system prompt;
    /// further H1s inside the user's prompt were measured to still apply.
    fileprivate static func writeAgent(named name: String, systemPrompt: String) throws {
        let directory = try homeDirectory()
            .appendingPathComponent(".gemini/config/agents/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = """
            ---
            name: \(name)
            description: QuickAI answering as a plain assistant, without tools.
            mainAgent: true
            subagent: false
            hidden: true
            excludeDefaultComponents: true
            inheritCustomizations: false
            inheritMcp: false
            tools: []
            ---

            # QuickAI

            \(systemPrompt)

            """
        let file = directory.appendingPathComponent("agent.md")
        if (try? String(contentsOf: file, encoding: .utf8)) != contents {
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// An empty directory of our own as the child's cwd, so the agent never
    /// reads a real project and no workspace customization can apply.
    fileprivate static func workspaceDirectory() throws -> URL {
        let directory = try supportDirectory().appendingPathComponent("antigravity-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    fileprivate static func logDirectory() throws -> URL {
        let directory = try supportDirectory().appendingPathComponent("antigravity-logs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The text to send. A child that already holds the conversation only
    /// needs the new question; a fresh one gets the transcript as a preamble.
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

import Foundation
import Security

enum OpenCodeServerError: LocalizedError {
    case notInstalled
    case noFreePort
    case launchFailed(String)
    case unhealthy(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "OpenCode was not found. Open Settings (⌘,) to set its path. \(HarnessKind.opencode.installHint)"
        case .noFreePort:
            return "Could not reserve a local port for the OpenCode server."
        case .launchFailed(let detail):
            return "Could not start the OpenCode server: \(detail)"
        case .unhealthy(let detail):
            return "The OpenCode server did not come up: \(detail)"
        }
    }
}

/// Owns the single `opencode serve` child process QuickAI talks to.
///
/// `opencode run` was measured to buffer a whole answer into one event, so the
/// headless server is the only transport that streams token by token. The
/// server is launched lazily, kept alive for the life of the app, and torn
/// down on quit.
///
/// Safety choices, all deliberate:
/// - binds to 127.0.0.1 only, with a random per-launch password, because this
///   server can run shell commands and must not be drivable by other local
///   processes;
/// - runs in an empty directory of our own so the agent never sees the user's
///   projects;
/// - `OPENCODE_DISABLE_PROJECT_CONFIG` so no stray AGENTS.md is picked up;
/// - HOME is inherited untouched: that is where `opencode auth login` stored
///   the credentials, and using them is the entire point.
actor OpenCodeServer {
    static let shared = OpenCodeServer()

    struct Endpoint: Equatable {
        let baseURL: URL
        let authorization: String

        func request(_ path: String) -> URLRequest {
            var request = URLRequest(url: baseURL.appendingPathComponent(path))
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            return request
        }
    }

    private var process: Process?
    private var endpoint: Endpoint?
    private var launch: Task<Endpoint, Error>?

    /// A live endpoint, starting the server if it is not running yet.
    /// Concurrent callers share one launch instead of racing to spawn.
    func endpoint(install: HarnessInstall) async throws -> Endpoint {
        if let endpoint, let process, process.isRunning { return endpoint }
        stop()

        if let launch { return try await launch.value }
        let task = Task { try await start(install: install) }
        launch = task
        do {
            let resolved = try await task.value
            launch = nil
            return resolved
        } catch {
            launch = nil
            stop()
            throw error
        }
    }

    /// Terminates the child. Safe to call when nothing is running.
    func stop() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        endpoint = nil
        Self.clearPidFile()
    }

    /// Kills a server left behind by a previous run.
    ///
    /// `applicationWillTerminate` only fires on a normal quit, so a crash or a
    /// SIGKILL leaves the child alive holding its port and the user's
    /// credentials. Called at launch, before anything else starts a server.
    nonisolated static func reapOrphan() {
        guard let record = try? String(contentsOf: pidFileURL, encoding: .utf8) else { return }
        defer { clearPidFile() }

        let fields = record.split(separator: " ").map(String.init)
        guard fields.count == 2, let pid = Int32(fields[0]), let port = UInt16(fields[1]) else { return }

        // A bare PID is not enough: it may have been recycled by an unrelated
        // process since. Only kill something that still looks like our server.
        guard let result = ProcessRunner.run("/bin/ps", ["-p", String(pid), "-o", "command="], timeout: 5),
              result.succeeded
        else { return }
        let command = result.stdout
        guard command.contains("opencode"), command.contains("serve"), command.contains("--port \(port)") else {
            return
        }
        kill(pid, SIGTERM)
    }

    // MARK: - Orphan bookkeeping

    private nonisolated static var pidFileURL: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("QuickAI/opencode-server.pid")
    }

    private nonisolated static func writePidFile(pid: Int32, port: UInt16) {
        try? "\(pid) \(port)".write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    private nonisolated static func clearPidFile() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    // MARK: - Launch

    private func start(install: HarnessInstall) async throws -> Endpoint {
        guard let port = ProcessRunner.freePort() else { throw OpenCodeServerError.noFreePort }
        let password = Self.randomPassword()
        let workspace = try Self.workspaceDirectory()

        let child = Process()
        child.executableURL = URL(fileURLWithPath: install.path)
        child.arguments = ["serve", "--port", String(port), "--hostname", "127.0.0.1"]
        child.currentDirectoryURL = workspace
        child.environment = Self.environment(password: password)
        // The server is chatty on stderr and we never read it; discarding
        // avoids filling a pipe buffer and wedging the child.
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice

        do {
            try child.run()
        } catch {
            throw OpenCodeServerError.launchFailed(error.localizedDescription)
        }

        guard let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
            child.terminate()
            throw OpenCodeServerError.launchFailed("could not build the server URL")
        }
        let credentials = Data("opencode:\(password)".utf8).base64EncodedString()
        let resolved = Endpoint(baseURL: baseURL, authorization: "Basic \(credentials)")

        Self.writePidFile(pid: child.processIdentifier, port: port)
        try await waitUntilHealthy(resolved, child: child)

        process = child
        endpoint = resolved
        return resolved
    }

    /// Polls `/global/health` until the server answers or we give up.
    private func waitUntilHealthy(_ endpoint: Endpoint, child: Process) async throws {
        let deadline = Date().addingTimeInterval(20)
        var lastError = "timed out"

        while Date() < deadline {
            if !child.isRunning {
                throw OpenCodeServerError.unhealthy("the server exited with status \(child.terminationStatus)")
            }
            var request = endpoint.request("global/health")
            request.timeoutInterval = 2
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    _ = data
                    return
                }
                lastError = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            } catch {
                lastError = error.localizedDescription
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        child.terminate()
        throw OpenCodeServerError.unhealthy(lastError)
    }

    // MARK: - Child environment

    private static func environment(password: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        // A bundled .app inherits a bare PATH, and opencode shells out to node,
        // bun and git. Give the child the user's real PATH.
        let searchPath = (ProcessRunner.loginShellPath + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
        environment["PATH"] = searchPath.joined(separator: ":")

        environment["OPENCODE_SERVER_PASSWORD"] = password
        environment["OPENCODE_SERVER_USERNAME"] = "opencode"
        environment["OPENCODE_DISABLE_PROJECT_CONFIG"] = "1"
        environment["OPENCODE_DISABLE_AUTOUPDATE"] = "1"

        // Never let an API key stand in for the user's subscription: paying by
        // subscription is the whole reason this provider exists.
        environment.removeValue(forKey: "OPENCODE_API_KEY")

        return environment
    }

    private static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        }
        return Data(bytes).base64EncodedString()
    }

    /// An empty directory of our own, so the agent's cwd is never a real project.
    private static func workspaceDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = support.appendingPathComponent("QuickAI/opencode-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

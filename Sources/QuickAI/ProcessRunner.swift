import Foundation

struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

/// Small helper around `Process` for the short-lived probes the harness
/// integration needs (`--version`, resolving the login shell PATH).
///
/// Long-running children (the opencode server) are managed by their own type;
/// this one always runs to completion or gets killed.
enum ProcessRunner {
    /// Runs `executable` to completion, terminating it after `timeout` seconds.
    /// Returns nil when the process could not be launched at all.
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 10
    ) -> ProcessResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Both pipes are drained on their own queues: a child that fills the
        // 64KB pipe buffer would block forever if we waited for exit first.
        var outData = Data()
        var errData = Data()
        let lock = NSLock()
        let group = DispatchGroup()
        for (pipe, isStdout) in [(outPipe, true), (errPipe, false)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if isStdout { outData = data } else { errData = data }
                lock.unlock()
                group.leave()
            }
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        _ = group.wait(timeout: .now() + 2)

        lock.lock()
        defer { lock.unlock() }
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// The PATH of the user's login shell.
    ///
    /// A bundled .app launched from Finder or the Dock inherits a bare
    /// `/usr/bin:/bin:/usr/sbin:/sbin`, so the user's tool directories are
    /// invisible unless we ask the shell for them. Resolved once per launch:
    /// spawning a login shell is slow and the answer does not change.
    static let loginShellPath: [String] = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell),
              let result = run(shell, ["-lic", "echo $PATH"], timeout: 5),
              result.succeeded
        else { return [] }
        return result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
    }()

    /// Finds a free TCP port by binding one and closing it.
    ///
    /// `opencode serve --port 0` picks a port but never prints it, so QuickAI
    /// has to choose the port itself and pass it explicitly.
    static func freePort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // let the kernel pick
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        return UInt16(bigEndian: resolved.sin_port)
    }
}

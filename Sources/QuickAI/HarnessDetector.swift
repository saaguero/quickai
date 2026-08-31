import Foundation

/// A locally installed coding-agent CLI that QuickAI can answer through.
///
/// The point of a harness provider is billing: the CLI already holds the
/// user's login, so answers are paid by their existing subscription and never
/// by a metered API key. See `.agent/harness-providers/PLAN.md`.
enum HarnessKind: String, CaseIterable, Identifiable, Codable {
    case opencode
    case claudeCode
    case copilot

    var id: String { rawValue }

    /// Also the provider id used in `ModelChoice` and `AppSettings`, and the
    /// prefix of every UserDefaults key this harness owns.
    var providerId: String { rawValue }

    var executableName: String {
        switch self {
        case .opencode: return "opencode"
        case .claudeCode: return "claude"
        case .copilot: return "copilot"
        }
    }

    var displayName: String {
        switch self {
        case .opencode: return "OpenCode"
        case .claudeCode: return "Claude Code"
        case .copilot: return "GitHub Copilot"
        }
    }

    /// Where to send the user when the binary is missing.
    var installHint: String {
        switch self {
        case .opencode: return "brew install opencode, then run: opencode auth login"
        case .claudeCode: return "install Claude Code, then run: claude auth login"
        case .copilot: return "brew install copilot-cli, then run: copilot login"
        }
    }

    /// What lean mode does here, shown under the toggle in Settings.
    var leanModeExplanation: (on: String, off: String) {
        switch self {
        case .opencode:
            return (
                "OpenCode answers as a plain assistant: its coding prompt and every tool are off.",
                "OpenCode behaves normally, with its own prompt and tools. Slower, and it can read files."
            )
        case .claudeCode:
            return (
                "Claude Code answers as a plain assistant: no tools, no skills, no plugins, no CLAUDE.md.",
                "Claude Code behaves normally, with its tools and your customizations. Slower, and it can read files. Anything that needs permission is denied: nothing here can approve it."
            )
        case .copilot:
            return (
                "Copilot answers as a plain assistant: no tools, no MCP servers.",
                "Copilot behaves normally, with its built-in tools and the GitHub MCP server (your own MCP servers and sessions stay untouched: QuickAI gives it a private home). Slower, and it can read files. Anything that needs permission is denied: nothing here can approve it."
            )
        }
    }
}

struct HarnessInstall: Equatable {
    let kind: HarnessKind
    let path: String
    let version: String

    var label: String { "\(version) at \(path)" }
}

/// Locates harness binaries on disk.
///
/// A bundled .app launched from Finder does NOT inherit the shell PATH, so
/// `which opencode` finds nothing in the very context that matters. Detection
/// probes an explicit list of the usual install directories plus every entry
/// of the login shell's PATH, and validates each hit by actually running
/// `--version`: a broken symlink or a non-executable file must not count.
enum HarnessDetector {
    /// Install directories to probe regardless of PATH, in priority order.
    private static let candidateDirectories: [String] = {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.opencode/bin",
            "\(home)/.claude/local",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.volta/bin",
            "/opt/local/bin",
            "/run/current-system/sw/bin",
            "/usr/bin",
            "/bin",
        ]
    }()

    /// Resolves a harness to a usable binary.
    ///
    /// `override` wins when set (the manual path field in Settings) and does
    /// not fall back to the search: a user who typed a path wants to know it
    /// is wrong rather than silently get a different binary.
    static func detect(_ kind: HarnessKind, override: String = "") -> HarnessInstall? {
        let manual = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty {
            return probe(kind, at: (manual as NSString).expandingTildeInPath)
        }
        for directory in searchDirectories() {
            let path = (directory as NSString).appendingPathComponent(kind.executableName)
            if let install = probe(kind, at: path) { return install }
        }
        return nil
    }

    /// Candidate directories first, then the login shell PATH, deduplicated so
    /// a directory present in both is probed once.
    private static func searchDirectories() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for directory in candidateDirectories + ProcessRunner.loginShellPath {
            let normalized = (directory as NSString).expandingTildeInPath
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }
        return ordered
    }

    /// Confirms `path` is a runnable harness binary by asking it its version.
    private static func probe(_ kind: HarnessKind, at path: String) -> HarnessInstall? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        guard let result = ProcessRunner.run(path, ["--version"], timeout: 10), result.succeeded else {
            return nil
        }
        let version = version(from: result.stdout) ?? version(from: result.stderr)
        guard let version else { return nil }
        return HarnessInstall(kind: kind, path: path, version: version)
    }

    /// First non-empty line, trimmed. `opencode --version` prints "1.18.0";
    /// `claude --version` prints "2.1.251 (Claude Code)"; `copilot --version`
    /// prints "GitHub Copilot CLI 1.0.82." with an update hint on line two.
    private static func version(from output: String) -> String? {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}

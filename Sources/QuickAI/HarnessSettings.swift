import Combine
import Foundation

/// Everything one harness provider owns, so adding a second harness does not
/// mean five more properties on `AppSettings` and a second copy of its UI.
///
/// The UserDefaults keys are the harness id plus the field name
/// (`opencodeEnabled`, `claudeCodeLeanMode`), which is what the OpenCode
/// settings already used before this became generic.
final class HarnessSettings: ObservableObject {
    let kind: HarnessKind

    @Published var enabled: Bool {
        didSet {
            store(enabled, "Enabled")
            if enabled { refreshDetection() }
        }
    }

    /// Manual binary path. Empty means auto-detect.
    @Published var path: String {
        didSet {
            store(path, "Path")
            refreshDetection()
        }
    }

    @Published var model: String { didSet { store(model, "Model") } }
    @Published var favorites: [String] { didSet { store(favorites, "Favorites") } }

    /// Lean = QuickAI's prompt, no tools, no customizations. Off lets the
    /// harness behave as it normally would.
    @Published var leanMode: Bool { didSet { store(leanMode, "LeanMode") } }

    /// Where the binary was found. Nil until detection runs, or when missing.
    @Published private(set) var install: HarnessInstall?
    @Published private(set) var isDetecting = false

    private let defaults: UserDefaults

    init(kind: HarnessKind, defaults: UserDefaults = .standard) {
        self.kind = kind
        self.defaults = defaults
        defaults.register(defaults: [
            "\(kind.rawValue)Enabled": false,
            "\(kind.rawValue)Favorites": [String](),
            "\(kind.rawValue)LeanMode": true,
        ])
        enabled = defaults.bool(forKey: "\(kind.rawValue)Enabled")
        path = defaults.string(forKey: "\(kind.rawValue)Path") ?? ""
        model = defaults.string(forKey: "\(kind.rawValue)Model") ?? ""
        favorites = defaults.stringArray(forKey: "\(kind.rawValue)Favorites") ?? []
        leanMode = defaults.bool(forKey: "\(kind.rawValue)LeanMode")
    }

    private func store(_ value: Any, _ field: String) {
        defaults.set(value, forKey: "\(kind.rawValue)\(field)")
    }

    // MARK: - Detection

    /// Locates the binary off the main thread: probing runs `--version` on
    /// candidates and resolves the login shell PATH, which is far too slow to
    /// do while drawing Settings.
    func refreshDetection() {
        guard !isDetecting else { return }
        isDetecting = true
        let kind = kind
        let override = path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let install = HarnessDetector.detect(kind, override: override)
            DispatchQueue.main.async {
                guard let self else { return }
                self.install = install
                self.isDetecting = false
                // The path field changed while we were probing (it fires on
                // every keystroke), so the answer we just got is already stale.
                if self.path != override { self.refreshDetection() }
            }
        }
    }

    // MARK: - Models

    /// Favorites are only reachable when the binary is actually there.
    var choices: [String] {
        guard enabled, install != nil else { return [] }
        return favorites
    }

    /// This harness as a provider, or nil when it is off, missing, or has no
    /// favorite model yet.
    var provider: Provider? {
        let choices = choices
        guard let install, !choices.isEmpty else { return nil }
        let current = model.trimmingCharacters(in: .whitespaces)
        return Provider(
            id: kind.providerId,
            name: kind.displayName,
            baseUrl: install.path,
            apiKey: nil,
            model: choices.contains(current) ? current : choices[0],
            kind: .harness(kind),
            install: install,
            leanMode: leanMode
        )
    }
}

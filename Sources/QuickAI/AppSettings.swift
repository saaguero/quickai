import AppKit
import Carbon.HIToolbox
import Combine

enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto (match macOS)"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let hotKeyChanged = Notification.Name("QuickAI.hotKeyChanged")

    static let defaultSystemPrompt =
        "You are a fast, concise assistant inside a launcher. Answer directly in Markdown, keep it short unless asked to elaborate, and reply in the language of the question."

    private let defaults = UserDefaults.standard

    @Published var openrouterKey: String { didSet { defaults.set(openrouterKey, forKey: "openrouterKey") } }
    @Published var openrouterModel: String { didSet { defaults.set(openrouterModel, forKey: "openrouterModel") } }
    @Published var localBaseUrl: String { didSet { defaults.set(localBaseUrl, forKey: "localBaseUrl") } }
    @Published var localModel: String { didSet { defaults.set(localModel, forKey: "localModel") } }
    @Published var localApiKey: String { didSet { defaults.set(localApiKey, forKey: "localApiKey") } }
    @Published var systemPrompt: String { didSet { defaults.set(systemPrompt, forKey: "systemPrompt") } }
    @Published var providerId: String { didSet { defaults.set(providerId, forKey: "providerId") } }

    @Published var appearance: AppearanceMode {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
    }

    @Published var hotKeyKeyCode: UInt32 {
        didSet {
            defaults.set(Int(hotKeyKeyCode), forKey: "hotKeyKeyCode")
            NotificationCenter.default.post(name: Self.hotKeyChanged, object: nil)
        }
    }

    @Published var hotKeyModifiers: UInt {
        didSet {
            defaults.set(Int(hotKeyModifiers), forKey: "hotKeyModifiers")
            NotificationCenter.default.post(name: Self.hotKeyChanged, object: nil)
        }
    }

    @Published var answerFontSize: Double { didSet { defaults.set(answerFontSize, forKey: "answerFontSize") } }
    @Published var autoResetMinutes: Double { didSet { defaults.set(autoResetMinutes, forKey: "autoResetMinutes") } }
    /// 0 = pure blur (very translucent), 1 = solid window background
    @Published var panelOpacity: Double { didSet { defaults.set(panelOpacity, forKey: "panelOpacity") } }
    /// "" = keep the last used model; otherwise a ModelChoice id ("providerId|model")
    @Published var defaultChoiceRaw: String { didSet { defaults.set(defaultChoiceRaw, forKey: "defaultChoiceRaw") } }
    /// Where the user dragged the panel, as its top-left corner in screen
    /// coordinates. nil = the default position (centered, upper third).
    /// The top edge is the anchor because the panel grows downward.
    @Published var panelTopLeft: CGPoint? {
        didSet {
            if let panelTopLeft {
                defaults.set(Double(panelTopLeft.x), forKey: "panelTopLeftX")
                defaults.set(Double(panelTopLeft.y), forKey: "panelTopLeftY")
                defaults.set(true, forKey: "hasPanelTopLeft")
            } else {
                defaults.set(false, forKey: "hasPanelTopLeft")
            }
        }
    }
    @Published var openrouterFavorites: [String] { didSet { defaults.set(openrouterFavorites, forKey: "openrouterFavorites") } }
    @Published var localFavorites: [String] { didSet { defaults.set(localFavorites, forKey: "localFavorites") } }

    // MARK: - Harnesses (local coding-agent CLIs, paid by their own subscription)

    /// One per `HarnessKind`, in declaration order. Each owns its own defaults,
    /// detection and favorites; `AppSettings` only republishes their changes.
    let harnesses: [HarnessSettings] = HarnessKind.allCases.map { HarnessSettings(kind: $0) }
    private var harnessObservers: [AnyCancellable] = []

    func harness(_ kind: HarnessKind) -> HarnessSettings {
        harnesses.first { $0.kind == kind } ?? HarnessSettings(kind: kind)
    }

    private init() {
        defaults.register(defaults: [
            "openrouterModel": "openrouter/free",
            "localBaseUrl": "http://localhost:8080/v1",
            "systemPrompt": Self.defaultSystemPrompt,
            "providerId": "openrouter",
            "appearance": AppearanceMode.auto.rawValue,
            "hotKeyKeyCode": kVK_Space,
            "hotKeyModifiers": Int(NSEvent.ModifierFlags.option.rawValue),
            "answerFontSize": 16.0,
            "autoResetMinutes": 2.0,
            "panelOpacity": 0.85,
            "openrouterFavorites": ["openrouter/free"],
            "localFavorites": [String](),
        ])
        openrouterKey = defaults.string(forKey: "openrouterKey") ?? ""
        openrouterModel = defaults.string(forKey: "openrouterModel") ?? "openrouter/free"
        localBaseUrl = defaults.string(forKey: "localBaseUrl") ?? ""
        localModel = defaults.string(forKey: "localModel") ?? ""
        localApiKey = defaults.string(forKey: "localApiKey") ?? ""
        systemPrompt = defaults.string(forKey: "systemPrompt") ?? Self.defaultSystemPrompt
        providerId = defaults.string(forKey: "providerId") ?? "openrouter"
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "auto") ?? .auto
        hotKeyKeyCode = UInt32(defaults.integer(forKey: "hotKeyKeyCode"))
        hotKeyModifiers = UInt(defaults.integer(forKey: "hotKeyModifiers"))
        answerFontSize = defaults.double(forKey: "answerFontSize")
        autoResetMinutes = defaults.double(forKey: "autoResetMinutes")
        panelOpacity = defaults.double(forKey: "panelOpacity")
        defaultChoiceRaw = defaults.string(forKey: "defaultChoiceRaw") ?? ""
        panelTopLeft = defaults.bool(forKey: "hasPanelTopLeft")
            ? CGPoint(x: defaults.double(forKey: "panelTopLeftX"), y: defaults.double(forKey: "panelTopLeftY"))
            : nil
        openrouterFavorites = defaults.stringArray(forKey: "openrouterFavorites") ?? ["openrouter/free"]
        localFavorites = defaults.stringArray(forKey: "localFavorites") ?? []

        // A harness change (a new favorite, a re-scan) has to redraw the panel
        // too, and the panel observes AppSettings.
        harnessObservers = harnesses.map { harness in
            harness.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        }
        for harness in harnesses where harness.enabled { harness.refreshDetection() }
    }

    // MARK: - Providers

    var providers: [Provider] {
        // the active model is always one of the favorites; stale values heal
        let orChoices = openrouterChoices
        let orCurrent = openrouterModel.trimmingCharacters(in: .whitespaces)
        var list = [
            Provider(
                id: "openrouter",
                name: "OpenRouter",
                baseUrl: "https://openrouter.ai/api/v1",
                apiKey: openrouterKey.trimmingCharacters(in: .whitespaces).isEmpty ? nil : openrouterKey.trimmingCharacters(in: .whitespaces),
                model: orChoices.contains(orCurrent) ? orCurrent : orChoices[0]
            )
        ]
        let base = localBaseUrl.trimmingCharacters(in: .whitespaces)
        let choices = localChoices
        if !base.isEmpty, !choices.isEmpty {
            let current = localModel.trimmingCharacters(in: .whitespaces)
            let key = localApiKey.trimmingCharacters(in: .whitespaces)
            list.append(Provider(
                id: "local",
                name: "Local LLM",
                baseUrl: base,
                apiKey: key.isEmpty ? nil : key,
                model: choices.contains(current) ? current : choices[0]
            ))
        }
        list.append(contentsOf: harnesses.compactMap(\.provider))
        return list
    }

    var currentProvider: Provider {
        providers.first(where: { $0.id == providerId }) ?? providers[0]
    }

    // MARK: - Model choices (favorites shown in the panel menu)

    var openrouterChoices: [String] {
        openrouterFavorites.isEmpty ? ["openrouter/free"] : openrouterFavorites
    }

    var localChoices: [String] {
        guard !localBaseUrl.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return localFavorites
    }

    var allChoices: [ModelChoice] {
        openrouterChoices.map { ModelChoice(providerId: "openrouter", model: $0) }
            + localChoices.map { ModelChoice(providerId: "local", model: $0) }
            + harnesses.flatMap { harness in
                harness.choices.map { ModelChoice(providerId: harness.kind.providerId, model: $0) }
            }
    }

    /// Label for a provider id, for menus and pickers.
    func providerName(_ providerId: String) -> String {
        if let kind = HarnessKind(rawValue: providerId) { return kind.displayName }
        return providerId == "openrouter" ? "OpenRouter" : "Local LLM"
    }

    var currentChoice: ModelChoice {
        let provider = currentProvider
        return ModelChoice(providerId: provider.id, model: provider.model)
    }

    func select(_ choice: ModelChoice) {
        if let kind = HarnessKind(rawValue: choice.providerId) {
            harness(kind).model = choice.model
        } else if choice.providerId == "openrouter" {
            openrouterModel = choice.model
        } else {
            localModel = choice.model
        }
        providerId = choice.providerId
    }

    func cycleProvider() {
        let all = allChoices
        guard all.count > 1 else { return }
        let index = all.firstIndex(of: currentChoice) ?? 0
        select(all[(index + 1) % all.count])
    }

    var defaultChoice: ModelChoice? {
        guard !defaultChoiceRaw.isEmpty else { return nil }
        let parts = defaultChoiceRaw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let choice = ModelChoice(providerId: parts[0], model: parts[1])
        return allChoices.contains(choice) ? choice : nil
    }

    /// New conversations start on the configured default model (if any).
    func applyDefaultChoice() {
        if let choice = defaultChoice { select(choice) }
    }

    // MARK: - Appearance

    func applyAppearance() {
        switch appearance {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - Hotkey

    var hotKeyModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: hotKeyModifiers)
    }

    var hotKeyDisplay: String {
        var parts = ""
        let flags = hotKeyModifierFlags
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }
        return parts + KeyNames.name(for: hotKeyKeyCode)
    }

    func setHotKey(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        let relevant = modifiers.intersection([.command, .option, .control, .shift])
        hotKeyModifiers = relevant.rawValue
        hotKeyKeyCode = keyCode
    }
}

enum KeyNames {
    private static let table: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        50: "`", 36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func name(for keyCode: UInt32) -> String {
        table[keyCode] ?? "Key\(keyCode)"
    }
}

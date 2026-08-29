import AppKit
import SwiftUI

/// One place for the settings window's type scale, sized to sit close to
/// Raycast's own preferences (roomier than SwiftUI's default form text).
enum SettingsMetrics {
    static let body: CGFloat = 15
    static let secondary: CGFloat = 13
    static let mono: CGFloat = 13
    static let windowWidth: CGFloat = 620
    static let windowHeight: CGFloat = 780
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: ChatViewModel

    var body: some View {
        Form {
            Section("OpenRouter") {
                SecureField("API Key", text: $settings.openrouterKey)
                ModelFavoritesEditor(
                    favorites: $settings.openrouterFavorites,
                    selected: $settings.openrouterModel,
                    fallback: "openrouter/free",
                    source: .openAI(baseUrl: "https://openrouter.ai/api/v1", apiKey: nil)
                )
            }
            Section("Local LLM (OpenAI-compatible)") {
                TextField("Base URL", text: $settings.localBaseUrl)
                SecureField("API Key (optional)", text: $settings.localApiKey)
                ModelFavoritesEditor(
                    favorites: $settings.localFavorites,
                    selected: $settings.localModel,
                    fallback: "",
                    source: .openAI(
                        baseUrl: settings.localBaseUrl,
                        apiKey: settings.localApiKey.isEmpty ? nil : settings.localApiKey
                    )
                )
            }
            ForEach(settings.harnesses, id: \.kind) { harness in
                HarnessSection(harness: harness)
            }
            Section("General") {
                LabeledContent("Global Hotkey") {
                    HotKeyRecorder(settings: settings)
                }
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Picker("Default model for new chats", selection: $settings.defaultChoiceRaw) {
                    Text("Last used").tag("")
                    ForEach(settings.allChoices) { choice in
                        Text("\(settings.providerName(choice.providerId)) · \(choice.model)")
                            .tag(choice.id)
                    }
                }
                LabeledContent("New chat after idle") {
                    Stepper(value: $settings.autoResetMinutes, in: 0...120, step: 1) {
                        Text(settings.autoResetMinutes == 0 ? "never" : "\(Int(settings.autoResetMinutes)) min")
                            .monospacedDigit()
                    }
                }
                LabeledContent("Panel opacity") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.panelOpacity, in: 0...1, step: 0.05)
                            .frame(width: 150)
                        Text("\(Int(settings.panelOpacity * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Reset") { settings.panelOpacity = 0.85 }
                            .disabled(settings.panelOpacity == 0.85)
                    }
                }
                LabeledContent("Answer text size") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.answerFontSize, in: 12...22, step: 1)
                            .frame(width: 150)
                        Text("\(Int(settings.answerFontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Reset") { settings.answerFontSize = 16 }
                            .disabled(settings.answerFontSize == 16)
                    }
                }
            }
            Section("System Prompt") {
                TextEditor(text: $settings.systemPrompt)
                    .font(.system(size: SettingsMetrics.secondary))
                    .frame(height: 80)
            }
            DangerZoneSection(model: model)
            Section("Panel Shortcuts") {
                Text("Drag the panel by its header or its input row; ⌘⇧R puts it back.")
                    .font(.system(size: SettingsMetrics.secondary))
                    .foregroundStyle(.secondary)
                Text(
                    "↩ send · ⎋ stop / close · ⌘N new conversation · ⌘⇧C copy answer · ⌘⇧A copy conversation · ⌘Y history · ⌘[ / ⌘] prev / next chat · ⌘P switch model · ⌘R retry · ⌘⇧R reset panel position · ⌘/ shortcuts · ⌘, settings · ⌘W hide · ⌘Q quit"
                )
                .font(.system(size: SettingsMetrics.secondary))
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .font(.system(size: SettingsMetrics.body))
        .frame(width: SettingsMetrics.windowWidth, height: SettingsMetrics.windowHeight)
    }
}

/// Favorites are the whole model story: star models here, pick the active one
/// from the panel's model menu (or ⌘P). `selected` is only updated to stay valid.
/// Answering through a coding-agent CLI that is already installed and logged
/// in, so the request is covered by that subscription instead of an API key.
struct HarnessSection: View {
    @ObservedObject var harness: HarnessSettings

    private var kind: HarnessKind { harness.kind }

    var body: some View {
        Section("\(kind.displayName) (uses your \(kind.displayName) subscription)") {
            Toggle("Use \(kind.displayName)", isOn: $harness.enabled)
                .font(.system(size: SettingsMetrics.body))

            HStack(spacing: 8) {
                status
                Spacer()
                Button("Re-scan") { harness.refreshDetection() }
                    .font(.system(size: SettingsMetrics.secondary))
                    .disabled(harness.isDetecting)
            }

            TextField("Binary path (leave empty to auto-detect)", text: $harness.path)
                .font(.system(size: SettingsMetrics.mono, design: .monospaced))

            if harness.enabled {
                Toggle("Lean mode (QuickAI prompt, no tools)", isOn: $harness.leanMode)
                    .font(.system(size: SettingsMetrics.body))
                Text(harness.leanMode ? kind.leanModeExplanation.on : kind.leanModeExplanation.off)
                    .font(.system(size: SettingsMetrics.secondary))
                    .foregroundStyle(.secondary)

                if let install = harness.install {
                    ModelFavoritesEditor(
                        favorites: $harness.favorites,
                        selected: $harness.model,
                        fallback: "",
                        source: kind == .opencode ? .opencode(install) : .claudeCode
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if harness.isDetecting {
            Text("Looking for the \(kind.executableName) binary…")
                .font(.system(size: SettingsMetrics.secondary))
                .foregroundStyle(.secondary)
        } else if let install = harness.install {
            Label("Found \(install.label)", systemImage: "checkmark.circle.fill")
                .font(.system(size: SettingsMetrics.secondary))
                .foregroundStyle(.green)
        } else {
            Label("Not found. \(kind.installHint)", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: SettingsMetrics.secondary))
                .foregroundStyle(.orange)
        }
    }
}

/// Where a model browser gets its list.
enum ModelSource: Equatable {
    case openAI(baseUrl: String, apiKey: String?)
    case opencode(HarnessInstall)
    case claudeCode

    /// Whether a model id that is not on the list can still be starred.
    ///
    /// Claude Code has no endpoint to enumerate models, so its list is a fixed
    /// one and typing an id it does not know has to be possible.
    var allowsCustomIds: Bool {
        if case .claudeCode = self { return true }
        return false
    }

    /// Whether the list can be re-fetched from somewhere.
    var isRefreshable: Bool {
        if case .claudeCode = self { return false }
        return true
    }
}

struct ModelFavoritesEditor: View {
    @Binding var favorites: [String]
    @Binding var selected: String
    let fallback: String
    let source: ModelSource

    @State private var models: [ModelInfo] = []
    @State private var query = ""
    @State private var isLoading = false
    @State private var errorText: String?

    /// A model row plus the offsets of its id that the query matched.
    private struct ModelRow: Identifiable {
        let model: ModelInfo
        let highlights: [Range<Int>]
        var id: String { model.id }
    }

    private var filtered: [ModelRow] {
        if query.isEmpty {
            // favorites bubble to the top when just browsing
            let sorted = models.filter { favorites.contains($0.id) } + models.filter { !favorites.contains($0.id) }
            return sorted.map { ModelRow(model: $0, highlights: []) }
        }
        return models
            .compactMap { model in fuzzyMatch(query, in: model.id).map { (model, $0) } }
            // fzf order: score first, then the shorter id, then alphabetical
            .sorted { left, right in
                if left.1.score != right.1.score { return left.1.score > right.1.score }
                if left.0.id.count != right.0.id.count { return left.0.id.count < right.0.id.count }
                return left.0.id < right.0.id
            }
            .map { ModelRow(model: $0.0, highlights: $0.1.ranges) }
    }

    /// A typed id that is on neither list, offered as a manual entry.
    private var customCandidate: String? {
        guard source.allowsCustomIds else { return nil }
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, !favorites.contains(typed), !models.contains(where: { $0.id == typed }) else {
            return nil
        }
        return typed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if favorites.isEmpty {
                Text("No favorite models yet. Search below and star the ones you want in the panel's model menu.")
                    .font(.system(size: SettingsMetrics.secondary))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(favorites, id: \.self) { model in
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill")
                            .font(.system(size: SettingsMetrics.secondary))
                            .foregroundStyle(.yellow)
                        Text(model)
                            .font(.system(size: SettingsMetrics.mono, design: .monospaced))
                            .lineLimit(1)
                        if model == selected {
                            Text("· active")
                                .font(.system(size: SettingsMetrics.secondary))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            removeFavorite(model)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("The active model is picked from the panel's model menu (or ⌘P).")
                    .font(.system(size: SettingsMetrics.secondary))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 8) {
                TextField("", text: $query, prompt: Text("Fuzzy-search models…"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    // a search box must never be autocorrected: macOS would
                    // silently rewrite partial words like "defi" and kill the match
                    .autocorrectionDisabled(true)
                if source.isRefreshable {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Fetch the model list from the server")
                }
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            if let errorText {
                Text(errorText)
                    .font(.system(size: SettingsMetrics.secondary))
                    .foregroundStyle(.red)
            }
            if let custom = customCandidate {
                Button {
                    toggleFavorite(custom)
                } label: {
                    Label("Use \"\(custom)\"", systemImage: "plus.circle")
                        .font(.system(size: SettingsMetrics.secondary))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            if !models.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered.prefix(300)) { row in
                            let model = row.model
                            HStack(spacing: 8) {
                                Button {
                                    toggleFavorite(model.id)
                                } label: {
                                    Image(systemName: favorites.contains(model.id) ? "star.fill" : "star")
                                        .foregroundStyle(favorites.contains(model.id) ? .yellow : .secondary)
                                }
                                .buttonStyle(.plain)
                                highlighted(model.id, ranges: row.highlights, color: SearchHighlight.color)
                                    .font(.system(size: SettingsMetrics.mono, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                if let price = model.priceLabel {
                                    Text(price)
                                        .font(.system(size: SettingsMetrics.secondary))
                                        .foregroundStyle(price == "free" ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                                }
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                            .onTapGesture { toggleFavorite(model.id) }
                        }
                    }
                }
                .frame(height: 180)
            }
        }
        .onAppear {
            if models.isEmpty { Task { await load() } }
        }
    }

    private func load() async {
        isLoading = true
        errorText = nil
        do {
            switch source {
            case .openAI(let baseUrl, let apiKey):
                models = try await ModelCatalog.fetch(baseUrl: baseUrl, apiKey: apiKey)
            case .opencode(let install):
                models = try await ModelCatalog.fetchOpenCode(install: install)
            case .claudeCode:
                models = ModelCatalog.claudeCodeModels
            }
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    private func toggleFavorite(_ model: String) {
        if favorites.contains(model) {
            removeFavorite(model)
        } else {
            favorites.append(model)
            if selected.isEmpty { selected = model }
        }
    }

    private func removeFavorite(_ model: String) {
        favorites.removeAll { $0 == model }
        if selected == model {
            selected = favorites.first ?? fallback
        }
    }
}

struct HotKeyRecorder: View {
    @ObservedObject var settings: AppSettings
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Text(isRecording ? "Press shortcut…" : settings.hotKeyDisplay)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
                )
            Button(isRecording ? "Cancel" : "Change") {
                isRecording ? stopRecording() : startRecording()
            }
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // esc cancels
                stopRecording()
                return nil
            }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let isFunctionKey = (96...122).contains(Int(event.keyCode))
            if modifiers.isEmpty && !isFunctionKey {
                NSSound.beep()
                return nil
            }
            settings.setHotKey(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// Everything destructive in one place. Nothing here is final: deletions land
/// in the 30-day recycle bin below and can be restored from it.
struct DangerZoneSection: View {
    @ObservedObject var model: ChatViewModel

    @State private var trashed: [TrashedConversation] = []
    @State private var isConfirmingDeleteAll = false
    @State private var isConfirmingEmptyTrash = false

    private static let deletedAtFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Section {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delete all conversations")
                        .font(.system(size: SettingsMetrics.body))
                    Text("Moves every conversation to Recently Deleted, kept for \(ConversationStore.trashRetentionDays) days.")
                        .font(.system(size: SettingsMetrics.secondary))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Delete All") { isConfirmingDeleteAll = true }
                    .buttonStyle(.plain)
                    .font(.system(size: SettingsMetrics.body, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.red.opacity(model.history.isEmpty ? 0.35 : 0.9))
                    )
                    .disabled(model.history.isEmpty)
            }
            .padding(.vertical, 2)

            if trashed.isEmpty {
                Text("Recently Deleted is empty.")
                    .font(.system(size: SettingsMetrics.secondary))
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Recently Deleted") {
                    Button("Empty Now") { isConfirmingEmptyTrash = true }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(trashed) { entry in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.conversation.title.isEmpty ? "Untitled" : entry.conversation.title)
                                        .font(.system(size: SettingsMetrics.secondary))
                                        .lineLimit(1)
                                    Text("deleted \(Self.deletedAtFormat.string(from: entry.deletedAt)) · \(daysLeft(entry)) days left")
                                        .font(.system(size: SettingsMetrics.secondary - 2))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Restore") {
                                    model.restoreConversation(id: entry.id)
                                    reload()
                                }
                                .font(.system(size: SettingsMetrics.secondary))
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        } header: {
            Text("Danger Zone")
                .foregroundStyle(.red)
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: ConversationStore.didChange)) { _ in reload() }
        .confirmationDialog(
            "Delete all \(model.history.count) conversations?",
            isPresented: $isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                model.deleteAllConversations()
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They move to Recently Deleted and can be restored for \(ConversationStore.trashRetentionDays) days.")
        }
        .confirmationDialog(
            "Empty Recently Deleted?",
            isPresented: $isConfirmingEmptyTrash,
            titleVisibility: .visible
        ) {
            Button("Empty Now", role: .destructive) {
                model.emptyTrash()
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This one cannot be undone: \(trashed.count) conversations are erased for good.")
        }
    }

    private func reload() {
        // history is lazily loaded by the panel, so refresh it here too:
        // otherwise the count and the button state read as "nothing to delete"
        model.reloadHistory()
        trashed = model.trashedConversations()
    }

    private func daysLeft(_ entry: TrashedConversation) -> Int {
        let elapsed = Date().timeIntervalSince(entry.deletedAt) / 86_400
        return max(0, ConversationStore.trashRetentionDays - Int(elapsed))
    }
}

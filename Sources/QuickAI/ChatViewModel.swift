import AppKit
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var conversation: Conversation
    @Published var inputText = ""
    @Published var draft = ""
    @Published var isStreaming = false
    @Published var error: String?
    @Published var isShowingHistory = false
    @Published var history: [Conversation] = []
    @Published var historyIndex = 0
    @Published var isShowingShortcuts = false
    @Published var flash: String?
    /// Live reasoning for the answer being streamed. Progress only: it is
    /// cleared when the answer lands and never saved with the conversation.
    @Published var reasoning = ""

    let settings: AppSettings
    private let store = ConversationStore()
    private var streamTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        conversation = .fresh(providerId: settings.providerId)
    }

    var hasContent: Bool {
        !conversation.messages.isEmpty || isStreaming || error != nil
    }

    var lastAnswer: String? {
        conversation.messages.last(where: { $0.role == .assistant })?.content
    }

    // MARK: - Ask

    func submitCurrentInput() {
        let question = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming else { return }
        inputText = ""
        submit(question)
    }

    func submit(_ question: String) {
        let provider = settings.currentProvider
        conversation.providerId = provider.id
        if conversation.title.isEmpty { conversation.title = String(question.prefix(80)) }
        conversation.messages.append(Message(role: .user, content: question))
        conversation.updatedAt = Date()
        error = nil
        draft = ""
        reasoning = ""
        isStreaming = true

        // Harness providers keep the transcript server-side and take the system
        // prompt as its own field, so they get the messages unprefixed.
        let payload: [Message]
        if case .harness = provider.kind {
            payload = conversation.messages
        } else {
            payload = [Message(role: .system, content: settings.systemPrompt)] + conversation.messages
        }
        let conversationId = conversation.id

        streamTask = Task { [weak self] in
            guard let self else { return }
            var answer = ""
            var thinking = ""
            var lastFlush = Date.distantPast
            var attempt = 0
            while true {
                attempt += 1
                do {
                    for try await chunk in ChatClient.stream(
                        provider: provider,
                        messages: payload,
                        conversationId: conversationId,
                        systemPrompt: self.settings.systemPrompt
                    ) {
                        switch chunk {
                        case .text(let delta): answer += delta
                        case .reasoning(let delta): thinking += delta
                        }
                        let now = Date()
                        if now.timeIntervalSince(lastFlush) > 0.05 {
                            lastFlush = now
                            self.draft = answer
                            self.reasoning = thinking
                        }
                    }
                    self.finishAssistant(answer.isEmpty ? "*(empty answer)*" : answer)
                    return
                } catch {
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        if answer.isEmpty {
                            // drop the pending user message so retry state stays clean
                            if self.conversation.messages.last?.role == .user {
                                self.conversation.messages.removeLast()
                            }
                            self.isStreaming = false
                            self.draft = ""
                            self.reasoning = ""
                        } else {
                            self.finishAssistant(answer + "\n\n*(stopped)*")
                        }
                        return
                    }
                    // First connect to a LAN server can die while macOS shows the
                    // Local Network permission prompt: retry once, silently.
                    if answer.isEmpty, attempt == 1,
                       let code = (error as? URLError)?.code,
                       code == .cannotConnectToHost || code == .networkConnectionLost {
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        if !Task.isCancelled { continue }
                    }
                    self.isStreaming = false
                    self.draft = ""
                    self.reasoning = ""
                    var message = error.localizedDescription
                    if let code = (error as? URLError)?.code,
                       code == .cannotConnectToHost || code == .networkConnectionLost || code == .timedOut {
                        // name the endpoint so misconfigured base URLs self-diagnose
                        message += " (\(provider.baseUrl))"
                    }
                    self.error = message
                    return
                }
            }
        }
    }

    private func finishAssistant(_ content: String) {
        conversation.messages.append(Message(role: .assistant, content: content.trimmingCharacters(in: .whitespacesAndNewlines)))
        conversation.updatedAt = Date()
        isStreaming = false
        draft = ""
        reasoning = ""
        store.upsert(conversation)
        if conversation.messages.filter({ $0.role == .user }).count == 1,
           let question = conversation.messages.first(where: { $0.role == .user })?.content {
            generateTitle(for: conversation.id, question: question)
        }
    }

    /// Ask the same model for a clean, spell-fixed title once the first answer lands.
    private func generateTitle(for conversationId: String, question: String) {
        let provider = settings.currentProvider
        Task { [weak self] in
            let prompt = """
            Write a short title (3 to 6 words) for a conversation that starts with the question below. \
            Fix any spelling mistakes. Use the question's own language. Reply with the title only, no quotes.

            Question: \(question)
            """
            guard let raw = try? await ChatClient.complete(
                provider: provider,
                messages: [Message(role: .user, content: prompt)],
                maxTokens: 30
            ) else { return }
            var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”«»`"))
            // small local models sometimes echo the instruction instead of answering
            let lowered = title.lowercased()
            let looksEchoed = lowered.contains("short title") || lowered.contains("3 to 6") || lowered.contains("the question")
            let wordCount = title.split(separator: " ").count
            guard !title.isEmpty, !title.contains("\n"), !looksEchoed, wordCount <= 10 else { return }
            self?.applyTitle(String(title.prefix(60)), to: conversationId)
        }
    }

    private func applyTitle(_ title: String, to conversationId: String) {
        store.updateTitle(id: conversationId, title: title)
        if conversation.id == conversationId {
            conversation.title = title
        }
        if isShowingHistory {
            reloadHistory()
        }
    }

    func stop() {
        streamTask?.cancel()
    }

    func retry() {
        guard !isStreaming, let lastUser = conversation.messages.last(where: { $0.role == .user }) else { return }
        if let index = conversation.messages.lastIndex(where: { $0.role == .user }) {
            conversation.messages.removeSubrange(index...)
        }
        error = nil
        let question = lastUser.content

        // A retry rewrites the transcript, and a harness session may already
        // hold the turn that just failed. Drop it first so the next turn is
        // rebuilt from what QuickAI actually has, instead of asking the same
        // question twice into the same session.
        guard case .harness(let kind) = settings.currentProvider.kind else {
            submit(question)
            return
        }
        let id = conversation.id
        Task { @MainActor [weak self] in
            await Self.resetHarnessSession(kind: kind, conversationId: id)
            self?.submit(question)
        }
    }

    private static func resetHarnessSession(kind: HarnessKind, conversationId: String) async {
        switch kind {
        case .opencode: await OpenCodeClient.reset(conversationId: conversationId)
        case .claudeCode: await ClaudeCodeClient.reset(conversationId: conversationId)
        }
    }

    /// `silent` starts a fresh conversation without leaving the history list or
    /// touching the search box: used when the open conversation is deleted.
    func newConversation(silent: Bool = false) {
        streamTask?.cancel()
        settings.applyDefaultChoice()
        conversation = .fresh(providerId: settings.providerId)
        draft = ""
        reasoning = ""
        error = nil
        isStreaming = false
        guard !silent else { return }
        isShowingHistory = false
        inputText = ""
        showFlash("New conversation")
    }

    // MARK: - History

    func toggleHistory() {
        if !isShowingHistory {
            reloadHistory()
            historyIndex = 0
        }
        inputText = ""
        isShowingHistory.toggle()
    }

    /// A history row: the conversation plus which offsets of its displayed
    /// title the current search matched, for highlighting.
    struct HistoryRow: Identifiable {
        let conversation: Conversation
        let title: String
        let highlights: [Range<Int>]
        var id: String { conversation.id }
    }

    /// History filtered by the bottom input, fzf-style: titles are matched
    /// fuzzily, the conversation's own questions only as an exact run and
    /// always behind any title hit. Higher fzf score first, recency breaks ties.
    var filteredHistoryRows: [HistoryRow] {
        let query = inputText.trimmingCharacters(in: .whitespaces)
        guard isShowingHistory, !query.isEmpty else {
            return history.map { HistoryRow(conversation: $0, title: Self.displayTitle($0), highlights: []) }
        }
        return history
            .compactMap { conversation -> (row: HistoryRow, isTitle: Bool, score: Int)? in
                let title = Self.displayTitle(conversation)
                if let match = fuzzyMatch(query, in: title) {
                    let row = HistoryRow(conversation: conversation, title: title, highlights: match.ranges)
                    return (row, true, match.score)
                }
                let questions = conversation.messages
                    .filter { $0.role == .user }
                    .map(\.content)
                    .joined(separator: " ")
                if let match = fuzzyMatch(query, in: questions, exact: true) {
                    let row = HistoryRow(conversation: conversation, title: title, highlights: [])
                    return (row, false, match.score)
                }
                return nil
            }
            .sorted { left, right in
                if left.isTitle != right.isTitle { return left.isTitle }
                if left.score != right.score { return left.score > right.score }
                // fzf breaks score ties by the shorter candidate; recency last
                if left.row.title.count != right.row.title.count {
                    return left.row.title.count < right.row.title.count
                }
                return left.row.conversation.updatedAt > right.row.conversation.updatedAt
            }
            .map(\.row)
    }

    var filteredHistory: [Conversation] {
        filteredHistoryRows.map(\.conversation)
    }

    private static func displayTitle(_ conversation: Conversation) -> String {
        conversation.title.isEmpty ? "Untitled" : conversation.title
    }

    func moveHistorySelection(_ delta: Int) {
        let count = filteredHistory.count
        guard count > 0 else { return }
        historyIndex = min(max(historyIndex + delta, 0), count - 1)
    }

    func openSelectedHistory() {
        let filtered = filteredHistory
        guard filtered.indices.contains(historyIndex) else { return }
        openConversation(filtered[historyIndex])
    }

    /// ⌘[ / ⌘]: walk saved conversations from the panel. direction -1 = older,
    /// +1 = newer; stepping past the newest lands on a fresh conversation.
    func navigateConversations(_ direction: Int) {
        let all = store.load()
        guard !all.isEmpty else { return }
        isShowingHistory = false
        if let index = all.firstIndex(where: { $0.id == conversation.id }) {
            let target = index - direction // list is newest-first
            if target >= 0 && target < all.count {
                // the persistent header title announces the switch, no flash needed
                openConversation(all[target])
            } else if target < 0 && !conversation.messages.isEmpty {
                newConversation()
            }
        } else if direction < 0 {
            openConversation(all[0])
        }
    }

    /// Called when the panel is summoned: a stale conversation starts fresh.
    func autoResetIfIdle() {
        guard settings.autoResetMinutes > 0, !isStreaming, !conversation.messages.isEmpty else { return }
        if Date().timeIntervalSince(conversation.updatedAt) > settings.autoResetMinutes * 60 {
            newConversation()
        }
    }

    /// Reopening the panel in history mode must never present a stale list:
    /// re-read the store, drop the leftover search text and reset the cursor.
    func restartHistorySearch() {
        inputText = ""
        historyIndex = 0
        reloadHistory()
    }

    func reloadHistory() {
        history = store.load()
    }

    func openConversation(_ conversation: Conversation) {
        streamTask?.cancel()
        self.conversation = conversation
        if settings.providers.contains(where: { $0.id == conversation.providerId }) {
            settings.providerId = conversation.providerId
        }
        draft = ""
        reasoning = ""
        error = nil
        isStreaming = false
        isShowingHistory = false
        inputText = ""
    }

    /// Deletions are recoverable: the store moves them to its 30-day bin.
    func deleteConversation(_ conversation: Conversation) {
        store.delete(id: conversation.id)
        if conversation.id == self.conversation.id { newConversation(silent: true) }
        reloadHistory()
        historyIndex = min(historyIndex, max(filteredHistoryRows.count - 1, 0))
        showFlash("Moved to Recently Deleted (\(ConversationStore.trashRetentionDays) days)")
    }

    /// ⌘⌫ in the history list: delete whatever row is selected.
    func deleteSelectedHistory() {
        let rows = filteredHistoryRows
        guard rows.indices.contains(historyIndex) else { return }
        deleteConversation(rows[historyIndex].conversation)
    }

    /// Settings "Danger Zone": everything to the bin, nothing lost yet.
    @discardableResult
    func deleteAllConversations() -> Int {
        let moved = store.deleteAll()
        newConversation(silent: true)
        reloadHistory()
        historyIndex = 0
        return moved
    }

    func restoreConversation(id: String) {
        store.restore(id: id)
        reloadHistory()
    }

    func trashedConversations() -> [TrashedConversation] {
        store.loadTrash()
    }

    /// The only irreversible delete in the app.
    func emptyTrash() {
        store.emptyTrash()
    }

    // MARK: - Clipboard

    func copyLastAnswer() {
        guard let answer = lastAnswer else { return }
        copyToClipboard(answer)
        showFlash("Answer copied")
    }

    func copyConversation() {
        guard !conversation.messages.isEmpty else { return }
        let plain = conversation.messages
            .map { $0.role == .user ? "> \($0.content)" : $0.content }
            .joined(separator: "\n\n")
        copyToClipboard(plain)
        showFlash("Conversation copied")
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func cycleProvider() {
        settings.cycleProvider()
        showFlash(settings.currentProvider.shortLabel)
    }

    func showFlash(_ text: String) {
        flashTask?.cancel()
        flash = text
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if !Task.isCancelled { self?.flash = nil }
        }
    }

    // MARK: - Rendering

    var fullMarkdown: String {
        var blocks: [String] = []
        for message in conversation.messages {
            switch message.role {
            case .user:
                blocks.append("### ❯ \(message.content)")
            case .assistant:
                blocks.append(message.content)
                blocks.append("---")
            case .system:
                break
            }
        }
        if isStreaming {
            blocks.append(draft.isEmpty ? "*Thinking…*" : draft + " ▍")
        }
        if let error {
            blocks.append("> ⚠️ **Error:** \(error)\n>\n> Press ⌘R to retry.")
        }
        while blocks.last == "---" { blocks.removeLast() }
        return blocks.joined(separator: "\n\n")
    }
}

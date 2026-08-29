import Foundation

struct Message: Codable, Equatable {
    enum Role: String, Codable {
        case system, user, assistant
    }

    var role: Role
    var content: String
}

struct Conversation: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var providerId: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [Message]

    static func fresh(providerId: String) -> Conversation {
        Conversation(
            id: UUID().uuidString,
            title: "",
            providerId: providerId,
            createdAt: Date(),
            updatedAt: Date(),
            messages: []
        )
    }
}

/// How QuickAI reaches a provider.
///
/// `.harness` answers through a coding-agent CLI already installed and logged
/// in on this machine, so the request is paid by the user's subscription and
/// never by a metered API key.
enum ProviderKind: Equatable {
    case openAI
    case harness(HarnessKind)
}

struct Provider: Identifiable, Equatable {
    let id: String
    let name: String
    let baseUrl: String
    let apiKey: String?
    let model: String
    var kind: ProviderKind = .openAI
    /// Resolved binary, for `.harness` providers only.
    var install: HarnessInstall?
    /// Lean mode strips the agent's own prompt and every tool, leaving a plain
    /// answerer. Off means the harness behaves as it normally would.
    var leanMode = true

    var shortLabel: String { "\(name) · \(model)" }
}

/// A conversation in the recycle bin, kept for `ConversationStore.trashRetentionDays`.
struct TrashedConversation: Codable, Identifiable, Equatable {
    var conversation: Conversation
    var deletedAt: Date

    var id: String { conversation.id }
}

/// Persists conversations as JSON under ~/Library/Application Support/QuickAI/.
/// Deletions are never immediate: they move to `trash.json` and are purged
/// after 30 days, so a wrong keystroke stays recoverable.
final class ConversationStore {
    static let trashRetentionDays = 30
    static let didChange = Notification.Name("QuickAI.conversationsDidChange")

    private let maxConversations = 50
    private let fileURL: URL
    private let trashURL: URL

    /// `directory` exists for tests: they MUST pass their own, because every
    /// delete path here writes to real files (see the trap in AGENTS.md).
    init(directory: URL? = nil) {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = support.appendingPathComponent("QuickAI", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("conversations.json")
        trashURL = dir.appendingPathComponent("trash.json")
    }

    func load() -> [Conversation] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Conversation].self, from: data)) ?? []
    }

    func upsert(_ conversation: Conversation) {
        var all = load()
        if let index = all.firstIndex(where: { $0.id == conversation.id }) {
            all[index] = conversation
        } else {
            all.insert(conversation, at: 0)
        }
        all.sort { $0.updatedAt > $1.updatedAt }
        save(Array(all.prefix(maxConversations)))
    }

    /// Moves one conversation to the recycle bin.
    func delete(id: String) {
        let all = load()
        guard let conversation = all.first(where: { $0.id == id }) else { return }
        save(all.filter { $0.id != id })
        addToTrash([conversation])
    }

    /// Moves every conversation to the recycle bin. Returns how many moved.
    @discardableResult
    func deleteAll() -> Int {
        let all = load()
        guard !all.isEmpty else { return 0 }
        save([])
        addToTrash(all)
        return all.count
    }

    // MARK: - Recycle bin

    /// The bin, newest deletion first, with expired entries already purged.
    func loadTrash() -> [TrashedConversation] {
        guard let data = try? Data(contentsOf: trashURL),
              let trashed = try? JSONDecoder().decode([TrashedConversation].self, from: data)
        else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(Self.trashRetentionDays) * 86_400)
        let alive = trashed.filter { $0.deletedAt > cutoff }
        if alive.count != trashed.count { saveTrash(alive) }
        return alive.sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Puts one conversation back into the history, keeping its own timestamps.
    func restore(id: String) {
        let trashed = loadTrash()
        guard let entry = trashed.first(where: { $0.id == id }) else { return }
        saveTrash(trashed.filter { $0.id != id })
        upsert(entry.conversation)
    }

    func emptyTrash() {
        saveTrash([])
    }

    private func addToTrash(_ conversations: [Conversation]) {
        let now = Date()
        var trashed = loadTrash()
        // a conversation deleted twice keeps only its latest copy
        let ids = Set(conversations.map(\.id))
        trashed.removeAll { ids.contains($0.id) }
        trashed.append(contentsOf: conversations.map { TrashedConversation(conversation: $0, deletedAt: now) })
        saveTrash(trashed)
    }

    private func saveTrash(_ trashed: [TrashedConversation]) {
        guard let data = try? JSONEncoder().encode(trashed) else { return }
        try? data.write(to: trashURL, options: .atomic)
    }

    func updateTitle(id: String, title: String) {
        var all = load()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].title = title
        save(all)
    }

    private func save(_ conversations: [Conversation]) {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        try? data.write(to: fileURL, options: .atomic)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
